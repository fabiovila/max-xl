-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"

config.plugins.problems = common.merge({
  size = 280 * SCALE,
  visible = false,
}, config.plugins.problems)

---Diagnostics registry shared by producers (linter hooks, builders, …)
---and the problems panel. This module doubles as the registry so
---producers only need `require "plugins.problems"`.
---@class plugins.problems.diagnostic
---@field file string absolute path
---@field line integer
---@field col integer
---@field severity "error"|"warning"|"info"
---@field message string
---@field source string producer name, e.g. "lua"
local problems = { diagnostics = {} }

---Replace all diagnostics from one producer.
---@param source string
---@param items plugins.problems.diagnostic[]
function problems.set(source, items)
  local kept = {}
  for _, d in ipairs(problems.diagnostics) do
    if d.source ~= source then table.insert(kept, d) end
  end
  for _, d in ipairs(items) do table.insert(kept, d) end
  problems.diagnostics = kept
  core.redraw = true
end

---Drop all diagnostics from one producer.
---@param source string
function problems.clear(source)
  problems.set(source, {})
end

local SEV_ORDER = { error = 1, warning = 2, info = 3 }

---@return plugins.problems.diagnostic[] sorted copy
function problems.get()
  local res = {}
  for _, d in ipairs(problems.diagnostics) do table.insert(res, d) end
  table.sort(res, function(a, b)
    if (SEV_ORDER[a.severity] or 9) ~= (SEV_ORDER[b.severity] or 9) then
      return (SEV_ORDER[a.severity] or 9) < (SEV_ORDER[b.severity] or 9)
    end
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line ~= b.line and a.line < b.line end
    return (a.col or 0) < (b.col or 0)
  end)
  return res
end


---@class plugins.problems.view : core.view
local ProblemsPanel = View:extend()

function ProblemsPanel:__tostring() return "ProblemsPanel" end

function ProblemsPanel:new()
  ProblemsPanel.super.new(self)
  self.scrollable = false
  self.visible = config.plugins.problems.visible
  self.init_size = true
  self.target_size = config.plugins.problems.size
  self.font = style.font:copy(13 * SCALE)
  self.selected = 0
  self.hovered = 0
  self.hovered_control = nil
  self.results_scroll = 0
  self.R = {}
end

function ProblemsPanel:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function ProblemsPanel:get_name() return "Problems" end

function ProblemsPanel:on_scale_change(new_scale)
  self.font = style.font:copy(13 * new_scale)
end

function ProblemsPanel:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "problemspanel")
  end
  ProblemsPanel.super.update(self)
end

-- Visibility ----------------------------------------------------------------

local function get_treeview()
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if tostring(view) == "TreeView" then return view end
  end
end

local tree_toggle_wrapped = false
local function ensure_tree_toggle_wrapped(panel)
  if tree_toggle_wrapped then return end
  local cmd = command.map["treeview:toggle"]
  if not cmd then return end
  tree_toggle_wrapped = true
  local orig = cmd.perform
  cmd.perform = function(...)
    orig(...)
    local tree = get_treeview()
    if tree and tree.visible and panel.visible then
      panel.visible = false
      core.redraw = true
    end
  end
end

function ProblemsPanel:show()
  ensure_tree_toggle_wrapped(self)
  local ab_ok, ab = pcall(require, "plugins.activitybar")
  if ab_ok then ab.show_only("problems") end
  local tree = get_treeview()
  if tree then tree.visible = false end
  self.visible = true
  core.set_active_view(self)
  self:refresh()
  core.redraw = true
end

function ProblemsPanel:hide(restore_tree)
  if not self.visible then return end
  self.visible = false
  if restore_tree == nil or restore_tree then
    local tree = get_treeview()
    if tree then tree.visible = true end
  end
  core.redraw = true
end

function ProblemsPanel:toggle()
  if self.visible then self:hide(true) else self:show() end
end

function ProblemsPanel:refresh()
  if self.visible then self:scan_open_docs() end
  core.redraw = true
end

-- Lua producer ---------------------------------------------------------------
-- Syntax-checks open Lua docs (save hook below + manual refresh).

