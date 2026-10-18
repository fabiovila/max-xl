-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local process = require "core.process"

config.plugins.console = common.merge({}, config.plugins.console)

-- Bottom output tab (read-only by construction: plain line buffer,
-- custom drawing, no editing paths). Opened with a horizontal split,
-- coexists with the sidebar panels.
---@class plugins.console.view : core.view
local ConsoleView = View:extend()

function ConsoleView:__tostring() return "ConsoleView" end

function ConsoleView:new()
  ConsoleView.super.new(self)
  self.scrollable = true
  self.lines = {}
  self.max_w = 0
  self.proc = nil
  self.run_id = 0
  self.follow = true
  self.history = {}
  self.last_command = nil
end

function ConsoleView:get_name() return "Console" end

function ConsoleView:is_open()
  return core.root_view.root_node:get_node_for_view(self) ~= nil
end

function ConsoleView:get_text()
  return table.concat(self.lines, "\n")
end

function ConsoleView:get_row_height()
  return style.code_font:get_height()
end

function ConsoleView:get_scrollable_size()
  return #self.lines * self:get_row_height()
end

function ConsoleView:get_h_scrollable_size()
  return self.max_w
end

function ConsoleView:update()
  ConsoleView.super.update(self)
  local max = self:get_scrollable_size() - self.size.y
  if max > 0 then
    if self.scroll.to.y < max - self:get_row_height() * 2 then
      self.follow = false
    elseif self.scroll.to.y >= max - 1 then
      self.follow = true
    end
    if self.follow then
      self.scroll.to.y = max
    end
  end
end

function ConsoleView:append(text)
  if not text or text == "" then return end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(self.lines, line)
    self.max_w = math.max(self.max_w, style.code_font:get_width(line))
  end
  while #self.lines > 5000 do
    table.remove(self.lines, 1)
  end
  core.redraw = true
end

function ConsoleView:clear()
  self.lines = {}
  self.max_w = 0
  self.scroll.to.x, self.scroll.to.y = 0, 0
  self.scroll.x, self.scroll.y = 0, 0
  core.redraw = true
end

function ConsoleView:copy_all()
  system.set_clipboard(table.concat(self.lines, "\n"))
  core.log("Console output copied to clipboard")
end

function ConsoleView:is_running()
  return self.proc ~= nil and self.proc:running()
end

function ConsoleView:kill()
  if self:is_running() then
    self.proc:kill()
    self:append("[killed]")
  end
  self.proc = nil
end

local function drain_to(view, stream)
  while true do
    local ok, line = pcall(stream.read, stream, "*l", { timeout = 0.15 })
    if not ok or line == nil then break end
    view:append(line)
  end
end

function ConsoleView:run(cmd)
  if not cmd or cmd == "" then return end
  if self:is_running() then
    core.error("A command is already running (see Console)")
    return
  end
  self.last_command = cmd
  self.run_id = self.run_id + 1
  local my_id = self.run_id
  local hist = self.history
  for i, h in ipairs(hist) do
    if h == cmd then table.remove(hist, i) break end
  end
  table.insert(hist, 1, cmd)
  while #hist > 50 do table.remove(hist) end
  local cwd = core.root_project() and core.root_project().path or nil
  self:append("$ " .. cmd)
  self.follow = true
  if not self:is_open() then self:show() end
  local shell = PLATFORM == "Windows" and { "cmd", "/c" } or { "sh", "-c" }
  core.add_thread(function()
    local ok, proc = pcall(process.start, { shell[1], shell[2], cmd }, cwd and { cwd = cwd } or {})
    if not ok or not proc then
      self:append("[could not start: " .. tostring(proc) .. "]")
      return
    end
    self.proc = proc
    while proc:running() and self.run_id == my_id do
      drain_to(self, proc.stdout)
      drain_to(self, proc.stderr)
      coroutine.yield(0.05)
    end
    if self.run_id ~= my_id then return end
    drain_to(self, proc.stdout)
    drain_to(self, proc.stderr)
    local code = proc:wait(5)
    if self.run_id ~= my_id then return end
    self.proc = nil
    self:append(string.format("[exit %s]", tostring(code)))
  end)
end

-- Placement: horizontal split below the active editor ------------------------

