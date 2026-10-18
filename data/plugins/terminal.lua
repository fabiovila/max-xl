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
}, config.plugins.terminal)

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
  self.view_y = 0
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

function TerminalView:get_row_height()
  return style.code_font:get_height()
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
  while #self.lines > cap do
    table.remove(self.lines, 1)
    self.cy = self.cy - 1
  end
  if self.cy < 1 then self.cy = 1 end
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
          self.view_y = 0
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
  if self.view_y == 0 then core.redraw = true end
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
  self.view_y = 0
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
  -- pin to live tail so content doesn't jump around on resize
  self.view_y = 0
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
  local row_h = self:get_row_height()
  local cols = math.max(1, math.floor(self.size.x / style.code_font:get_width("M")))
  local rows = math.max(1, math.floor(self.size.y / row_h))
  if (cols ~= self.cols or rows ~= self.rows) and self.size.x > 0 then
    self:resize(cols, rows)
  end
end

-- Drawing ---------------------------------------------------------------------

function TerminalView:draw()
  self.C = style.panel_theme()
  local C = self.C
  self:draw_background(C.terminal_bg)
  local row_h = self:get_row_height()
  local font = style.code_font
  local char_w = font:get_width("M")
  local vis_rows = math.max(1, math.floor(self.size.y / row_h))
  local total = #self.lines
  self.view_y = common.clamp(self.view_y, 0, math.max(0, total - 1))
  local last = total - self.view_y
  local first = math.max(1, last - vis_rows + 1)
  local ox, oy = self:get_content_offset()
  -- pixel-align like DocView does: fractional origins blur glyphs
  -- (subpixel fringes) on LCD screens
  ox, oy = common.round(ox), common.round(oy)
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local y = common.round(oy + self.size.y - (last - first + 1) * row_h)
  for i = first, last do
    local row = self.lines[i]
    for c = 1, #row.ch do
      -- pixel-aligned columns: fractional advances blur glyphs
      -- progressively toward the end of the row
      local cx = common.round(ox + (c - 1) * char_w)
      local fg = self:resolve_fg(row.fg[c], row.bold[c])
      local bg = row.bg[c]
      if bg then
        renderer.draw_rect(cx, y, math.ceil(char_w), row_h, bg)
      end
      if row.ch[c] ~= " " then
        renderer.draw_text(font, row.ch[c], cx, y, fg)
      end
    end
    -- cursor
    if self.view_y == 0 and self.show_cursor and i == self.cy
        and core.active_view == self
        and not config.disable_blink
        and (core.blink_timer - core.blink_start) % config.blink_period < config.blink_period / 2 then
      local ccx = common.round(ox + (self.cx - 1) * char_w)
      renderer.draw_rect(ccx, y, math.ceil(char_w), row_h, style.caret)
      local rowc = self.lines[self.cy]
      local ch = rowc and rowc.ch[self.cx] or " "
      if ch ~= " " then
        renderer.draw_text(font, ch, ccx, y, C.terminal_bg)
      end
    end
    y = y + row_h
  end
  core.pop_clip_rect()
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return false end
  return true
end

function TerminalView:on_mouse_wheel(y, x)
  local row_h = self:get_row_height()
  local vis_rows = math.max(1, math.floor(self.size.y / row_h))
  local max_up = math.max(0, #self.lines - vis_rows)
  if y ~= 0 then
    self.view_y = common.clamp(self.view_y + y * 3, 0, max_up)
    core.redraw = true
    return true
  end
  return false
end

function TerminalView:on_text_input(text)
  if self.pty and text ~= "" then
    self.pty:write(text)
  end
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
  ["terminal:send-return"] = function(v) if v.pty then v.pty:write("\r") end end,
  ["terminal:send-backspace"] = function(v) if v.pty then v.pty:write("\127") end end,
  ["terminal:send-tab"] = function(v) if v.pty then v.pty:write("\t") end end,
  ["terminal:send-escape"] = function(v) if v.pty then v.pty:write("\27") end end,
  ["terminal:send-up"] = function(v) if v.pty then v.pty:write("\27[A") end end,
  ["terminal:send-down"] = function(v) if v.pty then v.pty:write("\27[B") end end,
  ["terminal:send-right"] = function(v) if v.pty then v.pty:write("\27[C") end end,
  ["terminal:send-left"] = function(v) if v.pty then v.pty:write("\27[D") end end,
  ["terminal:send-home"] = function(v) if v.pty then v.pty:write("\27[H") end end,
  ["terminal:send-end"] = function(v) if v.pty then v.pty:write("\27[F") end end,
  ["terminal:send-escape"] = function(v) if v.pty then v.pty:write("\27") end end,
  ["terminal:send-pageup"] = function(v) if v.pty then v.pty:write("\27[5~") end end,
  ["terminal:send-pagedown"] = function(v) if v.pty then v.pty:write("\27[6~") end end,
  ["terminal:send-delete"] = function(v) if v.pty then v.pty:write("\27[3~") end end,
  ["terminal:send-interrupt"] = function(v) if v.pty then v.pty:write("\3") end end,
  ["terminal:send-eof"] = function(v) if v.pty then v.pty:write("\4") end end,
  ["terminal:paste"] = function(v)
    local text = system.get_clipboard()
    if v.pty and text and text ~= "" then v.pty:write(text) end
  end,
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