local function lua_diagnostics_for(doc)
  if not doc.filename or not doc.filename:match("%.lua$") then return nil end
  local text = doc:get_text(1, 1, math.huge, math.huge)
  local chunk, err = load(text, "@" .. (doc.filename or "unsaved"))
  if chunk then return {} end
  -- err looks like "file:line: message"
  local line, msg = err:match("^.-:(%d+):%s*(.*)$")
  line = tonumber(line) or 1
  return {{
    file = doc.abs_filename or doc.filename,
    line = line, col = 1,
    severity = "error", message = msg or err,
    source = "lua",
  }}
end

function ProblemsPanel:scan_open_docs()
  local items = {}
  for _, doc in ipairs(core.docs) do
    local res = lua_diagnostics_for(doc)
    if res then
      for _, d in ipairs(res) do table.insert(items, d) end
    end
  end
  problems.set("lua", items)
end

-- Wrap doc:save so Lua diagnostics update on every save.
local save_wrapped = false
local function ensure_save_wrapped()
  if save_wrapped then return end
  local cmd = command.map["doc:save"]
  if not cmd then return end
  save_wrapped = true
  local orig = cmd.perform
  cmd.perform = function(dv, ...)
    local res = orig(dv, ...)
    if dv and dv.doc then
      -- recompute from all open docs to also drop fixed files
      local all = {}
      for _, doc in ipairs(core.docs) do
        local r = lua_diagnostics_for(doc)
        if r then for _, d in ipairs(r) do table.insert(all, d) end end
      end
      problems.set("lua", all)
    end
    return res
  end
end

-- Layout / drawing -----------------------------------------------------------

function ProblemsPanel:layout()
  local font = self.font or style.font
  local pad = style.padding.x
  local x = self.position.x + math.floor(pad / 2)
  local w = self.size.x - pad
  local y = self.position.y + style.padding.y
  local L = {}
  local line_h = font:get_height()
  local btn_h = math.floor(line_h * 1.2) + style.padding.y * 2

  L.header_h = line_h + style.padding.y
  L.header = { x = x, y = y, w = w, h = L.header_h }
  y = y + L.header_h + 10

  L.btn_refresh = { x = x, y = y, w = w, h = btn_h }
  y = y + btn_h + 6

  L.status_h = line_h + 4
  L.status = { x = x, y = y, w = w, h = L.status_h }
  y = y + L.status_h + 4

  L.results = { x = self.position.x, y = y, w = self.size.x, h = self.position.y + self.size.y - y }
  L.row_h = line_h + style.padding.y
  return L
end

local function draw_button(self, r, text, hovered)
  local C = self.C or style.panel_theme()
  local font = self.font or style.font
  local bg = hovered and C.highlight or C.field_bg
  renderer.draw_rect(r.x, r.y, r.w, r.h, bg)
  renderer.draw_rect(r.x, r.y, r.w, 1, C.border)
  renderer.draw_rect(r.x, r.y + r.h - 1, r.w, 1, C.border)
  renderer.draw_rect(r.x, r.y, 1, r.h, C.border)
  renderer.draw_rect(r.x + r.w - 1, r.y, 1, r.h, C.border)
  common.draw_text(font, C.text, text, "center", r.x, r.y, r.w, r.h)
end

local function sev_color(C, sev)
  if sev == "error" then return C.warn end
  if sev == "warning" then return C.accent end
  return C.dim
end

