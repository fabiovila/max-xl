-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

config.plugins.terminal = common.merge({
  scrollback = 1000,
  -- Font used by the terminal grid. Either a path to a monospace .ttf or a
  -- renderer.font object (see renderer.font.load). When nil the view falls
  -- back to style.code_font, so themes/scale still apply.
  font = nil,
  -- Only used when `font` is a path; multiplied by SCALE like style fonts.
  font_size = 15,
  -- Rendering options for a font loaded from a path.
  font_options = { antialiasing = "grayscale", hinting = "full" },
  -- Fonts tried (in order) for glyphs missing from `font`, e.g. the ✓/✗ that
  -- fish prompts print. Only paths that exist are loaded. Set to false to
  -- disable the fallback chain.
  font_fallback = {
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
  },
  -- Inner margin between the view edges and the grid, in SCALE units.
  padding = { x = 10, y = 8 },
  -- Rows scrolled per mouse wheel notch.
  scroll_wheel_rows = 3,
}, config.plugins.terminal)

local DEFAULT_FONT_OPTIONS = { antialiasing = "grayscale", hinting = "full" }
local font_cache = {}

local has_pty = pcall(function() return pty end)
if not has_pty then
  core.error("Terminal needs the pty module (rebuild max-xl)")
end

-- xterm palette 0-15 + 6x6x6 cube + grayscale for 256-color mode.
local PALETTE = {}
do
  local base = {
    "#000000", "#cd0000", "#00cd00", "#cdcd00",
    "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
    "#7f7f7f", "#ff0000", "#00ff00", "#ffff00",
    "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
  }
  for _, hex in ipairs(base) do
    table.insert(PALETTE, { common.color(hex) })
  end
  for r = 0, 5 do for g = 0, 5 do for b = 0, 5 do
    local v = function(x) return x == 0 and 0 or 55 + 40 * x end
    table.insert(PALETTE, { v(r), v(g), v(b), 255 })
  end end end
  for i = 0, 23 do
    local v = 8 + 10 * i
    table.insert(PALETTE, { v, v, v, 255 })
  end
end
local BRIGHT_OF = {}
for i = 1, 8 do BRIGHT_OF[PALETTE[i]] = PALETTE[i + 8] end
local rgb_cache = {}
local function rgb(r, g, b)
  local key = r * 65536 + g * 256 + b
  local c = rgb_cache[key]
  if not c then
    c = { r, g, b, 255 }
    rgb_cache[key] = c
  end
  return c
end

---@class plugins.terminal.view : core.view
local TerminalView = View:extend()

function TerminalView:__tostring() return "TerminalView" end

function TerminalView:new()
  TerminalView.super.new(self)
  self.scrollable = false
  self.lines = {}
  self.max_w = 0
  self.pty = nil
  self.started = false
  self.cols, self.rows = 80, 24
  self.cx, self.cy = 1, 1
  self.pending_wrap = false
  self.show_cursor = true
  self.fg, self.bg, self.bold = nil, nil, false
  self.region_top, self.region_bottom = 1, 24
  self.alt = nil
  self.carry = ""
  self.view_top = nil -- nil = follow the tail; number = first visible line
  self.sel = nil -- { line1, col1, line2, col2 } inclusive cell coordinates
  self.mouse_selecting = nil
  self.scrollbar_dragging = false
  self.osc_title = nil
  self.exit_code = nil
  self.started = false
end

function TerminalView:get_name()
  if self.osc_title and self.osc_title ~= "" then return self.osc_title end
  if self.exit_code ~= nil then
    return string.format("Terminal [exit %d]", self.exit_code)
  end
  return "Terminal"
end

function TerminalView:supports_text_input() return true end

function TerminalView:is_open()
  return core.root_view.root_node:get_node_for_view(self) ~= nil
end

function TerminalView:is_running()
  return self.pty ~= nil and self.pty:running()
end

function TerminalView:get_text()
  local out = {}
  for _, row in ipairs(self.lines) do
    local chars = {}
    for _, c in ipairs(row.ch) do table.insert(chars, c) end
    table.insert(out, (table.concat(chars):gsub("%s+$", "")))
  end
  return table.concat(out, "\n")
end

local function load_font_file(path, size, opts)
  local ok, font = pcall(renderer.font.load, path, size, opts)
  if ok and font then return font end
  return nil
end

local function font_file_exists(path)
  return system.get_file_info(path) ~= nil
end

