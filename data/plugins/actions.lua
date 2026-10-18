-- mod-version:4
-- Custom action buttons in the status bar, driven by Lua config files:
--
--   * USERDIR/actions.lua            e.g. ~/.config/max-xl/actions.lua
--   * <project>/.max-xl/actions.lua  per project (loaded last, wins)
--
-- Each file returns a list of buttons, for example
-- (~/.config/max-xl/actions.lua):
--
--   return {
--     { label = "build", command = "make -j$(nproc)" },
--     { label = "run",   command = "make run", tooltip = "run the app" },
--     { label = "test",  command = "./tests/run-e2e.sh", align = "right" },
--     { label = "clean", command = "make clean" },
--   }
--
-- Clicking a button runs its command in the project directory. stdout,
-- stderr and the exit status are captured in the Console panel, which is
-- opened automatically (see plugins/console.lua). With no console plugin
-- available the command is not run.
--
-- Button fields:
--   label   (string, required)  text drawn on the button.
--   command (string|function)   shell command, or a Lua function called
--                               with the button table as argument.
--   name    (string)            identifier, for overriding between the
--                               global and project files (default: label).
--   tooltip (string)            hover text (default: the command).
--   cwd     (string)            working directory; relative paths are
--                               resolved from the project root (default:
--                               the project root).
--   align   ("left"|"right")    side of the status bar (default "left").
--
-- Commands:
--   actions:reload  re-read the configuration files.
--   actions:run     pick an action from the command view.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local StatusView = require "core.statusview"

config.plugins.actions = common.merge({
  -- Side of the status bar used when a button does not set `align`.
  alignment = "left",
  -- Name of the configuration file, looked up in USERDIR and in
  -- <project>/.max-xl/.
  file = "actions.lua",
}, config.plugins.actions)

local M = {}

local ITEM_PREFIX = "actions:"
local actions = {}       -- the currently loaded buttons
local loaded_project = nil

local function project_path()
  local project = core.root_project()
  return project and project.path or nil
end


local function action_name(action)
  return tostring(action.name or action.label or "action")
end


local function action_label(action)
  return tostring(action.label or action.name or "action")
end


---Read one configuration file and append its buttons to `out`.
local function read_actions(path, out)
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then return end

  local chunk, err = loadfile(path)
  if not chunk then
    core.error("actions: cannot load %q: %s", path, err)
    return
  end

  local ok, result = core.try(chunk)
  if not ok then
    core.error("actions: error in %q: %s", path, tostring(result))
    return
  end

  if type(result) ~= "table" then
    core.error("actions: %q must return a table", path)
    return
  end

  -- Accept both a plain list and { actions = { ... } }.
  local list = result.actions or result
  for _, action in ipairs(list) do
    if type(action) == "table" then
      table.insert(out, action)
    end
  end
end


---Collect and de-duplicate the buttons from the global and project files.
---Project entries with the same name replace the global ones.
local function collect_actions()
  local raw = {}
  read_actions(USERDIR .. PATHSEP .. config.plugins.actions.file, raw)
  local project = project_path()
  if project then
    read_actions(project .. PATHSEP .. ".max-xl" .. PATHSEP .. config.plugins.actions.file, raw)
  end

  local order, by_name = {}, {}
  for _, action in ipairs(raw) do
    local name = action_name(action)
    if not by_name[name] then table.insert(order, name) end
    by_name[name] = action
  end

  local result = {}
  for _, name in ipairs(order) do table.insert(result, by_name[name]) end
  return result
end


local function resolve_cwd(action)
  local cwd = action.cwd
  if not cwd then return project_path() end
  if cwd:sub(1, 1) == "/" or cwd:match("^%a:[/\\]") then return cwd end
  local project = project_path()
  return project and (project .. PATHSEP .. cwd) or cwd
end


---Run an action: a shell command (captured in the Console) or a Lua function.
function M.run(action)
  local cmd = action.command

  if type(cmd) == "function" then
    local ok, err = core.try(cmd, action)
    if not ok then core.error("actions: %s", tostring(err)) end
    return
  end

  if type(cmd) ~= "string" or cmd:match("^%s*$") then
    core.error("actions: %q has no command", action_name(action))
    return
  end

  local ok, console = pcall(require, "plugins.console")
  if not ok or not console or type(console.run) ~= "function" then
    core.error("actions: the console plugin is required to run commands")
    return
  end

  console:run(cmd, { cwd = resolve_cwd(action) })
end


---Build the status bar item for a button.
local function make_button(action)
  local side = action.align or config.plugins.actions.alignment
  return {
    name = ITEM_PREFIX .. action_name(action),
    alignment = side == "right" and StatusView.Item.RIGHT or StatusView.Item.LEFT,
    tooltip = action.tooltip
      or (type(action.command) == "string" and action.command or ""),
    get_item = function()
      return { style.text, " " .. action_label(action) .. " " }
    end,
    command = function(button)
      if button == "left" then
        M.run(action)
      end
    end,
  }
end


---(Re)load the configuration files and rebuild the status bar buttons.
function M.reload()
  local status_view = core.status_view
  if not status_view then return end

  for _, action in ipairs(actions) do
    status_view:remove_item(ITEM_PREFIX .. action_name(action))
  end

  actions = collect_actions()
  loaded_project = project_path()

  for _, action in ipairs(actions) do
    local name = ITEM_PREFIX .. action_name(action)
    if status_view:get_item(name) then status_view:remove_item(name) end
    local item = status_view:add_item(make_button(action))
    item.background_color = style.background
    item.background_color_hover = style.selection
  end

  core.redraw = true
  core.log_quiet("actions: loaded %d button(s)", #actions)
end


command.add(nil, {
  ["actions:reload"] = function()
    M.reload()
  end,

  ["actions:run"] = function()
    if #actions == 0 then
      core.error("actions: no actions configured")
      return
    end
    local labels = {}
    for _, action in ipairs(actions) do
      table.insert(labels, action_label(action))
    end
    core.command_view:enter("Run Action", {
      submit = function(text)
        for _, action in ipairs(actions) do
          if action_label(action) == text then
            M.run(action)
            return
          end
        end
      end,
      suggest = function() return labels end,
    })
  end,
})

keymap.add {
  ["ctrl+alt+a"] = "actions:reload",
}

-- Load the buttons now and refresh them whenever a directory is added or
-- removed (which may change the root project).
M.reload()

local base_add_project = core.add_project
function core.add_project(...)
  local project = base_add_project(...)
  if project_path() ~= loaded_project then M.reload() end
  return project
end

local base_remove_project = core.remove_project
function core.remove_project(...)
  local result = base_remove_project(...)
  if project_path() ~= loaded_project then M.reload() end
  return result
end

return M