function ProblemsPanel:draw()
  if not self.visible then return end
  if self.size.x < 10 then return end
  self.C = style.panel_theme()
  local C = self.C
  local F = self.font or style.font
  self:draw_background(C.panel_bg)
  local L = self:layout()
  self.R = L
  local hovered = self.hovered_control
  local items = problems.get()
  if self.selected > #items then self.selected = #items end

  renderer.draw_rect(L.header.x, L.header.y, L.header.w, L.header.h, C.header_bg)
  local title = string.format("PROBLEMS  %d", #items)
  common.draw_text(F, C.header_text, title, "left",
    L.header.x + 6, L.header.y, L.header.w - 24, L.header.h)
  local close = { x = L.header.x + L.header.w - 24, y = L.header.y, w = 24, h = L.header.h }
  self.R.close = close
  if hovered == "close" then
    renderer.draw_rect(close.x, close.y, close.w, close.h, C.highlight)
  end
  common.draw_text(F, C.header_text, "x", "center", close.x, close.y, close.w, close.h)

  draw_button(self, L.btn_refresh, "Refresh", hovered == "refresh")

  local summary
  if #items == 0 then
    summary = "No problems"
  else
    local n_err, n_warn = 0, 0
    for _, d in ipairs(items) do
      if d.severity == "error" then n_err = n_err + 1
      elseif d.severity == "warning" then n_warn = n_warn + 1 end
    end
    summary = string.format("%d error(s), %d warning(s)", n_err, n_warn)
  end
  common.draw_text(F, #items == 0 and C.dim or C.text, summary, "left",
    L.status.x, L.status.y, L.status.w, L.status.h)

  local res = L.results
  if res.h > 0 then
    core.push_clip_rect(res.x, res.y, res.w, res.h)
    local row_h = L.row_h
    local ox = res.x + math.floor(style.padding.x / 2)
    local first = math.max(1, math.floor(self.results_scroll / row_h) + 1)
    local y = res.y + (first - 1) * row_h - self.results_scroll
    for i = first, #items do
      if y > res.y + res.h then break end
      local d = items[i]
      if i == self.selected then
        renderer.draw_rect(res.x, y, res.w, row_h, C.highlight)
      elseif i == self.hovered then
        local c = { table.unpack(C.highlight) }
        c[4] = 100
        renderer.draw_rect(res.x, y, res.w, row_h, c)
      end
      local badge = d.severity == "error" and "E" or d.severity == "warning" and "W" or "I"
      local bx = common.draw_text(F, sev_color(C, d.severity), badge .. "  ", "left", ox, y, res.w, row_h)
      local loc = string.format("%s:%d  ", common.basename(d.file), d.line)
      bx = common.draw_text(F, C.dim, loc, "left", bx, y, res.x + res.w - bx, row_h)
      local preview = i == self.selected and C.match or C.text
      common.draw_text(F, preview, d.message, "left", bx, y, res.x + res.w - bx, row_h)
      y = y + row_h
    end
    core.pop_clip_rect()
    local content_h = #items * row_h
    if content_h > res.h and res.h > 0 then
      local bar_h = math.max(20, res.h * res.h / content_h)
      local bar_y = res.y + (self.results_scroll / content_h) * res.h
      bar_y = math.min(bar_y, res.y + res.h - bar_h)
      renderer.draw_rect(res.x + res.w - 5, bar_y, 4, bar_h, C.dim)
    end
  end
end

function ProblemsPanel:ensure_selected_visible()
  local items = problems.get()
  local L = self.R.results or self:layout().results
  local row_h = (self.font or style.font):get_height() + style.padding.y
  if self.selected < 1 or L.h <= 0 then self.results_scroll = 0 return end
  local y_rel = (self.selected - 1) * row_h
  if y_rel < self.results_scroll then
    self.results_scroll = y_rel
  elseif y_rel + row_h > self.results_scroll + L.h then
    self.results_scroll = y_rel + row_h - L.h
  end
  local max = math.max(0, #items * row_h - L.h)
  self.results_scroll = common.clamp(self.results_scroll, 0, max)
end

function ProblemsPanel:open_selection()
  local items = problems.get()
  local d = items[self.selected]
  if not d then return false end
  return core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(d.file))
    core.root_view.root_node:update_layout()
    local line = common.clamp(d.line, 1, #dv.doc.lines)
    local col = common.clamp(d.col or 1, 1, #dv.doc.lines[line])
    dv.doc:set_selection(line, col)
    dv:scroll_to_line(line, true)
  end)
end

-- Mouse ---------------------------------------------------------------------

local function in_rect(x, y, r)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function ProblemsPanel:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return false end
  if button ~= "left" then return true end
  local L = self.R
  if in_rect(x, y, L.close) then self:hide(true) return true end
  if in_rect(x, y, L.btn_refresh) then self:scan_open_docs() return true end
  local res = L.results
  if res and x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
    local row_h = L.row_h
    local idx = math.floor((y - res.y + self.results_scroll) / row_h) + 1
    if problems.get()[idx] then
      self.selected = idx
      self:ensure_selected_visible()
      if clicks >= 2 then self:open_selection() end
      core.redraw = true
    end
    return true
  end
  return true
end

function ProblemsPanel:on_mouse_moved(x, y, ...)
  if not self.visible then return end
  local L = self.R
  self.hovered = 0
  local control = nil
  if in_rect(x, y, L.close) then control = "close"
  elseif in_rect(x, y, L.btn_refresh) then control = "refresh" end
  if not control and L.results then
    local res = L.results
    if x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
      local idx = math.floor((y - res.y + self.results_scroll) / L.row_h) + 1
      if problems.get()[idx] then self.hovered = idx control = "result" end
    end
  end
  if control ~= self.hovered_control then
    self.hovered_control = control
    if control == "close" then
      core.status_view:show_tooltip("Close problems")
    elseif control == "refresh" then
      core.status_view:show_tooltip("Re-scan open files")
    else
      core.status_view:remove_tooltip()
    end
    core.redraw = true
  end
  self.cursor = "arrow"
end

function ProblemsPanel:on_mouse_left()
  self.hovered_control = nil
  core.status_view:remove_tooltip()
end

function ProblemsPanel:on_mouse_wheel(y, x)
  if not self.visible then return false end
  local res = self.R.results
  if not res or res.h <= 0 then return false end
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  if mx >= res.x and my >= res.y and mx < res.x + res.w and my < res.y + res.h then
    local row_h = self.R.row_h or ((self.font or style.font):get_height() + style.padding.y)
    self.results_scroll = self.results_scroll - y * row_h * 3
    local max = math.max(0, #problems.get() * row_h - res.h)
    self.results_scroll = common.clamp(self.results_scroll, 0, max)
    core.redraw = true
    return true
  end
  return false
end

-- Instantiate ---------------------------------------------------------------

local view = ProblemsPanel()
do
  local node = core.root_view:get_active_node()
  view.node = node:split("left", view, { x = true }, true)
end

problems.view = view

-- Commands ------------------------------------------------------------------

local function panel_visible() return view.visible end

command.add(nil, {
  ["problems-panel:toggle"] = function() view:toggle() end,
  ["problems-panel:show"] = function() view:show() end,
})

command.add(panel_visible, {
  ["problems-panel:refresh"] = function() view:scan_open_docs() end,
})

command.add(ProblemsPanel, {
  ["problems-panel:hide"] = function(v) v:hide(true) end,
  ["problems-panel:up"] = function(v)
    local n = #problems.get()
    if n == 0 then return end
    v.selected = v.selected - 1
    if v.selected < 1 then v.selected = n end
    v:ensure_selected_visible()
    core.redraw = true
  end,
  ["problems-panel:down"] = function(v)
    local n = #problems.get()
    if n == 0 then return end
    v.selected = v.selected + 1
    if v.selected > n then v.selected = 1 end
    v:ensure_selected_visible()
    core.redraw = true
  end,
  ["problems-panel:open"] = function(v) v:open_selection() end,
})

keymap.add {
  ["ctrl+shift+m"] = "problems-panel:toggle",
  ["escape"] = "problems-panel:hide",
  ["up"] = "problems-panel:up",
  ["down"] = "problems-panel:down",
  ["return"] = "problems-panel:open",
}

-- Register the problems button on the activity bar (panel selector).
local ok_activitybar, activitybar = pcall(require, "plugins.activitybar")
if ok_activitybar then
  activitybar.add_button({
    id = "problems",
    symbol = "!",
    tooltip = "Problems",
    show = function()
      activitybar.show_only("problems")
      view:show()
    end,
    hide = function() view:hide(false) end,
    is_active = function() return view.visible end,
  })
end

ensure_save_wrapped()

return problems
