-- mod-version:4
-- Debug UI for plugins.gdb: Run & Debug sidebar, floating toolbar, debug
-- console, gutter breakpoints and the stopped-line highlight.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local RootView = require "core.rootview"
local ContextMenu = require "core.contextmenu"
local gdb = require "plugins.gdb"

config.plugins.gdbui = common.merge({
  sidebar_size = 280 * SCALE,
  console_height = 220 * SCALE,
}, config.plugins.gdbui)

local M = {}
gdb.ui = M

-- Forward declarations: these views are created further down, but the helper
-- below (and the console's split logic) references them by identity.
local console, panel, debug_status_item

---True when every view in a leaf belongs to the debug UI (console/panel).
local function is_debug_leaf(node)
  if not node or not node.views or #node.views == 0 then return false end
  for _, v in ipairs(node.views) do
    if v ~= console and v ~= panel then return false end
  end
  return true
end

local function session() return gdb.session end

local function basename(path)
  return (path or ""):match("([^/\\]+)$") or path or ""
end

local function short_path(path)
  local root = core.root_project()
  if root and path and path:sub(1, #root.path + 1) == root.path .. PATHSEP then
    return path:sub(#root.path + 2)
  end
  return path
end

local function state_label()
  if gdb.state == "starting" then return "starting"
  elseif gdb.state == "running" then return "running"
  elseif gdb.state == "paused" then
    local _, line, cur = gdb.current_location()
    if cur and cur.file then
      return string.format("paused at %s:%d", basename(cur.file), line or 0)
    end
    return "paused"
  elseif gdb.state == "exited" then return "exited"
  end
  return "idle"
end

-- Debug console ---------------------------------------------------------------

---@class plugins.gdbui.console : core.view
local DebugConsole = View:extend()

function DebugConsole:__tostring() return "DebugConsole" end

function DebugConsole:new()
  DebugConsole.super.new(self)
  self.scrollable = false
  self.lines = {}
  self.partial = nil
  self.partial_kind = "output"
  self.offset = 0
  self.follow = true
  self.input = ""
  self.caret = 1
  self.history = {}
  self.history_idx = 0
  self.draft = ""
end

function DebugConsole:get_name() return "Debug Console" end

function DebugConsole:is_open()
  return core.root_view.root_node:get_node_for_view(self) ~= nil
end

function DebugConsole:get_row_height()
  return style.code_font:get_height()
end

function DebugConsole:get_input_height()
  return self:get_row_height() + 6 * SCALE
end

function DebugConsole:flush_partial()
  if self.partial and #self.partial > 0 then
    table.insert(self.lines, { text = self.partial, kind = self.partial_kind })
    self.partial = nil
  end
end

function DebugConsole:append(text, kind)
  kind = kind or "output"
  if text == nil then return end
  local data = (self.partial or "") .. tostring(text)
  self.partial = nil
  self.partial_kind = kind
  local start = 1
  while true do
    local nl = data:find("\n", start, true)
    if not nl then break end
    local line = data:sub(start, nl - 1):gsub("\r$", "")
    table.insert(self.lines, { text = line, kind = kind })
    start = nl + 1
  end
  if start <= #data then self.partial = data:sub(start) end
  while #self.lines > 5000 do table.remove(self.lines, 1) end
  core.redraw = true
end

function DebugConsole:clear()
  self.lines = {}
  self.partial = nil
  self.offset = 0
  self.follow = true
  core.redraw = true
end

function DebugConsole:output_height()
  local ih = self:get_input_height()
  return math.max(0, self.size.y - ih)
end

function DebugConsole:max_offset()
  return math.max(0, #self.lines * self:get_row_height() - self:output_height())
end

function DebugConsole:update()
  DebugConsole.super.update(self)
  if self.follow then
    self.offset = self:max_offset()
  else
    self.offset = common.clamp(self.offset, 0, self:max_offset())
  end
end

local CONSOLE_COLORS = {
  error = function() return style.error end,
  log = function() return style.dim end,
  info = function() return style.accent end,
}

function DebugConsole:draw()
  self:draw_background(style.background)
  local row_h = self:get_row_height()
  local ih = self:get_input_height()
  local ox, oy = self.position.x, self.position.y
  local wh = self:output_height()
  core.push_clip_rect(ox, oy, self.size.x, wh)
  local first = math.max(1, math.floor(self.offset / row_h) + 1)
  local y = oy + (first - 1) * row_h - self.offset
  for i = first, #self.lines do
    if y > oy + wh then break end
    local line = self.lines[i]
    local color = (CONSOLE_COLORS[line.kind] or function() return style.text end)()
    common.draw_text(style.code_font, color, line.text ~= "" and line.text or " ",
      "left", ox + style.padding.x, y, self.size.x - style.padding.x * 2, row_h)
    y = y + row_h
  end
  -- partial line (program output/prompt without a trailing newline)
  if self.partial and self.partial ~= "" and y < oy + wh then
    local color = (CONSOLE_COLORS[self.partial_kind] or function() return style.text end)()
    common.draw_text(style.code_font, color, self.partial, "left",
      ox + style.padding.x, y, self.size.x - style.padding.x * 2, row_h)
  end
  core.pop_clip_rect()

  -- input row
  local iy = oy + wh
  renderer.draw_rect(ox, iy, self.size.x, ih, style.background3)
  renderer.draw_rect(ox, iy, self.size.x, 1, style.divider)
  local pad = style.padding.x
  local prefix_w = style.code_font:get_width("(gdb) ")
  common.draw_text(style.code_font, style.accent, "(gdb) ", "left",
    ox + pad, iy + 3 * SCALE, prefix_w, row_h)
  local tx = ox + pad + prefix_w
  local maxw = self.size.x - pad * 2 - prefix_w
  common.draw_text(style.code_font, style.text, self.input, "left",
    tx, iy + 3 * SCALE, maxw, row_h)
  if core.active_view == self and (config.disable_blink
      or (core.blink_timer - core.blink_start) % config.blink_period < config.blink_period / 2) then
    local before = self.input:sub(1, self.caret - 1)
    local cx = tx + style.code_font:get_width(before)
    renderer.draw_rect(cx, iy + 3 * SCALE, 2 * SCALE, row_h, style.caret)
  end
end

function DebugConsole:on_mouse_wheel(y, x)
  self.follow = false
  self.offset = common.clamp(self.offset - y * self:get_row_height() * 3,
    0, self:max_offset())
  if self.offset >= self:max_offset() then self.follow = true end
  core.redraw = true
  return true
end

function DebugConsole:on_mouse_pressed(button, x, y, clicks)
  local caught = DebugConsole.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  if button == "left" then
    core.set_active_view(self)
    return true
  end
  return false
end

local function clamp_caret(console)
  console.caret = common.clamp(console.caret, 1, #console.input + 1)
end

function DebugConsole:on_text_input(text)
  if not text or text == "" then return end
  text = text:gsub("[\r\n]", "")
  self.input = self.input:sub(1, self.caret - 1) .. text .. self.input:sub(self.caret)
  self.caret = self.caret + #text
  clamp_caret(self)
  core.blink_reset()
end

function DebugConsole:submit()
  local text = self.input
  self.input = ""
  self.caret = 1
  self.history_idx = 0
  self.draft = ""
  if text:match("%S") then
    table.insert(self.history, 1, text)
    while #self.history > 50 do table.remove(self.history) end
    if gdb.session then
      gdb.execute(text)
    else
      self:append("no active debug session (start one with F5)", "error")
    end
  end
  self.follow = true
  core.redraw = true
end

function DebugConsole:history_move(delta)
  if #self.history == 0 then return end
  if self.history_idx == 0 then self.draft = self.input end
  self.history_idx = common.clamp(self.history_idx + delta, 0, #self.history)
  if self.history_idx == 0 then
    self.input = self.draft
  else
    self.input = self.history[self.history_idx]
  end
  self.caret = #self.input + 1
end

function DebugConsole:on_key_pressed(key)
  if key == "backspace" then
    if self.caret > 1 then
      self.input = self.input:sub(1, self.caret - 2) .. self.input:sub(self.caret)
      self.caret = self.caret - 1
    end
  elseif key == "delete" then
    if self.caret <= #self.input then
      self.input = self.input:sub(1, self.caret - 1) .. self.input:sub(self.caret + 1)
    end
  elseif key == "left" then
    self.caret = self.caret - 1
  elseif key == "right" then
    self.caret = self.caret + 1
  elseif key == "home" then
    self.caret = 1
  elseif key == "end" then
    self.caret = #self.input + 1
  elseif key == "up" then
    self:history_move(-1)
  elseif key == "down" then
    self:history_move(1)
  elseif key == "return" or key == "kp_enter" then
    self:submit()
  elseif key == "escape" then
    self.input = ""
    self.caret = 1
  else
    return false
  end
  clamp_caret(self)
  core.blink_reset()
  core.redraw = true
  return true
end

function DebugConsole:show()
  if self:is_open() then
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then node:set_active_view(self) end
    return
  end
  local node = core.root_view:get_active_node_default()
  -- Never split the sidebar or the console itself: use the editor area.
  if node.locked or is_debug_leaf(node) then
    local primary = core.root_view:get_primary_node()
    if primary and not primary.locked then node = primary end
  end
  local leaf = node:split("down", self)
  local parent = leaf:get_parent_node(core.root_view.root_node)
  if parent then parent.divider = 0.72 end
  core.root_view.root_node:update_layout()
  core.redraw = true
end

function DebugConsole:hide()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then
    node:close_view(core.root_view.root_node, self)
    core.redraw = true
  end
end

function DebugConsole:toggle()
  if self:is_open() then self:hide() else self:show() end
end

console = DebugConsole()

-- Forward declaration (defined after the panel; used by its click handler).
local open_source

-- Sidebar panel ---------------------------------------------------------------

---@class plugins.gdbui.panel : core.view
local DebugPanel = View:extend()

function DebugPanel:__tostring() return "DebugPanel" end

function DebugPanel:new()
  DebugPanel.super.new(self)
  self.scrollable = false
  self.visible = false
  self.init_size = true
  self.target_size = config.plugins.gdbui.sidebar_size
  self.font = style.font:copy(13 * SCALE)
  self.scroll_y = 0
  self.rows = {}
  self.collapsed = {}
  self.hover_row = nil
  self.hover_action = nil
end

function DebugPanel:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function DebugPanel:get_name() return "Run and Debug" end

function DebugPanel:on_scale_change(new_scale)
  self.font = style.font:copy(13 * new_scale)
end

function DebugPanel:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "debugpanel")
  end
  DebugPanel.super.update(self)
end

function DebugPanel:get_row_height()
  return self.font:get_height() + 4 * SCALE
end

local function get_treeview()
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if tostring(view) == "TreeView" then return view end
  end
end

function DebugPanel:show()
  local ab_ok, ab = pcall(require, "plugins.activitybar")
  if ab_ok then ab.show_only("debug") end
  local tree = get_treeview()
  if tree then tree.visible = false end
  self.visible = true
  gdb.load_project_breakpoints()
  core.set_active_view(self)
  core.redraw = true
end

function DebugPanel:hide(restore_tree)
  if not self.visible then return end
  self.visible = false
  if restore_tree == nil or restore_tree then
    local tree = get_treeview()
    if tree then tree.visible = true end
  end
  core.redraw = true
end

function DebugPanel:toggle()
  if self.visible then self:hide(true) else self:show() end
end

function DebugPanel:add_row(rows, row)
  row.y = self._row_y or 0
  row.h = self:get_row_height()
  self._row_y = row.y + row.h
  rows[#rows + 1] = row
  return row
end

function DebugPanel:add_section(rows, key, label, count)
  self:add_row(rows, { kind = "section", key = key, label = label, count = count })
end

local function each_var(panel, rows, list, depth)
  for _, v in ipairs(list) do
    if list ~= panel._root_vars then v.depth = depth end
    panel:add_row(rows, { kind = "var", var = v, depth = depth })
    if v.expanded and v.children then
      each_var(panel, rows, v.children, depth + 1)
    end
  end
end

function DebugPanel:build_rows()
  local rows = {}
  self._row_y = 0
  local s = session()

  -- breakpoints
  local bps = gdb.iter_breakpoints()
  self:add_section(rows, "breakpoints", "BREAKPOINTS", #bps)
  if not self.collapsed.breakpoints then
    for _, entry in ipairs(bps) do
      self:add_row(rows, { kind = "bp", entry = entry })
    end
    if #bps == 0 then
      self:add_row(rows, { kind = "hint", text = "No breakpoints (F9 toggles)" })
    end
  end

  if s then
    local frames = s.frames or {}
    self:add_section(rows, "stack", "CALL STACK", #frames)
    if not self.collapsed.stack then
      for i, f in ipairs(frames) do
        self:add_row(rows, { kind = "frame", frame = f, level = tonumber(f.level) or (i - 1) })
      end
      if #frames == 0 then
        self:add_row(rows, { kind = "hint", text = gdb.state == "paused" and "Loading…" or "Not running" })
      end
    end

    local vars = s.variables or {}
    if gdb.state == "paused" or #vars > 0 then
      self:add_section(rows, "variables", "VARIABLES", #vars)
      if not self.collapsed.variables then
        self._root_vars = vars
        each_var(self, rows, vars, 0)
        if #vars == 0 then
          self:add_row(rows, { kind = "hint", text = "No locals in this frame" })
        end
      end
    end

    local threads = s.threads or {}
    if #threads > 1 then
      self:add_section(rows, "threads", "THREADS", #threads)
      if not self.collapsed.threads then
        for _, t in ipairs(threads) do
          self:add_row(rows, { kind = "thread", thread = t })
        end
      end
    end

    if config.plugins.gdb.show_registers and #(s.registers or {}) > 0 then
      self:add_section(rows, "registers", "REGISTERS", #s.registers)
      if not self.collapsed.registers then
        for _, r in ipairs(s.registers) do
          self:add_row(rows, { kind = "register", reg = r })
        end
      end
    end
  end

  self.rows = rows
  self.content_h = self._row_y or 0
end

function DebugPanel:draw()
  if not self.visible then return end
  if self.size.x < 10 then return end
  local C = style.panel_theme()
  local F = self.font or style.font
  self:draw_background(C.panel_bg)
  local x, y = self.position.x, self.position.y
  local w = self.size.x
  local row_h = self:get_row_height()
  local pad = 6 * SCALE
  local header_h = row_h + 2 * SCALE

  renderer.draw_rect(x, y, w, header_h, C.header_bg)
  common.draw_text(F, C.header_text, "RUN AND DEBUG", "left", x + pad, y, w - 26, header_h)
  self.close_rect = { x = x + w - 22 * SCALE, y = y, w = 22 * SCALE, h = header_h }
  common.draw_text(F, C.header_text, "x", "center",
    self.close_rect.x, self.close_rect.y, self.close_rect.w, self.close_rect.h)

  y = y + header_h
  -- launch configuration row
  local cfg = gdb.last_config
  local cfg_name = cfg and cfg.name or
    (gdb.has_configs() and "select configuration" or "no configuration")
  local config_h = row_h + pad
  self.config_rect = { x = x + pad, y = y + 2 * SCALE, w = w - 2 * pad - 92 * SCALE, h = row_h }
  self.run_rect = { x = x + w - pad - 86 * SCALE, y = y + 2 * SCALE, w = 86 * SCALE, h = row_h }
  common.draw_text(F, C.dim, "config:", "left", x + pad, y + 2 * SCALE,
    F:get_width("config: ") + 2, row_h)
  common.draw_text(F, C.text, cfg_name, "left",
    x + pad + F:get_width("config: "), y + 2 * SCALE,
    self.config_rect.w - F:get_width("config: "), row_h)
  local label, color = "Start", C.accent
  if gdb.state == "starting" then label, color = "Starting", C.dim
  elseif gdb.state == "running" then label, color = "Pause", C.accent
  elseif gdb.state == "paused" then label, color = "Continue", C.accent
  elseif gdb.state == "exited" then label, color = "Restart", C.accent end
  renderer.draw_rect(self.run_rect.x, self.run_rect.y, self.run_rect.w, self.run_rect.h,
    self.hover_action == "run" and C.highlight or C.field_bg)
  common.draw_text(F, color, label, "center", self.run_rect.x, self.run_rect.y,
    self.run_rect.w, self.run_rect.h)
  y = y + config_h

  -- rows
  self:build_rows()
  local avail = self.position.y + self.size.y - y
  self.rows_origin_y = y
  self.max_scroll = math.max(0, self.content_h - avail)
  self.scroll_y = common.clamp(self.scroll_y, 0, self.max_scroll)
  core.push_clip_rect(x, y, w, avail)
  local ry = y - self.scroll_y
  local content_x = x + pad
  for idx, row in ipairs(self.rows) do
    if ry + row.h > y and ry < y + avail then
      local hovered = self.hover_row == idx
      local row_rect = { x = x, y = ry, w = w, h = row.h }
      if hovered and row.kind ~= "section" then
        renderer.draw_rect(x, ry, w, row.h, C.highlight)
      end
      if row.kind == "section" then
        renderer.draw_rect(x, ry, w, row.h, C.field_bg)
        local mark = self.collapsed[row.key] and "+" or "-"
        common.draw_text(F, C.dim, mark, "left", content_x, ry, 10 * SCALE, row.h)
        common.draw_text(F, C.text, row.label .. (row.count and (" " .. row.count) or ""),
          "left", content_x + 11 * SCALE, ry, w - 20 * SCALE, row.h)
      elseif row.kind == "hint" then
        common.draw_text(F, C.dim, row.text, "left", content_x, ry, w - 2 * pad, row.h)
      elseif row.kind == "bp" then
        local bp = row.entry.bp
        local dot_color = bp.enabled and config.plugins.gdb.breakpoint_color or C.dim
        if self.hover_row == idx and self.hover_action == "bp-toggle" then dot_color = C.accent end
        renderer.draw_rect(content_x, ry + row.h / 2 - 3 * SCALE, 6 * SCALE, 6 * SCALE, dot_color)
        local text = basename(row.entry.file) .. ":" .. row.entry.line
        local tx = content_x + 12 * SCALE
        common.draw_text(F, bp.enabled and C.text or C.dim, text, "left", tx, ry,
          w - tx + x - 24 * SCALE, row.h)
        if bp.condition and bp.condition ~= "" then
          common.draw_text(F, C.dim, "[" .. bp.condition .. "]", "left",
            tx + F:get_width(text) + 6 * SCALE, ry, 90 * SCALE, row.h)
        end
        common.draw_text(F, (self.hover_row == idx and self.hover_action == "bp-remove")
          and C.warn or C.dim, "x", "center", x + w - 20 * SCALE, ry, 16 * SCALE, row.h)
      elseif row.kind == "frame" then
        local f = row.frame
        local cur = (row.level == (session() and session().selected_frame or 0))
        local color = cur and C.accent or C.text
        local text = string.format("#%d %s", row.level, f.func or "??")
        common.draw_text(F, color, text, "left", content_x, ry, w * 0.55, row.h)
        local loc = f.file and string.format("%s:%s", basename(f.file), f.line or "?") or (f.addr or "")
        common.draw_text(F, C.dim, loc, "right", x + pad, ry, w - 2 * pad, row.h)
      elseif row.kind == "var" then
        local v = row.var
        local vx = content_x + (row.depth or 0) * 10 * SCALE
        if v.expandable then
          common.draw_text(F, C.dim, v.expanded and "-" or "+", "left", vx, ry, 10 * SCALE, row.h)
        end
        vx = vx + 10 * SCALE
        local val = v.value
        if val == nil then val = v.expanded and "" or "{…}" end
        local text = v.name .. " = " .. tostring(val)
        common.draw_text(F, C.text, text, "left", vx, ry, w - (vx - x) - 6 * SCALE, row.h)
      elseif row.kind == "thread" then
        local s2 = session()
        local t = row.thread
        local id = tostring(t.id)
        local cur = s2 and tostring(s2.selected_thread) == id
        common.draw_text(F, cur and C.accent or C.text, (cur and "*" or " ") .. "thread " .. id,
          "left", content_x, ry, w * 0.4, row.h)
        common.draw_text(F, C.dim, t.state or (t.name or ""), "right",
          x + pad, ry, w - 2 * pad, row.h)
      elseif row.kind == "register" then
        common.draw_text(F, C.dim, row.reg.name, "left", content_x, ry, 60 * SCALE, row.h)
        common.draw_text(F, C.text, row.reg.value or "", "left",
          content_x + 50 * SCALE, ry, w - 60 * SCALE, row.h)
      end
    end
    ry = ry + row.h
  end
  core.pop_clip_rect()

  if self.max_scroll > 0 and avail > 0 then
    local track_h = avail
    local thumb_h = math.max(12 * SCALE, track_h * avail / math.max(1, self.content_h))
    local thumb_y = y + (track_h - thumb_h) * (self.scroll_y / self.max_scroll)
    renderer.draw_rect(x + w - 3 * SCALE, thumb_y, 3 * SCALE, thumb_h, C.dim)
  end

  self.C = C
end

function DebugPanel:row_at(x, y)
  if not self.rows_origin_y then return nil end
  if y < self.rows_origin_y then return nil end
  local cy = y - self.rows_origin_y + self.scroll_y
  for idx, row in ipairs(self.rows) do
    if cy >= row.y and cy < row.y + row.h then return idx, row end
  end
end

local function in_rect(x, y, r)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function DebugPanel:on_mouse_moved(x, y, ...)
  DebugPanel.super.on_mouse_moved(self, x, y, ...)
  self.hover_action = nil
  if in_rect(x, y, self.close_rect) then
    self.hover_action = "close"
  elseif in_rect(x, y, self.run_rect) then
    self.hover_action = "run"
    self.cursor = "arrow"
    return
  elseif in_rect(x, y, self.config_rect) then
    self.hover_action = "config"
    self.cursor = "arrow"
    return
  end
  local idx, row = self:row_at(x, y)
  self.hover_row = idx
  if row and row.kind == "bp" then
    if x < self.position.x + 20 * SCALE then
      self.hover_action = "bp-toggle"
    elseif x > self.position.x + self.size.x - 26 * SCALE then
      self.hover_action = "bp-remove"
    end
  end
  self.cursor = "arrow"
end

function DebugPanel:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return false end
  if button == "left" then
    if in_rect(x, y, self.close_rect) then
      self:hide(true)
      return true
    elseif in_rect(x, y, self.run_rect) then
      if gdb.state == "running" then
        command.perform("debug:pause")
      elseif gdb.state == "exited" then
        command.perform("debug:restart")
      else
        command.perform("debug:start")
      end
      return true
    elseif in_rect(x, y, self.config_rect) then
      command.perform("debug:select-config")
      return true
    end
    local idx, row = self:row_at(x, y)
    if row then
      if row.kind == "section" then
        self.collapsed[row.key] = not self.collapsed[row.key]
      elseif row.kind == "bp" then
        local entry = row.entry
        if x < self.position.x + 20 * SCALE then
          gdb.toggle_breakpoint_enabled(entry.file, entry.line)
        elseif x > self.position.x + self.size.x - 26 * SCALE then
          gdb.remove_breakpoint(entry.file, entry.line)
        else
          open_source(entry.file, entry.line)
        end
      elseif row.kind == "frame" then
        if session() then session():select_frame(row.level) end
      elseif row.kind == "var" then
        if session() then session():expand_variable(row.var) end
      elseif row.kind == "thread" then
        if session() then session():select_thread(row.thread.id) end
      end
      core.redraw = true
      return true
    end
  end
  return DebugPanel.super.on_mouse_pressed(self, button, x, y, clicks)
end

function DebugPanel:on_mouse_wheel(y, x)
  self.scroll_y = common.clamp(self.scroll_y - y * self:get_row_height() * 3,
    0, self.max_scroll or 0)
  core.redraw = true
  return true
end

panel = DebugPanel()

-- Place the panel in the sidebar, hidden by default (like Problems/Git).
do
  local node = core.root_view:get_active_node()
  panel.node = node:split("left", panel, { x = true }, true)
end

-- Opening a location ----------------------------------------------------------

---Open a file in the editor area, never in the debug console/panel leaf.
open_source = function(file, line)
  if not file then return end
  core.try(function()
    local doc = core.open_doc(file)
    if is_debug_leaf(core.root_view:get_active_node_default()) then
      local primary = core.root_view:get_primary_node()
      local av = primary and (primary.active_view or primary.views[1])
      if av then core.set_active_view(av) end
    end
    local dv = core.root_view:open_doc(doc)
    core.root_view.root_node:update_layout()
    local l = common.clamp(line or 1, 1, #doc.lines)
    doc:set_selection(l, 1, l, 1)
    dv:scroll_to_line(l, false)
    core.set_active_view(dv)
  end)
end

-- Floating toolbar -------------------------------------------------------------

local toolbar = { rect = nil, buttons = {}, hover = nil }

local function toolbar_buttons()
  local paused = gdb.state == "paused"
  local active = gdb.state == "paused" or gdb.state == "running"
  return {
    { label = "Continue", command = "debug:continue", enabled = paused },
    { label = "Pause", command = "debug:pause", enabled = gdb.state == "running" },
    { label = "Over", command = "debug:step-over", enabled = paused },
    { label = "Into", command = "debug:step-into", enabled = paused },
    { label = "Out", command = "debug:step-out", enabled = paused },
    { label = "Restart", command = "debug:restart", enabled = active },
    { label = "Stop", command = "debug:stop", enabled = gdb.session ~= nil },
  }
end

local function toolbar_rects()
  local font = style.font
  local pad = 6 * SCALE
  local gap = 3 * SCALE
  local w, h = 0, font:get_height() + 8 * SCALE
  local items = toolbar_buttons()
  for _, b in ipairs(items) do
    b.w = font:get_width(b.label) + pad * 2
    w = w + b.w + gap
  end
  w = w + pad * 2
  -- Anchor to the editor area (primary node), just below its tab bar, so
  -- the toolbar stays put even when the console or sidebar has the focus.
  local node = core.root_view:get_primary_node()
  local vx, vy, vw = core.root_view.position.x, core.root_view.position.y,
    core.root_view.size.x
  if node then vx, vy, vw = node.position.x, node.position.y, node.size.x end
  local tab_h = style.font:get_height() + style.padding.y * 2 + style.margin.tab.top
  local x = vx + math.max(0, (vw - w) / 2)
  local y = vy + tab_h + 6 * SCALE
  toolbar.rect = { x = x, y = y, w = w, h = h }
  local bx = x + pad
  for i, b in ipairs(items) do
    b.rect = { x = bx, y = y + 4 * SCALE, w = b.w, h = h - 8 * SCALE }
    bx = bx + b.w + gap
  end
  toolbar.buttons = items
  return items
end

local function draw_toolbar()
  if not gdb.session then return end
  local items = toolbar_rects()
  local r = toolbar.rect
  local C = style.panel_theme()
  renderer.draw_rect(r.x, r.y, r.w, r.h, style.background2)
  renderer.draw_rect(r.x, r.y, r.w, 1, style.divider)
  renderer.draw_rect(r.x, r.y + r.h - 1, r.w, 1, style.divider)
  for i, b in ipairs(items) do
    local hovered = toolbar.hover == i and b.enabled
    if hovered then
      renderer.draw_rect(b.rect.x, b.rect.y, b.rect.w, b.rect.h, C.highlight)
    end
    local color = b.enabled and style.text or style.dim
    if hovered then color = style.accent end
    common.draw_text(style.font, color, b.label, "center",
      b.rect.x, b.rect.y, b.rect.w, b.rect.h)
  end
end

local function toolbar_hit(x, y)
  if not toolbar.rect or not gdb.session then return nil end
  if not in_rect(x, y, toolbar.rect) then return nil end
  for i, b in ipairs(toolbar.buttons) do
    if in_rect(x, y, b.rect) then return i, b end
  end
  return 0
end

local old_root_draw = RootView.draw
function RootView:draw()
  old_root_draw(self)
  draw_toolbar()
end

local old_root_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local idx, btn = toolbar_hit(x, y)
  if idx then
    if btn and btn.enabled and button == "left" then
      command.perform(btn.command)
    end
    return true
  end
  return old_root_pressed(self, button, x, y, clicks)
end

local old_root_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  local idx = toolbar_hit(x, y)
  if idx then
    self.mouse.x, self.mouse.y = x, y
    toolbar.hover = (idx ~= 0) and idx or nil
    core.request_cursor("arrow")
    core.redraw = true
    return true
  end
  if toolbar.hover then
    toolbar.hover = nil
    core.redraw = true
  end
  return old_root_moved(self, x, y, dx, dy)
end

-- DocView integration: breakpoint dots, stopped line, gutter clicks -----------

local stop_line_color = config.plugins.gdb.stop_line_color

local old_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local h = old_gutter(self, line, x, y, width)
  local file = self.doc.abs_filename
  if not file then return h end
  local gw = self:get_gutter_width()
  if gw <= 0 then return h end
  local cy = y + h / 2
  local bp = gdb.breakpoint_at(file, line)
  local stopped = gdb.is_stopped_at(file, line)
  if stopped then
    renderer.draw_rect(x + 2 * SCALE, cy - 4 * SCALE, 9 * SCALE, 8 * SCALE, style.accent)
  end
  if bp then
    local color = bp.enabled and config.plugins.gdb.breakpoint_color or style.dim
    local bx = stopped and x + 13 * SCALE or x + 4 * SCALE
    renderer.draw_rect(bx, cy - 3 * SCALE, 6 * SCALE, 6 * SCALE, color)
  end
  return h
end

local old_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  local file = self.doc.abs_filename
  if file and gdb.is_stopped_at(file, line) then
    local gw = self:get_gutter_width()
    renderer.draw_rect(self.position.x + gw, y,
      math.max(0, self.size.x - gw), self:get_line_height(),
      config.plugins.gdb.stop_line_color or stop_line_color)
  end
  return old_body(self, line, x, y)
end

local old_doc_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.hovering_gutter and self.doc.abs_filename then
    local gw = self:get_gutter_width()
    local zone = math.min(gw, 22 * SCALE)
    if gw > 0 and x >= self.position.x and x <= self.position.x + zone then
      local line = self:resolve_screen_position(x, y)
      gdb.toggle_breakpoint(self.doc.abs_filename, line)
      return true
    end
  end
  return old_doc_pressed(self, button, x, y, clicks)
end

local old_context = DocView.on_context_menu
function DocView:on_context_menu(...)
  local menu, view = old_context(self, ...)
  if not menu or not menu.items or not self.doc.abs_filename then return menu, view end
  local items = {
    { text = gdb.breakpoint_at(self.doc.abs_filename, self.doc:get_selection())
        and "Remove Breakpoint" or "Toggle Breakpoint",
      command = "debug:toggle-breakpoint" },
    { text = "Conditional Breakpoint…", command = "debug:conditional-breakpoint" },
    { text = "Run to Cursor", command = "debug:run-to-cursor" },
    ContextMenu.DIVIDER,
  }
  for i = #items, 1, -1 do table.insert(menu.items, 1, items[i]) end
  return menu, view
end

-- Events ---------------------------------------------------------------------

gdb.on("output", function(text, kind)
  console:append(text, kind)
end)

gdb.on("state", function(state)
  if state == "idle" then
    console:flush_partial()
  end
  if debug_status_item then
    debug_status_item.visible = gdb.session ~= nil or state ~= "idle"
  end
  toolbar.hover = nil
  core.redraw = true
end)

gdb.on("stop", function(location, payload)
  console:flush_partial()
  local reason = payload and payload.reason
  if reason and reason ~= "breakpoint-hit" and reason ~= "end-stepping-range"
      and reason ~= "function-finished" and reason ~= "location-reached" then
    console:append("[stopped: " .. tostring(reason) .. "]", "info")
  end
  if panel.visible then panel.scroll_y = 0 end
end)

gdb.on("jump", function(file, line)
  open_source(file, line)
end)

gdb.on("exit", function()
  console:flush_partial()
end)

gdb.on("breakpoints", function()
  core.redraw = true
end)

-- Commands ---------------------------------------------------------------------

local function debug_views_active()
  return core.active_view == panel or core.active_view == console
end

local function debug_context()
  local av = core.active_view
  if debug_views_active() then return true end
  if not (av and av.doc) then return false end
  if gdb.session then return true end
  return gdb.has_configs()
end

local function current_doc_line()
  local av = core.active_view
  if not av or not av.doc or not av.doc.abs_filename then
    core.error("debug: open a file first")
    return
  end
  return av.doc.abs_filename, av.doc:get_selection()
end

command.add(debug_context, {
  ["debug:continue"] = function() gdb.continue() end,
  ["debug:pause"] = function() gdb.pause() end,
  ["debug:step-over"] = function() gdb.step_over() end,
  ["debug:step-into"] = function() gdb.step_into() end,
  ["debug:step-out"] = function() gdb.step_out() end,
  ["debug:toggle-breakpoint"] = function()
    local file, line = current_doc_line()
    if file then gdb.toggle_breakpoint(file, line) end
  end,
  ["debug:conditional-breakpoint"] = function()
    local file, line = current_doc_line()
    if not file then return end
    local bp = gdb.breakpoint_at(file, line)
    core.command_view:enter("Breakpoint Condition", {
      text = bp and bp.condition or "",
      submit = function(text)
        gdb.set_breakpoint(file, line, { condition = text ~= "" and text or nil })
      end,
    })
  end,
  ["debug:run-to-cursor"] = function() gdb.run_to_cursor() end,
})

command.add(nil, {
  ["debug:start"] = function() gdb.start_interactive() end,
  ["debug:start-config"] = function(text) gdb.start(text) end,
  ["debug:stop"] = function() gdb.stop() end,
  ["debug:restart"] = function() gdb.restart() end,
  ["debug:clear-breakpoints"] = function() gdb.clear_breakpoints() end,
  ["debug:select-config"] = function()
    local configs = gdb.load_configs()
    if #configs == 0 then
      core.error("debug: no launch configuration (add one to <project>/.max-xl/" 
        .. config.plugins.gdb.config_file .. " or config.plugins.gdb.configs)")
      return
    end
    if #configs == 1 then return gdb.start(configs[1]) end
    local names = {}
    for _, c in ipairs(configs) do names[#names + 1] = c.name end
    core.command_view:enter("Debug Configuration", {
      text = gdb.last_config and gdb.last_config.name or names[1],
      submit = function(text) gdb.start(text) end,
      suggest = function() return names end,
    })
  end,
  ["debug:toggle-panel"] = function() panel:toggle() end,
  ["debug:show-panel"] = function() panel:show() end,
  ["debug:toggle-console"] = function() console:toggle() end,
  ["debug:show-console"] = function() console:show() end,
  ["debug:clear-console"] = function() console:clear() end,
  ["debug:command"] = function()
    core.command_view:enter("GDB Command", {
      submit = function(text) gdb.execute(text) end,
      suggest = function() return console.history end,
    })
  end,
  ["debug:evaluate"] = function()
    core.command_view:enter("Evaluate Expression", {
      submit = function(text)
        if text ~= "" then gdb.execute("p " .. text) end
      end,
      suggest = function()
        local out = {}
        for _, v in ipairs((gdb.session and gdb.session.variables) or {}) do
          out[#out + 1] = v.name
        end
        return out
      end,
    })
  end,
  ["debug:refresh"] = function()
    local s = session()
    if not s then return end
    s:refresh_frames()
    s:refresh_threads()
    s:refresh_variables()
    s:refresh_registers()
  end,
})

command.add(DebugPanel, {
  ["debug:focus-panel"] = function(v) core.set_active_view(v) end,
})

command.add(DebugConsole, {
  ["debug:focus-console"] = function(v) core.set_active_view(v) end,
})

keymap.add({
  ["f5"] = "debug:continue",
  ["shift+f5"] = "debug:stop",
  ["ctrl+shift+f5"] = "debug:restart",
  ["f6"] = "debug:pause",
  ["f9"] = "debug:toggle-breakpoint",
  ["f10"] = "debug:step-over",
  ["f11"] = "debug:step-into",
  ["shift+f11"] = "debug:step-out",
  ["ctrl+f10"] = "debug:run-to-cursor",
  ["ctrl+shift+y"] = "debug:toggle-console",
  ["ctrl+alt+d"] = "debug:toggle-panel",
})

-- Status bar + activity bar ----------------------------------------------------

if core.status_view then
  local StatusView = require "core.statusview"
  debug_status_item = core.status_view:add_item({
    name = "debug:status",
    alignment = StatusView.Item.RIGHT,
    tooltip = "Debug session (click to open the Run and Debug panel)",
    visible = false,
    get_item = function()
      if not gdb.session then return {} end
      local color = style.accent
      if gdb.state == "running" then color = style.text
      elseif gdb.state == "paused" then color = style.accent
      elseif gdb.state == "exited" then color = style.dim end
      return { color, "debug: " .. state_label() }
    end,
    command = function()
      command.perform("debug:toggle-panel")
    end,
  })
end

local ab_ok, activitybar = pcall(require, "plugins.activitybar")
if ab_ok then
  activitybar.add_button({
    id = "debug",
    tooltip = "Run and Debug",
    draw = function(r, active, hovered)
      local color = active and style.accent or style.text
      local cx = math.floor(r.x + r.w / 2)
      local cy = math.floor(r.y + r.h / 2)
      -- simple bug: body, head and legs
      renderer.draw_rect(cx - 4, cy - 2, 8, 7, color)
      renderer.draw_rect(cx - 2, cy - 6, 4, 4, color)
      for i = -1, 1 do
        renderer.draw_rect(cx - 8, cy + i * 2, 4, 1, color)
        renderer.draw_rect(cx + 4, cy + i * 2, 4, 1, color)
      end
      renderer.draw_rect(cx - 3, cy - 8, 1, 3, color)
      renderer.draw_rect(cx + 2, cy - 8, 1, 3, color)
    end,
    show = function() panel:show() end,
    hide = function() panel:hide(false) end,
    is_active = function() return panel.visible end,
  })
end

M.panel = panel
M.console = console

return M
