-- mod-version:4
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

local ToolbarView = View:extend()

function ToolbarView:__tostring() return "ToolbarView" end

function ToolbarView:new()
  ToolbarView.super.new(self)
  self.visible = true
  self.init_size = true
  self.tooltip = false
  self.toolbar_font = style.icon_font
  -- `sep` entries draw a group divider. `stack` draws the symbol twice,
  -- offset, to suggest "all" (used by save-all).
  self.toolbar_commands = {
    { symbol = "f", command = "core:new-doc" },
    { symbol = "D", command = "core:open-file" },
    { symbol = "S", command = "doc:save" },
    { symbol = "S", command = "doc:save-all", stack = true },
    { sep = true },
    { symbol = "d", command = "core:add-directory" },
    { sep = true },
    { symbol = "L", command = "search-panel:toggle" },
    { sep = true },
    { symbol = "B", command = "core:find-command" },
  }
end


function ToolbarView:get_row_height()
  return self.toolbar_font:get_height() + style.padding.y * 2
end


function ToolbarView:update()
  local dest = 0
  if self.visible then
    if self.init_size then
      dest = self:get_row_height()
    else
      local max_y = 0
      local _, oy = self:get_content_offset()
      for _, _, _, y, h in self:each_item() do
        max_y = math.max(max_y, y + h)
      end
      dest = math.max(self:get_row_height(), max_y - oy + style.padding.y)
    end
  end
  if self.init_size then
    self.size.y = dest
    self.init_size = nil
  else
    self:move_towards(self.size, "y", dest)
  end
  ToolbarView.super.update(self)
end


function ToolbarView:toggle_visible()
  self.visible = not self.visible
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
  self.hovered_item = nil
end

function ToolbarView:get_icon_width()
  local max_width = 0
  for _, v in ipairs(self.toolbar_commands) do
    if v.symbol then
      max_width = math.max(max_width, (v.font or self.toolbar_font):get_width(v.symbol))
    end
  end
  return max_width
end

function ToolbarView:each_item()
  local icon_h = self.toolbar_font:get_height()
  local row_h = self:get_row_height()
  local ox, oy = self:get_content_offset()
  local x0 = ox + style.padding.x
  local x_limit = ox + self.size.x - style.padding.x
  local x, y = x0, oy + style.padding.y
  local icon_w = self:get_icon_width()
  local gap = math.floor(icon_w / 2)
  local index = 0
  return function()
    index = index + 1
    local item = self.toolbar_commands[index]
    if not item then return end
    local w = item.sep and math.floor(style.padding.x / 2) or icon_w
    if x + w > x_limit and x > x0 then
      x, y = x0, y + row_h
    end
    local rx, ry = x, y
    x = x + w + gap
    return item, rx, ry, w, icon_h
  end
end


function ToolbarView:get_min_width()
  return 2 * style.padding.x + self:get_icon_width()
end


function ToolbarView:draw()
  if not self.visible then return end
  self:draw_background(style.background2)

  for item, x, y, w, h in self:each_item() do
    if item.sep then
      renderer.draw_rect(x + math.floor(w / 2), y, 1, h, style.divider)
    else
      local color = style.dim
      if command.is_valid(item.command) then
        color = (item == self.hovered_item) and style.accent or style.text
      end
      if item.stack then
        common.draw_text(item.font or self.toolbar_font, style.dim, item.symbol, nil, x + 2, y + 2, 0, h)
      end
      common.draw_text(item.font or self.toolbar_font, color, item.symbol, nil, x, y, 0, h)
    end
  end
end


function ToolbarView:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  local caught = ToolbarView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  core.set_active_view(core.last_active_view)
  local item = self.hovered_item
  if item and item.command and command.is_valid(item.command) then
    command.perform(item.command)
  end
  return true
end


function ToolbarView:on_mouse_left()
  ToolbarView.super.on_mouse_left(self)
  if self.tooltip then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
  self.hovered_item = nil
end


function ToolbarView:on_mouse_moved(px, py, ...)
  if not self.visible then return end
  ToolbarView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  local x_min, x_max, y_min, y_max = self.size.x, 0, self.size.y, 0
  for item, x, y, w, h in self:each_item() do
    x_min, x_max = math.min(x, x_min), math.max(x + w, x_max)
    y_min, y_max = y, y + h
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      if item.command then
        local binding = keymap.get_binding(item.command)
        local name = command.prettify_name(item.command)
        core.status_view:show_tooltip(binding and { name, style.dim, "  ", binding } or { name })
        self.tooltip = true
      elseif self.tooltip then
        core.status_view:remove_tooltip()
        self.tooltip = false
      end
      return
    end
  end
  if self.tooltip and not (px > x_min and px <= x_max and py > y_min and py <= y_max) then
    core.status_view:remove_tooltip()
    self.tooltip = false
  end
end

-- The toolbarview pane is not plugged here but it is added in the
-- treeview plugin.

return ToolbarView