function ConsoleView:show()
  if self:is_open() then
    local node = core.root_view.root_node:get_node_for_view(self)
    if node then node:set_active_view(self) end
    return
  end
  local node = core.root_view:get_active_node_default()
  local leaf = node:split("down", self)
  local parent = leaf:get_parent_node(core.root_view.root_node)
  if parent then parent.divider = 0.75 end
  -- add_view already focused the console; refresh geometry
  core.root_view.root_node:update_layout()
  core.redraw = true
end

function ConsoleView:hide()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then
    node:close_view(core.root_view.root_node, self)
    core.redraw = true
  end
end

function ConsoleView:toggle()
  if self:is_open() then self:hide() else self:show() end
end

-- Drawing (read-only log) ----------------------------------------------------

function ConsoleView:draw()
  self:draw_background(style.background)
  local row_h = self:get_row_height()
  local ox, oy = self:get_content_offset()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  if #self.lines == 0 then
    common.draw_text(style.code_font, style.dim,
      "Console output — run a command with console:run.",
      "left", ox, oy, self.size.x, row_h)
    common.draw_text(style.code_font, style.dim,
      "For an interactive shell, open the Terminal tab.",
      "left", ox, oy + row_h, self.size.x, row_h)
  end
  local first = math.max(1, math.floor(self.scroll.y / row_h) + 1)
  local y = oy + (first - 1) * row_h
  for i = first, #self.lines do
    if y > self.position.y + self.size.y then break end
    local line = self.lines[i]
    local color = style.text
    if line:sub(1, 2) == "$ " or line:sub(1, 1) == "[" then
      color = style.dim
    end
    common.draw_text(style.code_font, color, line ~= "" and line or " ", "left",
      ox, y, self.size.x, row_h)
    y = y + row_h
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function ConsoleView:on_mouse_pressed(button, x, y, clicks)
  local caught = ConsoleView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then return caught end
  if button ~= "left" then return false end
  return true
end

function ConsoleView:on_mouse_wheel(y, x)
  local row_h = self:get_row_height()
  if x ~= 0 then
    self.scroll.to.x = self.scroll.to.x - x * row_h
  end
  if y ~= 0 then
    self.scroll.to.y = self.scroll.to.y - y * row_h * 3
  end
  local max_y = math.max(0, self:get_scrollable_size() - self.size.y)
  local max_x = math.max(0, self:get_h_scrollable_size() - self.size.x)
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max_y)
  self.scroll.to.x = common.clamp(self.scroll.to.x, 0, max_x)
  core.redraw = true
  return true
end

-- Instantiate (a single tab, opened on demand) ------------------------------

local view = ConsoleView()

-- Commands ------------------------------------------------------------------

local function panel_open() return view:is_open() end

command.add(nil, {
  ["console:toggle"] = function() view:toggle() end,
  ["console:show"] = function() view:show() end,
  ["console:hide"] = function() view:hide() end,
})

command.add(panel_open, {
  ["console:run"] = function()
    core.command_view:enter("Run", {
      text = view.last_command,
      submit = function(cmd) view:run(cmd) end,
      suggest = function() return view.history end,
    })
  end,
  ["console:rerun"] = function()
    if view.last_command then
      view:run(view.last_command)
    else
      command.perform("console:run")
    end
  end,
  ["console:clear"] = function() view:clear() end,
  ["console:kill"] = function() view:kill() end,
  ["console:copy-all"] = function() view:copy_all() end,
})

command.add(ConsoleView, {
  ["console:focus"] = function(v)
    core.set_active_view(v)
  end,
})

keymap.add {
  ["ctrl+alt+t"] = "console:toggle",
  ["escape"] = "console:hide",
}

-- Register the console button on the activity bar (panel selector).
local ok_activitybar, activitybar = pcall(require, "plugins.activitybar")
if ok_activitybar then
  activitybar.add_button({
    id = "console",
    tooltip = "Console",
    draw = function(r, active, hovered)
      local color = active and style.accent or style.text
      common.draw_text(style.code_font, color, ">_", "center", r.x, r.y, r.w, r.h)
    end,
    show = function() view:show() end,
    hide = function() view:hide() end,
    is_active = function() return view:is_open() end,
  })
end

return view