-- Resolve the configured font. When possible it is wrapped in a renderer font
-- group with fallback fonts, so glyphs the main font lacks (the ✓/✗ printed
-- by fish prompts, box drawing, emoji-ish symbols) do not render as tofu.
function TerminalView:get_font()
  local cfg = config.plugins.terminal
  local font = cfg.font
  if type(font) == "table" then return font end

  local from_path = type(font) == "string" and font ~= ""
  local size, opts, label
  if from_path then
    size = common.round((cfg.font_size or 15) * SCALE)
    opts = cfg.font_options or DEFAULT_FONT_OPTIONS
    label = font
  else
    font = style.code_font
    if type(font) == "table" then return font end -- theme already grouped it
    size = font:get_size()
    opts = DEFAULT_FONT_OPTIONS
    label = tostring(font)
  end

  local fallbacks = {}
  if cfg.font_fallback ~= false then
    for _, path in ipairs(cfg.font_fallback or {}) do
      if font_file_exists(path) then fallbacks[#fallbacks + 1] = path end
    end
  end

  local key = string.format("%s|%s|%s|%s|%s", label, tostring(size),
    tostring(opts.antialiasing), tostring(opts.hinting),
    table.concat(fallbacks, ","))
  local cached = font_cache[key]
  if cached ~= nil then return cached or style.code_font end

  local primary = font
  if from_path then
    primary = load_font_file(font, size, opts)
    if not primary then
      core.log("Terminal: could not load font '%s', using the code font", font)
      primary = style.code_font
      size = primary:get_size()
    end
  end

  local group = { primary }
  for _, path in ipairs(fallbacks) do
    local fallback = load_font_file(path, size, opts)
    if fallback then group[#group + 1] = fallback end
  end
  local resolved = #group > 1 and renderer.font.group(group) or primary
  font_cache[key] = resolved or false
  return resolved
end

function TerminalView:get_row_height()
  return self:get_font():get_height()
end

function TerminalView:get_char_width()
  return self:get_font():get_width("M")
end

function TerminalView:get_padding()
  local pad = config.plugins.terminal.padding
  if type(pad) == "number" then pad = { x = pad, y = pad } end
  pad = pad or {}
  return common.round((pad.x or 0) * SCALE), common.round((pad.y or 0) * SCALE)
end

-- Area actually used by the character grid (the view minus the inner margin).
function TerminalView:get_grid_bounds()
  local padx, pady = self:get_padding()
  local w = math.max(1, self.size.x - padx * 2)
  local h = math.max(1, self.size.y - pady * 2)
  return common.round(self.position.x + padx), common.round(self.position.y + pady), w, h
end

function TerminalView:get_visible_rows()
  local _, _, _, h = self:get_grid_bounds()
  return math.max(1, math.floor(h / self:get_row_height()))
end

function TerminalView:get_visible_cols()
  local _, _, w = self:get_grid_bounds()
  return math.max(1, math.floor(w / self:get_char_width()))
end

function TerminalView:get_max_view_top()
  return math.max(1, #self.lines - self:get_visible_rows() + 1)
end

-- top line of the viewport; nil means "follow the tail"
function TerminalView:get_view_top()
  if self.view_top == nil then return self:get_max_view_top() end
  return common.clamp(self.view_top, 1, self:get_max_view_top())
end

function TerminalView:set_view_top(top)
  local max_top = self:get_max_view_top()
  top = common.clamp(math.floor(top), 1, max_top)
  self.view_top = top >= max_top and nil or top
  core.redraw = true
end

function TerminalView:scroll_by(rows)
  local max_top = self:get_max_view_top()
  local top = self:get_view_top()
  self:set_view_top(top - rows)
  return max_top > 1
end

function TerminalView:scroll_to_bottom()
  if self.view_top ~= nil then
    self.view_top = nil
    core.redraw = true
  end
end

function TerminalView:get_view_range()
  local total = #self.lines
  if total == 0 then return 1, 0 end
  local vis = self:get_visible_rows()
  if total <= vis then return 1, total end
  local first = self:get_view_top()
  return first, math.min(total, first + vis - 1)
end

-- Pixel origin of the visible grid chunk. Short buffers are bottom-aligned
-- so a fresh prompt sits at the bottom of the view, like a real terminal.
function TerminalView:get_grid_origin()
  local gx, gy, _, gh = self:get_grid_bounds()
  local first, last = self:get_view_range()
  local rows = math.max(1, last - first + 1)
  return gx, common.round(gy + gh - rows * self:get_row_height())
end

function TerminalView:get_scrollable_size()
  return #self.lines * self:get_row_height()
end

-- Grid -----------------------------------------------------------------------

function TerminalView:blank_row()
  return { ch = {}, fg = {}, bg = {}, bold = {} }
end

function TerminalView:screen_start()
  return math.max(1, #self.lines - self.rows + 1)
end

function TerminalView:ensure_cell(line, col)
  local row = self.lines[line]
  while #row.ch < col do
    table.insert(row.ch, " ")
    table.insert(row.fg, false)
    table.insert(row.bg, false)
    table.insert(row.bold, false)
  end
end

function TerminalView:default_fg() return style.text end
function TerminalView:default_bg()
  local C = self.C or style.panel_theme()
  return C.terminal_bg
end

function TerminalView:resolve_fg(cell_fg, bold)
  local fg = cell_fg or self:default_fg()
  if bold and BRIGHT_OF[fg] then fg = BRIGHT_OF[fg] end
  return fg
end

function TerminalView:trim_buffer()
  local cap = self.rows + (config.plugins.terminal.scrollback or 1000)
  local removed = 0
  while #self.lines > cap do
    table.remove(self.lines, 1)
    self.cy = self.cy - 1
    removed = removed + 1
  end
  if self.cy < 1 then self.cy = 1 end
  -- keep the same absolute lines in view when old scrollback is dropped
  if removed > 0 and self.view_top then
    self.view_top = self.view_top - removed
    if self.view_top < 1 then self.view_top = 1 end
    if self.view_top >= self:get_max_view_top() then self.view_top = nil end
  end
  -- selected cells move up with the buffer
  if removed > 0 and self.sel then
    self.sel[1], self.sel[3] = self.sel[1] - removed, self.sel[3] - removed
    if self.sel[1] < 1 or self.sel[3] < 1 then self.sel = nil end
  end
end

function TerminalView:scroll_up(rs, re, n)
  n = math.min(n, re - rs + 1)
  if n < 1 then return end
  local to_sb = rs == self:screen_start()
  local cap = {}
  if to_sb then
    for i = rs, rs + n - 1 do table.insert(cap, self.lines[i]) end
  end
  for i = rs, re - n do self.lines[i] = self.lines[i + n] end
  for i = re - n + 1, re do self.lines[i] = self:blank_row() end
  if to_sb then
    local ss = self:screen_start()
    for i = 1, #cap do table.insert(self.lines, ss, cap[i]) end
  end
  self:trim_buffer()
end

function TerminalView:linefeed()
  self.pending_wrap = false
  -- Scroll only when the cursor sits at the region bottom AND the buffer
  -- actually reaches it. With a short buffer (fresh shell) the clamped
  -- rbot would equal cy and wrongly trigger a scroll, making new output
  -- overwrite the current row instead of advancing to a fresh one.
  local region_end = self:screen_start() + self.region_bottom - 1
  if self.cy >= region_end and #self.lines >= region_end then
    local rbot = math.min(region_end, #self.lines)
    self:scroll_up(self:screen_start() + self.region_top - 1, rbot, 1)
    -- track the region bottom in the (possibly grown) buffer
    self.cy = math.min(self:screen_start() + self.region_bottom - 1, #self.lines)
    if self.cy > #self.lines then self.cy = #self.lines end
  else
    self.cy = self.cy + 1
  end
  if self.cy > #self.lines then
    table.insert(self.lines, self:blank_row())
  end
end

function TerminalView:put(ch)
  if self.pending_wrap then
    self.cx = 1
    self:linefeed()
    self.pending_wrap = false
  end
  if self.cx > self.cols then
    self.cx = 1
    self:linefeed()
  end
  while #self.lines < self.cy do
    table.insert(self.lines, self:blank_row())
  end
  self:ensure_cell(self.cy, self.cx)
  local row = self.lines[self.cy]
  row.ch[self.cx] = ch
  row.fg[self.cx] = self.fg or false
  row.bg[self.cx] = self.bg or false
  row.bold[self.cx] = self.bold or false
  if self.cx >= self.cols then
    self.pending_wrap = true
  else
    self.cx = self.cx + 1
  end
end

-- Parser ----------------------------------------------------------------------

function TerminalView:sgr(params)
  local i = 1
  local function next_param(default)
    local v = params[i]
    i = i + 1
    if v == nil or v == "" then return default end
    return tonumber(v) or default
  end
  while i <= #params + 1 do
    local p = next_param(0)
    if p == 0 then
      self.fg, self.bg, self.bold = nil, nil, false
    elseif p == 1 then
      self.bold = true
    elseif p == 22 then
      self.bold = false
    elseif p >= 30 and p <= 37 then
      self.fg = PALETTE[p - 30 + 1]
    elseif p >= 90 and p <= 97 then
      self.fg = PALETTE[p - 90 + 9]
    elseif p == 39 then
      self.fg = nil
    elseif p >= 40 and p <= 47 then
      self.bg = PALETTE[p - 40 + 1]
    elseif p >= 100 and p <= 107 then
      self.bg = PALETTE[p - 100 + 9]
    elseif p == 49 then
      self.bg = nil
    elseif p == 38 or p == 48 then
      local target_fg = p == 38
      local mode = next_param(0)
      local color
      if mode == 5 then
        local n = next_param(0)
        color = PALETTE[n + 1]
      elseif mode == 2 then
        color = rgb(next_param(0), next_param(0), next_param(0))
      end
      if color then
        if target_fg then self.fg = color else self.bg = color end
      end
    end
    if i > #params then break end
  end
end

function TerminalView:reply(data)
  if self.pty then
    pcall(function() self.pty:write(data) end)
  end
end

function TerminalView:csi(params, private, final)
  local n = tonumber(params[1] or "") or 1
  local function clamp_row(v) return common.clamp(v, 1, #self.lines) end
  if final == "A" then
    self.cy = clamp_row(self.cy - math.max(n, 1))
    self.pending_wrap = false
  elseif final == "B" or final == "e" then
    self.cy = clamp_row(self.cy + math.max(n, 1))
    self.pending_wrap = false
  elseif final == "C" then
    self.cx = common.clamp(self.cx + math.max(n, 1), 1, self.cols)
    self.pending_wrap = false
  elseif final == "D" then
    self.cx = common.clamp(self.cx - math.max(n, 1), 1, self.cols)
    self.pending_wrap = false
  elseif final == "E" then
    self.cy = clamp_row(self.cy + math.max(n, 1))
    self.cx = 1
    self.pending_wrap = false
  elseif final == "F" then
    self.cy = clamp_row(self.cy - math.max(n, 1))
    self.cx = 1
    self.pending_wrap = false
  elseif final == "G" or final == "`" then
    self.cx = common.clamp(math.max(tonumber(params[1] or "") or 1, 1), 1, self.cols)
    self.pending_wrap = false
  elseif final == "H" or final == "f" then
    local r = math.max(tonumber(params[1] or "") or 1, 1)
    local c = math.max(tonumber(params[2] or "") or 1, 1)
    local ss = self:screen_start()
    self.cy = common.clamp(ss + r - 1, ss, ss + self.rows - 1)
    if self.cy > #self.lines then self.cy = #self.lines end
    self.cx = common.clamp(c, 1, self.cols)
    self.pending_wrap = false
  elseif final == "d" then
    local ss = self:screen_start()
    self.cy = common.clamp(ss + math.max(n, 1) - 1, ss, #self.lines)
    self.pending_wrap = false
  elseif final == "J" then
    -- Erase in display. Modes 0/1 only clear the current line from (or up
    -- to) the cursor column onwards; blanking the whole line would wipe
    -- text the shell has just written before the cursor (e.g. fish emits
    -- the prompt and then ESC[J on resize, which used to erase the prompt).
    local mode = tonumber(params[1] or "") or 0
    local function clear_cells(row, from)
      if not row then return end
      for i = #row.ch, from, -1 do
        row.ch[i], row.fg[i], row.bg[i], row.bold[i] = nil, nil, nil, nil
      end
    end
    local function blank_cells(row, to)
      if not row then return end
      for i = 1, to do
        row.ch[i], row.fg[i], row.bg[i], row.bold[i] = " ", false, false, false
      end
    end
    if mode == 2 or mode == 3 then
      for i = self:screen_start(), #self.lines do
        self.lines[i] = self:blank_row()
      end
      if mode == 3 then
        while #self.lines > self.rows do
          table.remove(self.lines, 1)
          self.cy = self.cy - 1
        end
      end
    elseif mode == 1 then
      for i = self:screen_start(), self.cy - 1 do
        self.lines[i] = self:blank_row()
      end
      blank_cells(self.lines[self.cy], self.cx)
    else
      clear_cells(self.lines[self.cy], self.cx)
      for i = self.cy + 1, #self.lines do
        self.lines[i] = self:blank_row()
      end
    end
    if mode == 2 then self.cx, self.cy = 1, self:screen_start() end
  elseif final == "K" then
    local mode = tonumber(params[1] or "") or 0
    local row = self.lines[self.cy]
    if row then
      if mode == 2 then
        self.lines[self.cy] = self:blank_row()
      elseif mode == 1 then
        for i = 1, self.cx do
          row.ch[i], row.fg[i], row.bg[i], row.bold[i] = " ", false, false, false
        end
      else
        for i = #row.ch, self.cx, -1 do
          row.ch[i], row.fg[i], row.bg[i], row.bold[i] = nil, nil, nil, nil
        end
      end
    end
  elseif final == "S" then
    local ss = self:screen_start()
    self:scroll_up(ss + self.region_top - 1, ss + self.region_bottom - 1, math.max(n, 1))
  elseif final == "T" then
    local ss = self:screen_start()
    local rs, re = ss + self.region_top - 1, math.min(ss + self.region_bottom - 1, #self.lines)
    n = math.min(math.max(n, 1), re - rs + 1)
    for i = re, rs + n, -1 do self.lines[i] = self.lines[i - n] end
    for i = rs, rs + n - 1 do self.lines[i] = self:blank_row() end
  elseif final == "L" then
    local ss = self:screen_start()
    local re = math.min(ss + self.region_bottom - 1, #self.lines)
    n = math.min(math.max(n, 1), re - self.cy + 1)
    if n > 0 and self.cy <= re then
      for i = re, self.cy + n, -1 do self.lines[i] = self.lines[i - n] end
      for i = self.cy, self.cy + n - 1 do self.lines[i] = self:blank_row() end
    end
  elseif final == "M" then
    local ss = self:screen_start()
    local re = math.min(ss + self.region_bottom - 1, #self.lines)
    n = math.min(math.max(n, 1), re - self.cy + 1)
    if n > 0 and self.cy <= re then
      for i = self.cy, re - n do self.lines[i] = self.lines[i + n] end
      for i = re - n + 1, re do self.lines[i] = self:blank_row() end
    end
  elseif final == "P" or final == "X" then
    local row = self.lines[self.cy]
    if row then
      n = math.max(n, 1)
      if final == "P" then
        for i = self.cx, #row.ch - n do
          row.ch[i], row.fg[i], row.bg[i], row.bold[i] =
            row.ch[i + n], row.fg[i + n], row.bg[i + n], row.bold[i + n]
        end
        for i = math.max(#row.ch - n + 1, self.cx), #row.ch do
          row.ch[i], row.fg[i], row.bg[i], row.bold[i] = nil, nil, nil, nil
        end
      else
        for i = self.cx, math.min(self.cx + n - 1, #row.ch) do
          row.ch[i], row.fg[i], row.bg[i], row.bold[i] = " ", false, false, false
        end
      end
    end
  elseif final == "c" then
    -- Device Attributes. Interactive shells (fish included) query this
    -- at startup and stall without a reply (fish waits ~10s).
    local q = table.concat(params)
    if q == "" or q == "0" then
      self:reply("\27[?1;2c")
    elseif q == ">" then
      self:reply("\27[>0;95;0c")
    end
  elseif final == "n" then
    -- Device Status Report.
    local mode = tonumber(params[1] or "") or 0
    if mode == 5 or mode == 0 then
      self:reply("\27[0n")
    elseif mode == 6 then
      local r = self.cy - self:screen_start() + 1
      self:reply(string.format("\27[%d;%dR", math.max(r, 1), self.cx))
    end
  elseif final == "m" then
    self:sgr(params)
  elseif final == "r" then
    local top = math.max(tonumber(params[1] or "") or 1, 1)
    local bottom = tonumber(params[2] or "") or self.rows
    bottom = common.clamp(bottom, top, self.rows)
    self.region_top, self.region_bottom = top, bottom
  elseif final == "s" then
    self.saved_cx, self.saved_cy = self.cx, self.cy
  elseif final == "u" then
    if self.saved_cx then
      self.cx = common.clamp(self.saved_cx, 1, self.cols)
      self.cy = common.clamp(self.saved_cy, 1, #self.lines)
    end
    self.pending_wrap = false
  elseif final == "h" or final == "l" then
    self:handle_mode(private, params, final == "h")
  end
end

function TerminalView:handle_mode(private, params, set)
  for _, p in ipairs(params) do
    local n = tonumber(p) or 0
    if private == "?" and (n == 1049 or n == 1047 or n == 1048) then
      if set then
        if not self.alt then
          self.alt = {
            lines = self.lines, cx = self.cx, cy = self.cy,
            fg = self.fg, bg = self.bg, bold = self.bold,
            region_top = self.region_top, region_bottom = self.region_bottom,
          }
          self.lines = {}
          for _ = 1, self.rows do table.insert(self.lines, self:blank_row()) end
          self.cx, self.cy = 1, 1
          self.fg, self.bg, self.bold = nil, nil, false
          self.region_top, self.region_bottom = 1, self.rows
          self.pending_wrap = false
          self.view_top = nil
          self.sel = nil
        end
      elseif self.alt then
        local a = self.alt
        self.alt = nil
        self.lines, self.cx, self.cy = a.lines, a.cx, a.cy
        self.fg, self.bg, self.bold = a.fg, a.bg, a.bold
        self.region_top, self.region_bottom = a.region_top, a.region_bottom
        self.pending_wrap = false
      end
    elseif private == "?" and n == 25 then
      self.show_cursor = set
    end
  end
end

-- Returns the new index after consuming one sequence/char.
-- Incomplete trailing data stays in self.carry for the next chunk.
function TerminalView:parse(data)
  local s = self.carry .. data
  self.carry = ""
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 27 then -- ESC
      if i + 1 > n then self.carry = s:sub(i) break end
      local c2 = s:sub(i + 1, i + 1)
      if c2 == "[" then
        local j = i + 2
        local private = ""
        if s:sub(j, j) == "?" then private, j = "?", j + 1 end
        local pstart = j
        while j <= n and not s:sub(j, j):match("[@-~]") do j = j + 1 end
        if j > n then self.carry = s:sub(i) break end
        local body = s:sub(pstart, j - 1)
        local params = {}
        for p in (body .. ";"):gmatch("([^;]*);") do table.insert(params, p) end
        -- strip intermediates (space..\/) from body end
        while #params > 0 and params[#params]:match("^[ %-/]+$") do
          table.remove(params)
        end
        self:csi(params, private, s:sub(j, j))
        i = j + 1
      elseif c2 == "]" then
        local bel = s:find("\a", i + 2, true)
        local esc = s:find("\27\\", i + 2)
        local e
        if bel and esc then e = math.min(bel, esc) else e = bel or esc end
        if not e then self.carry = s:sub(i) break end
        local body = s:sub(i + 2, e - 1)
        local cmd, arg = body:match("^(%d+);(.*)$")
        if (cmd == "0" or cmd == "2") and arg then
          self.osc_title = arg
        end
        i = (s:sub(e, e) == "\a") and e + 1 or e + 2
      elseif c2 == "P" or c2 == "X" or c2 == "^" or c2 == "_" then
        local bel = s:find("\a", i + 2, true)
        local esc = s:find("\27\\", i + 2)
        local e
        if bel and esc then e = math.min(bel, esc) else e = bel or esc end
        if not e then self.carry = s:sub(i) break end
        i = (s:sub(e, e) == "\a") and e + 1 or e + 2
      elseif c2 == "(" or c2 == ")" or c2 == "#" then
        if i + 2 > n then self.carry = s:sub(i) break end
        i = i + 3
      elseif c2 == "M" then
        local ss = self:screen_start()
        if self.cy <= ss + self.region_top - 1 then
          local rs = ss + self.region_top - 1
          local re = math.min(ss + self.region_bottom - 1, #self.lines)
          for x = re, rs + 1, -1 do self.lines[x] = self.lines[x - 1] end
          self.lines[rs] = self:blank_row()
        else
          self.cy = self.cy - 1
        end
        self.pending_wrap = false
        i = i + 2
      elseif c2 == "c" then
        self.lines = {}
        for _ = 1, self.rows do table.insert(self.lines, self:blank_row()) end
        self.cx, self.cy = 1, 1
        self.fg, self.bg, self.bold = nil, nil, false
        self.pending_wrap = false
        i = i + 2
      elseif c2 == "7" then
        self.saved_cx, self.saved_cy = self.cx, self.cy
        i = i + 2
      elseif c2 == "8" then
        if self.saved_cx then
          self.cx = common.clamp(self.saved_cx, 1, self.cols)
          self.cy = common.clamp(self.saved_cy, 1, #self.lines)
        end
        self.pending_wrap = false
        i = i + 2
      else
        i = i + 2 -- = > and other ignored introducers
      end
    elseif b == 7 then -- BEL
      i = i + 1
    elseif b == 8 then -- BS
      self.cx = math.max(1, self.cx - 1)
      self.pending_wrap = false
      i = i + 1
    elseif b == 9 then -- TAB
      self.cx = math.min(self.cx + 8 - ((self.cx - 1) % 8), self.cols)
      self.pending_wrap = false
      i = i + 1
    elseif b == 10 then -- LF (with CR, like ONLCR)
      self.cx = 1
      self:linefeed()
      i = i + 1
    elseif b == 13 then -- CR
      self.cx = 1
      self.pending_wrap = false
      i = i + 1
    elseif b < 32 then -- other C0: ignore
      self.pending_wrap = false
      i = i + 1
    else
      local b = s:byte(i)
      local need = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
      if b < 0x80 or b >= 0xF5 or b == 0xC0 or b == 0xC1 then
        -- ASCII (single byte) or invalid lead/stray continuation
        self:put(b < 0x80 and s:sub(i, i) or "�")
        i = i + 1
      else
        local have = 1
        while have < need and i + have <= n do
          local c = s:byte(i + have)
          if c < 0x80 or c >= 0xC0 then break end
          have = have + 1
        end
        if have < need then
          if i + have - 1 == n then
            self.carry = s:sub(i) -- truncated at chunk end: carry over
            break
          end
          self:put("�")
          i = i + 1
        else
          self:put(s:sub(i, i + have - 1))
          i = i + have
        end
      end
    end
  end
  -- bound a runaway carry (unterminated escape sequence)
  if #self.carry > 4096 then self.carry = "" end
  core.redraw = true
end

function TerminalView:pump()
  if not self.pty then return end
  while true do
    local chunk = self.pty:read(8192)
    if chunk == nil then
      return true -- EOF
    elseif chunk == "" then
      return false
    end
    self:parse(chunk)
  end
end

-- Process ---------------------------------------------------------------------

function TerminalView:start(cmd)
  local has_pty = pcall(function() return pty end)
  if not has_pty then
    core.error("Terminal needs the pty module (rebuild max-xl)")
    return false
  end
  self.started = true
  if self.pty then pcall(function() self.pty:close() end) end
  self.pty = nil
  self.exit_code = nil
  -- NOTE: no blank prefill. The buffer starts with a single row so fresh
  -- output lands inside the visible window; prefilling `rows` blanks
  -- would push the prompt above the viewport (black screen).
  self.lines = { self:blank_row() }
  self.cx, self.cy = 1, 1
  self.alt = nil
  self.carry = ""
  self.view_top = nil
  self.sel = nil
  self.mouse_selecting = nil
  self.scrollbar_dragging = false
  self.osc_title = nil
  self.fg, self.bg, self.bold = nil, nil, false
  self.region_top, self.region_bottom = 1, self.rows
  local shell = os.getenv("SHELL")
  cmd = cmd or (shell and { shell } or { "/bin/sh" })
  local cwd = core.root_project() and core.root_project().path or nil
  local ok, handle = pcall(pty.start,
    cmd, { cwd = cwd, cols = self.cols, rows = self.rows })
  if not ok or not handle then
    core.error("Could not start terminal: %s", tostring(handle))
    return false
  end
  self.pty = handle
  if not self:is_open() then self:show() end
  core.add_thread(function()
    while self.pty == handle and handle:running() do
      self:pump()
      coroutine.yield(0.02)
    end
    if self.pty ~= handle then return end
    self:pump()
    self.exit_code = handle:returncode()
    if self.pty == handle then
      -- deterministic fd lifecycle: never rely on __gc timing, otherwise
      -- a late close can hit a reused fd number
      pcall(function() handle:close() end)
      self.pty = nil
    end
    core.redraw = true
  end)
  return true
end

function TerminalView:kill()
  if self:is_running() then
    self.pty:kill()
  end
end

function TerminalView:resize(cols, rows)
  cols = math.max(cols, 1)
  rows = math.max(rows, 1)
  if cols == self.cols and rows == self.rows then return end
  local old_ss = self:screen_start()
  local old_rows = self.rows
  -- a full-screen region tracks the size; a custom one (vim-style)
  -- is only clamped, the app re-sets it explicitly after SIGWINCH
  local was_full = (self.region_top == 1 and self.region_bottom == old_rows)
  self.cols, self.rows = cols, rows
  self.cx = common.clamp(self.cx, 1, cols)
  if was_full then
    self.region_top, self.region_bottom = 1, rows
  else
    self.region_top = common.clamp(self.region_top, 1, rows)
    self.region_bottom = common.clamp(self.region_bottom, self.region_top, rows)
  end
  -- keep the cursor on the same visible row across the resize (shrink
  -- moves the screen base up; grow keeps the absolute row). Without
  -- this the cursor strands outside the viewport (invisible typing)
  -- or on a row fish no longer addresses (misplaced redraws).
  local new_ss = self:screen_start()
  local dss = new_ss - old_ss
  self.cy = common.clamp(self.cy + math.max(dss, 0), new_ss, #self.lines)
  self.pending_wrap = false
  -- keep a scrollback position stable; follow mode stays pinned to the tail
  if self.view_top then
    local max_top = self:get_max_view_top()
    if self.view_top >= max_top then
      self.view_top = nil
    else
      self.view_top = common.clamp(self.view_top, 1, max_top)
    end
  end
  if self.pty then pcall(function() self.pty:resize(cols, rows) end) end
end

function TerminalView:update()
  TerminalView.super.update(self)
  -- drive the caret blink (DocView only does this for itself when active)
  if not config.disable_blink and system.window_has_focus(core.window) and self == core.active_view then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end
  if self.view_top and self.view_top >= self:get_max_view_top() then
    self.view_top = nil
  end
  local cols = self:get_visible_cols()
  local rows = self:get_visible_rows()
  if (cols ~= self.cols or rows ~= self.rows)
      and self.size.x > 0 and self.size.y > 0 then
    self:resize(cols, rows)
  end
end

-- Drawing ---------------------------------------------------------------------

-- Selection is stored as two inclusive cell coordinates; sort them so a drag
-- in any direction yields the same text.
local function sorted_selection(sel)
  local l1, c1, l2, c2 = sel[1], sel[2], sel[3], sel[4]
  if l2 < l1 or (l2 == l1 and c2 < c1) then
    return l2, c2, l1, c1
  end
  return l1, c1, l2, c2
end

function TerminalView:get_selection_span(line)
  if not self.sel then return nil end
  local l1, c1, l2, c2 = sorted_selection(self.sel)
  if line < l1 or line > l2 then return nil end
  local from = line == l1 and c1 or 1
  local to = line == l2 and c2 or self.cols
  return from, to
end

function TerminalView:get_selection_text()
  if not self.sel then return "" end
  local l1, c1, l2, c2 = sorted_selection(self.sel)
  local out = {}
  for line = l1, l2 do
    local row = self.lines[line]
    local text = ""
    if row then
      local from = line == l1 and c1 or 1
      local to = math.min(line == l2 and c2 or #row.ch, #row.ch)
      local chars = {}
      for c = from, to do chars[#chars + 1] = row.ch[c] or " " end
      text = table.concat(chars):gsub("%s+$", "")
    end
    out[#out + 1] = text
  end
  return table.concat(out, "\n")
end

function TerminalView:clear_selection()
  if self.sel then
    self.sel = nil
    core.redraw = true
  end
end

function TerminalView:copy_selection()
  local text = self:get_selection_text()
  if text == "" then
    if core.status_view then
      core.status_view:show_message("!", style.dim, "Nothing selected")
    end
    return false
  end
  system.set_clipboard(text)
  if core.status_view then
    core.status_view:show_message("i", style.accent, "Copied to clipboard")
  end
  return true
end

function TerminalView:select_line(line)
  if #self.lines == 0 then return end
  line = common.clamp(line, 1, #self.lines)
  local row = self.lines[line]
  self.sel = { line, 1, line, math.max(1, row and #row.ch or 1) }
  core.redraw = true
end

function TerminalView:select_word(line, col)
  local row = self.lines[line]
  if not row or #row.ch == 0 then return self:select_line(line) end
  if col > #row.ch then
    -- clicked past the end of a line: select the last word
    col = #row.ch
  end
  local function is_word(c) return c ~= nil and c ~= " " and c ~= "\t" end
  if not is_word(row.ch[col]) then
    self.sel = { line, col, line, col }
    core.redraw = true
    return
  end
  local from, to = col, col
  while from > 1 and is_word(row.ch[from - 1]) do from = from - 1 end
  while to < #row.ch and is_word(row.ch[to + 1]) do to = to + 1 end
  self.sel = { line, from, line, to }
  core.redraw = true
end

function TerminalView:select_all()
  local last = #self.lines
  if last < 1 then return end
  while last > 1 and #self.lines[last].ch == 0 do last = last - 1 end
  self.sel = { 1, 1, last, math.max(1, #self.lines[last].ch) }
  core.redraw = true
end

-- Map a screen point to a cell in the visible window.
function TerminalView:resolve_position(x, y)
  local gx, top = self:get_grid_origin()
  local row_h = self:get_row_height()
  local char_w = self:get_char_width()
  local first, last = self:get_view_range()
  local line = first + math.floor((y - top) / row_h)
  line = common.clamp(line, first, math.max(first, last))
  local col = math.floor((x - gx) / char_w) + 1
  col = common.clamp(col, 1, self.cols)
  return line, col
end

function TerminalView:get_scrollbar_rect()
  local total, vis = #self.lines, self:get_visible_rows()
  if total <= vis then return nil end
  local padx, pady = self:get_padding()
  local w = math.max(common.round(4 * SCALE), 2)
  local margin = math.max(common.round(2 * SCALE),
    padx - w - common.round(2 * SCALE))
  local x = common.round(self.position.x + self.size.x - margin - w)
  local y = common.round(self.position.y + pady)
  local h = common.round(self.size.y - pady * 2)
  if h <= 0 then return nil end
  return { x = x, y = y, w = w, h = h }
end

function TerminalView:get_scrollbar_thumb()
  local r = self:get_scrollbar_rect()
  if not r then return nil end
  local total, vis = #self.lines, self:get_visible_rows()
  local thumb_h = math.max(common.round(20 * SCALE), math.floor(r.h * vis / total))
  thumb_h = math.min(thumb_h, r.h)
  local max_top = self:get_max_view_top()
  local ratio = max_top > 1 and (self:get_view_top() - 1) / (max_top - 1) or 0
  local thumb_y = common.round(r.y + (r.h - thumb_h) * ratio)
  return { x = r.x, y = thumb_y, w = r.w, h = thumb_h }
end

function TerminalView:draw_scrollbar()
  local track = self:get_scrollbar_rect()
  if not track then return end
  local thumb = self:get_scrollbar_thumb()
  local C = self.C or style.panel_theme()
  local base = C.dim or style.dim
  local color = (self.scrollbar_dragging or self.scrollbar_hover) and style.accent or base
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  renderer.draw_rect(track.x, track.y, track.w, track.h,
    { base[1], base[2], base[3], 40 })
  renderer.draw_rect(thumb.x, thumb.y, thumb.w, thumb.h, color)
  core.pop_clip_rect()
end

function TerminalView:scrollbar_overlaps_point(x, y)
  local r = self:get_scrollbar_rect()
  if not r then return false end
  local slack = common.round(2 * SCALE)
  return x >= r.x - slack and x <= r.x + r.w + slack
    and y >= r.y and y <= r.y + r.h
end

function TerminalView:scrollbar_drag_to(y)
  local r = self:get_scrollbar_rect()
  local thumb = self:get_scrollbar_thumb()
  if not r or not thumb then return end
  local offset = self.scrollbar_drag_offset or thumb.h / 2
  local top_y = common.clamp(y - offset, r.y, r.y + r.h - thumb.h)
  local ratio = (top_y - r.y) / math.max(1, r.h - thumb.h)
  self:set_view_top(1 + ratio * (self:get_max_view_top() - 1))
end

function TerminalView:draw()
  self.C = style.panel_theme()
  local C = self.C
  self:draw_background(C.terminal_bg)
  local font = self:get_font()
  local row_h = self:get_row_height()
  local char_w = self:get_char_width()
  local cell_w = math.ceil(char_w)
  local first, last = self:get_view_range()
  local ox, oy = self:get_grid_origin()
  local sel_color = C.selection or style.selection
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local y = oy
  for i = first, last do
    local row = self.lines[i]
    local sel_from, sel_to = self:get_selection_span(i)
    local maxc = #row.ch
    if sel_to then maxc = math.max(maxc, math.min(sel_to, self.cols)) end
    for c = 1, maxc do
      -- pixel-aligned columns: fractional advances blur glyphs
      -- progressively toward the end of the row
      local cx = common.round(ox + (c - 1) * char_w)
      local bg = row.bg[c]
      if bg then
        renderer.draw_rect(cx, y, cell_w, row_h, bg)
      end
      if sel_from and c >= sel_from and c <= sel_to then
        renderer.draw_rect(cx, y, cell_w, row_h, sel_color)
      end
      local ch = row.ch[c]
      if ch and ch ~= " " then
        renderer.draw_text(font, ch, cx, y, self:resolve_fg(row.fg[c], row.bold[c]))
      end
    end
    -- cursor (only while following the tail, like a real terminal)
    if self.view_top == nil and self.show_cursor and i == self.cy
        and core.active_view == self
        and not self.mouse_selecting
        and not config.disable_blink
        and (core.blink_timer - core.blink_start) % config.blink_period < config.blink_period / 2 then
      local ccx = common.round(ox + (self.cx - 1) * char_w)
      renderer.draw_rect(ccx, y, cell_w, row_h, style.caret)
      local rowc = self.lines[self.cy]
      local ch = rowc and rowc.ch[self.cx] or " "
      if ch ~= " " then
        renderer.draw_text(font, ch, ccx, y, C.terminal_bg)
      end
    end
    y = y + row_h
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return false end
  local r = self:get_scrollbar_rect()
  if r and self:scrollbar_overlaps_point(x, y) then
    local thumb = self:get_scrollbar_thumb()
    local on_thumb = thumb and y >= thumb.y and y <= thumb.y + thumb.h
      and x >= r.x - common.round(2 * SCALE)
      and x <= r.x + r.w + common.round(2 * SCALE)
    self.scrollbar_dragging = true
    self.scrollbar_drag_offset = on_thumb and (y - thumb.y) or nil
    if not on_thumb then self:scrollbar_drag_to(y) end
    core.redraw = true
    return true
  end
  local line, col = self:resolve_position(x, y)
  if keymap.modkeys["shift"] and self.sel then
    -- shift-click extends the current selection
    self.sel[3], self.sel[4] = line, col
    self.mouse_selecting = { line = line, col = col, snap = nil }
  elseif clicks >= 3 then
    self:select_line(line)
    self.mouse_selecting = { line = line, col = col, snap = "lines" }
  elseif clicks == 2 then
    self:select_word(line, col)
    self.mouse_selecting = { line = line, col = col, snap = "word" }
  else
    self.sel = { line, col, line, col }
    self.mouse_selecting = { line = line, col = col, snap = nil }
  end
  core.redraw = true
  return true
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  local over_scrollbar = self:scrollbar_overlaps_point(x, y)
  if self.scrollbar_hover ~= over_scrollbar then
    self.scrollbar_hover = over_scrollbar
    core.redraw = true
  end
  if self.scrollbar_dragging then
    self:scrollbar_drag_to(y)
    self.cursor = "arrow"
    return
  end
  if self.mouse_selecting then
    -- auto-scroll while dragging past the top/bottom edge of the grid
    local _, top = self:get_grid_origin()
    local row_h = self:get_row_height()
    local grid_h = self:get_visible_rows() * row_h
    if y < top then
      self:scroll_by(math.ceil((top - y) / row_h))
    elseif y > top + grid_h then
      self:scroll_by(-math.ceil((y - top - grid_h) / row_h))
    end
    local line, col = self:resolve_position(x, y)
    if self.mouse_selecting.snap == "lines" then
      local a = self.mouse_selecting.line
      local l1, l2 = math.min(a, line), math.max(a, line)
      local to = 1
      for l = l1, l2 do
        to = math.max(to, #(self.lines[l] and self.lines[l].ch or 0))
      end
      self.sel = { l1, 1, l2, to }
    else
      self.sel[3], self.sel[4] = line, col
    end
    self.cursor = "ibeam"
    core.redraw = true
    return
  end
  self.cursor = over_scrollbar and "arrow" or "ibeam"
end

function TerminalView:on_mouse_released(button, x, y)
  local snap = self.mouse_selecting and self.mouse_selecting.snap
  self.mouse_selecting = nil
  self.scrollbar_dragging = false
  self.scrollbar_drag_offset = nil
  -- a plain click (no drag, no word/line snap) just clears the selection
  if not snap and self.sel then
    local l1, c1, l2, c2 = sorted_selection(self.sel)
    if l1 == l2 and c1 == c2 then self.sel = nil end
  end
  core.redraw = true
end

function TerminalView:on_mouse_left()
  if self.scrollbar_hover then
    self.scrollbar_hover = false
    core.redraw = true
  end
end

function TerminalView:on_mouse_wheel(y, x)
  if y == 0 then return false end
  local rows = config.plugins.terminal.scroll_wheel_rows or 3
  self:scroll_by(y * rows)
  return true
end

function TerminalView:on_text_input(text)
  if text == "" then return end
  self:clear_selection()
  self:scroll_to_bottom()
  if self.pty then self.pty:write(text) end
end

-- Send a key sequence to the shell, leaving scrollback/selection mode first.
function TerminalView:send_key(data)
  self:clear_selection()
  self:scroll_to_bottom()
  if self.pty then self.pty:write(data) end
  core.redraw = true
end

-- Placement: bottom tab next to the console ------------------------------------

function TerminalView:show()
  if self:is_open() then
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then node:set_active_view(self) end
  else
    local tabbed = false
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "ConsoleView" then
        local node = core.root_view.root_node:get_node_for_view(v)
        if node then
          node:add_view(self)
          core.root_view.root_node:update_layout()
          tabbed = true
          break
        end
      end
    end
    if not tabbed then
      local node = core.root_view:get_active_node_default()
      local leaf = node:split("down", self)
      local parent = leaf:get_parent_node(core.root_view.root_node)
      if parent then parent.divider = 0.75 end
      core.root_view.root_node:update_layout()
    end
  end
  if not self.started then self:start() end
  core.redraw = true
end

function TerminalView:hide()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then
    node:close_view(core.root_view.root_node, self)
    core.redraw = true
  end
end

function TerminalView:toggle()
  if self:is_open() then self:hide() else self:show() end
end

-- Instantiate ------------------------------------------------------------------

local view = TerminalView()

-- Commands ---------------------------------------------------------------------

command.add(nil, {
  ["terminal:toggle"] = function() view:toggle() end,
  ["terminal:show"] = function() view:show() end,
  ["terminal:hide"] = function() view:hide() end,
  ["terminal:new-shell"] = function() view:start() end,
  ["terminal:kill"] = function() view:kill() end,
})

command.add(TerminalView, {
  ["terminal:send-return"] = function(v) v:send_key("\r") end,
  ["terminal:send-backspace"] = function(v) v:send_key("\127") end,
  ["terminal:send-tab"] = function(v) v:send_key("\t") end,
  ["terminal:send-escape"] = function(v) v:send_key("\27") end,
  ["terminal:send-up"] = function(v) v:send_key("\27[A") end,
  ["terminal:send-down"] = function(v) v:send_key("\27[B") end,
  ["terminal:send-right"] = function(v) v:send_key("\27[C") end,
  ["terminal:send-left"] = function(v) v:send_key("\27[D") end,
  ["terminal:send-home"] = function(v) v:send_key("\27[H") end,
  ["terminal:send-end"] = function(v) v:send_key("\27[F") end,
  ["terminal:send-pageup"] = function(v) v:send_key("\27[5~") end,
  ["terminal:send-pagedown"] = function(v) v:send_key("\27[6~") end,
  ["terminal:send-delete"] = function(v) v:send_key("\27[3~") end,
  ["terminal:send-interrupt"] = function(v) v:send_key("\3") end,
  ["terminal:send-eof"] = function(v) v:send_key("\4") end,
  ["terminal:paste"] = function(v)
    local text = system.get_clipboard()
    if text and text ~= "" then v:send_key(text) end
  end,
  ["terminal:copy"] = function(v) v:copy_selection() end,
  ["terminal:select-all"] = function(v) v:select_all() end,
  ["terminal:scroll-up"] = function(v) return v:scroll_by(1) end,
  ["terminal:scroll-down"] = function(v) return v:scroll_by(-1) end,
  ["terminal:scroll-page-up"] = function(v) return v:scroll_by(v:get_visible_rows()) end,
  ["terminal:scroll-page-down"] = function(v) return v:scroll_by(-v:get_visible_rows()) end,
  ["terminal:scroll-to-top"] = function(v) v:set_view_top(1) end,
  ["terminal:scroll-to-bottom"] = function(v) v:scroll_to_bottom() end,
})

keymap.add {
  ["ctrl+shift+t"] = "terminal:toggle",
  ["escape"] = "terminal:send-escape",
  ["return"] = "terminal:send-return",
  ["backspace"] = "terminal:send-backspace",
  ["tab"] = "terminal:send-tab",
  ["up"] = "terminal:send-up",
  ["down"] = "terminal:send-down",
  ["right"] = "terminal:send-right",
  ["left"] = "terminal:send-left",
  ["home"] = "terminal:send-home",
  ["end"] = "terminal:send-end",
  ["pageup"] = "terminal:send-pageup",
  ["pagedown"] = "terminal:send-pagedown",
  ["delete"] = "terminal:send-delete",
  ["ctrl+c"] = "terminal:send-interrupt",
  ["ctrl+d"] = "terminal:send-eof",
  ["ctrl+v"] = "terminal:paste",
  -- selection and scrollback
  ["ctrl+shift+c"] = "terminal:copy",
  ["ctrl+shift+a"] = "terminal:select-all",
  ["shift+pageup"] = "terminal:scroll-page-up",
  ["shift+pagedown"] = "terminal:scroll-page-down",
  ["ctrl+shift+home"] = "terminal:scroll-to-top",
  ["ctrl+shift+end"] = "terminal:scroll-to-bottom",
}

-- Register the terminal button on the activity bar (panel selector).
local ok_activitybar, activitybar = pcall(require, "plugins.activitybar")
if ok_activitybar then
  activitybar.add_button({
    id = "terminal",
    tooltip = "Terminal",
    draw = function(r, active, hovered)
      local color = active and style.accent or style.text
      local pad = math.floor(r.w * 0.22)
      local top = r.y + 8
      local bot = r.y + r.h - 8
      renderer.draw_rect(r.x + pad, top, r.w - 2 * pad, 1, color)
      renderer.draw_rect(r.x + pad, bot - 1, r.w - 2 * pad, 1, color)
      renderer.draw_rect(r.x + pad, top, 1, bot - top, color)
      renderer.draw_rect(r.x + r.w - pad - 1, top, 1, bot - top, color)
      renderer.draw_rect(r.x + pad + 4, bot - 6, 4, 4, color)
    end,
    show = function() view:show() if not view:is_running() then view:start() end end,
    hide = function() view:hide() end,
    is_active = function() return view:is_open() end,
  })
end

return view
