-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"

config.plugins.activitybar = common.merge({
  size = 40 * SCALE,
  visible = true,
}, config.plugins.activitybar)

---Registry for sidebar panel selectors (VSCode-style activity bar).
---Panels register themselves; e.g. treeview registers "explorer",
---searchpanel registers "search". Future panels just add a button.
---@class plugins.activitybar.registry
---@field buttons table
local activitybar = { buttons = {} }

---@class plugins.activitybar.button
---@field id string unique id; re-registering replaces the entry
---@field symbol? string icon-font glyph, e.g. "D", "L" (ignored when `draw` is set)
---@field draw? fun(r: table, active: boolean, hovered: boolean) custom vector icon
---@field tooltip string
---@field show fun() focuses the panel (hiding the others)
---@field hide? fun() hides the panel, used by `show_only`
---@field is_active (fun(): boolean)?

---@param b plugins.activitybar.button
function activitybar.add_button(b)
  assert(b.id and b.show, "activitybar button needs id and show")
  for i, existing in ipairs(activitybar.buttons) do
    if existing.id == b.id then
      activitybar.buttons[i] = b
      return
    end
  end
  table.insert(activitybar.buttons, b)
end

---Hides every registered panel except `id` (which the caller then shows).
function activitybar.show_only(id)
  for _, b in ipairs(activitybar.buttons) do
    if b.id ~= id and b.hide and b.is_active and b.is_active() then
      core.try(b.hide)
    end
  end
end


---@class plugins.activitybar.view : core.view
local ActivityBar = View:extend()

function ActivityBar:__tostring() return "ActivityBar" end

function ActivityBar:new()
  ActivityBar.super.new(self)
  self.scrollable = false
  self.visible = config.plugins.activitybar.visible
  self.init_size = true
  self.target_size = config.plugins.activitybar.size
  self.hovered_idx = 0
end

function ActivityBar:get_name() return "Activity" end

function ActivityBar:get_row_height()
  return style.icon_font:get_height() + style.padding.y * 2
end

function ActivityBar:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "activitybar")
  end
  ActivityBar.super.update(self)
end

function ActivityBar:row_rect(idx)
  local row_h = self:get_row_height()
  return {
    x = self.position.x,
    y = self.position.y + row_h + (idx - 1) * row_h,
    w = self.size.x,
    h = row_h,
  }
end

function ActivityBar:draw()
  if not self.visible or self.size.x < 10 then return end
  self:draw_background(style.background2)
  for i, btn in ipairs(activitybar.buttons) do
    local r = self:row_rect(i)
    if r.y > self.position.y + self.size.y then break end
    local active = btn.is_active and btn.is_active()
    if i == self.hovered_idx then
      renderer.draw_rect(r.x, r.y, r.w, r.h, style.line_highlight)
    end
    if active then
      renderer.draw_rect(r.x, r.y, 2, r.h, style.accent)
    end
    local color = active and style.accent or style.text
    if btn.draw then
      btn.draw(r, active, i == self.hovered_idx)
    else
      common.draw_text(style.icon_font, color, btn.symbol or "M", "center", r.x, r.y, r.w, r.h)
    end
  end
  -- divider against the sidebar
  renderer.draw_rect(self.position.x + self.size.x - 1, self.position.y,
    1, self.size.y, style.divider)
end

function ActivityBar:button_at(x, y)
  for i in ipairs(activitybar.buttons) do
    local r = self:row_rect(i)
    if x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h then
      return i
    end
  end
end

function ActivityBar:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return false end
  if button ~= "left" then return true end
  local idx = self:button_at(x, y)
  if idx then
    local btn = activitybar.buttons[idx]
    core.try(btn.show)
    core.redraw = true
  end
  return true
end

function ActivityBar:on_mouse_moved(x, y, ...)
  if not self.visible then return end
  local idx = self:button_at(x, y) or 0
  if idx ~= self.hovered_idx then
    self.hovered_idx = idx
    if idx > 0 then
      core.status_view:show_tooltip(activitybar.buttons[idx].tooltip or activitybar.buttons[idx].id)
    else
      core.status_view:remove_tooltip()
    end
    core.redraw = true
  end
  self.cursor = "arrow"
end

function ActivityBar:on_mouse_left()
  self.hovered_idx = 0
  core.status_view:remove_tooltip()
end

local view = ActivityBar()
do
  local node = core.root_view:get_active_node()
  view.node = node:split("left", view, { x = true })
end

activitybar.view = view

local command = require "core.command"
command.add(nil, {
  ["activitybar:toggle"] = function()
    view.visible = not view.visible
    core.redraw = true
  end,
})

return activitybar
