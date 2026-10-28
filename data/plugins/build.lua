-- mod-version:4
-- Build tasks with compiler problem matching.
--
-- Tasks are plain Lua tables read from USERDIR/build.lua and from
-- <project>/.max-xl/build.lua (the project file wins). Both a map and a list
-- are accepted:
--
--   return {
--     build = { command = "make -j$(nproc)", default = true },
--     clean = { command = "make clean", matcher = false },
--   }
--
--   return {
--     { name = "build", command = "cmake --build build" },
--     { name = "test",  command = "ctest --test-dir build" },
--   }
--
-- Task fields:
--   name     (string)          identifier (default: the table key)
--   command  (string)          shell command (required)
--   cwd      (string)          working directory, relative to the project
--                              root (default: the project root)
--   matcher  ("gcc"|false|fun) output matcher (default "gcc"); false keeps
--                              the output out of the Problems panel, a
--                              function(line, state) can add custom items
--   default  (boolean)         use this task for F7
--
-- When no build.lua exists, the buttons configured for plugins/actions.lua
-- are reused, so an existing `{ label = "build", command = "make" }` just
-- works.
--
-- Compiler output (GCC, Clang and build tools that wrap them) is parsed as
-- it streams through the console: every `file:line:col: error|warning|note:`
-- becomes an entry in the Problems panel, where a double click jumps to the
-- source. `make` "Entering directory" lines update the base directory used
-- for relative paths.
--
-- Commands: build:run (F7), build:pick (Shift+F7), build:cancel,
-- build:reload. Problem navigation: F8 / Shift+F8.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"

config.plugins.build = common.merge({
  -- Task run by `build:run` / F7 when none is marked `default`.
  default_task = "build",
  -- Configuration file, looked up in USERDIR and in <project>/.max-xl/.
  file = "build.lua",
  -- Output matcher used by default: "gcc" or false.
  matcher = "gcc",
  -- Open the Problems panel when a build fails with diagnostics.
  auto_open_problems = false,
}, config.plugins.build)

local M = {}

-- Loaded lazily so a user plugin with the same name still wins.
local problems
local function get_problems()
  problems = problems or require "plugins.problems"
  return problems
end

---@class plugins.build.task
---@field name string
---@field command string
---@field cwd? string
---@field matcher? string|false|fun(line: string, state: plugins.build.state)
---@field default? boolean

---@type plugins.build.task[]
local tasks = {}
local loaded_project = nil

---Information about the most recent run.
---@type nil|{ task: plugins.build.task, code?: integer|string|nil,
---            running: boolean, items: plugins.problems.diagnostic[] }
local last = nil

local status_item = nil


---Root project directory (or nil).
local function project_path()
  local project = core.root_project()
  return project and project.path or nil
end


local function resolve_cwd(task)
  local cwd = task.cwd
  if not cwd then return project_path() end
  if common.is_absolute_path(cwd) then return common.normalize_path(cwd) end
  local project = project_path()
  return project and common.normalize_path(project .. PATHSEP .. cwd) or cwd
end


-- Output matching ------------------------------------------------------------

local SEVERITIES = {
  ["error"] = "error",
  ["fatal error"] = "error",
  ["warning"] = "warning",
  ["note"] = "info",
  ["info"] = "info",
  ["remark"] = "info",
}

-- `file:line:col: severity: message`
local DIAG_WITH_COL = "^(.-):(%d+):(%d+):%s*([%a][%w ]-):%s*(.-)$"
-- `file:line: severity: message`
local DIAG = "^(.-):(%d+):%s*([%a][%w ]-):%s*(.-)$"
-- `make[1]: Entering directory '/path'`
local ENTER_DIR = "^make%[?%d*%]?:%s*Entering directory [\"'`](.+)[\"'`]$"
local LEAVE_DIR = "^make%[?%d*%]?:%s*Leaving directory [\"'`](.+)[\"'`]$"

local ANSI = "\27%[[%d;]*m"

---@class plugins.build.state
---@field cwd string
---@field dirs string[]
---@field items plugins.problems.diagnostic[]
---@field seen table<string, boolean>

---Create a fresh matcher state.
---@param cwd? string base directory for relative paths
---@return plugins.build.state
function M.new_state(cwd)
  return {
    cwd = cwd or project_path() or system.absolute_path("."),
    dirs = {},
    items = {},
    seen = {},
  }
end


local function current_dir(state)
  return state.dirs[#state.dirs] or state.cwd
end


local function resolve_file(filename, state)
  filename = common.normalize_path(filename)
  if common.is_absolute_path(filename) then return filename end
  return common.normalize_path(current_dir(state) .. PATHSEP .. filename)
end


local function add_item(state, filename, line, col, severity, message)
  filename = filename:match("^%s*(.-)%s*$")
  message = message:match("^%s*(.-)%s*$")
  line = tonumber(line)
  if filename == "" or message == "" or not line or line < 1 then return end
  col = tonumber(col) or 1
  local file = resolve_file(filename, state)
  local key = string.format("%s:%d:%d:%s", file, line, col, message)
  if state.seen[key] then return end
  state.seen[key] = true
  table.insert(state.items, {
    file = file,
    line = line,
    col = col,
    severity = severity,
    message = message,
    source = "build",
  })
end


---Feed one line of build output into `state`.
---@param state plugins.build.state
---@param line string
---@return plugins.problems.diagnostic|nil the diagnostic found, if any
function M.feed(state, line)
  line = (line or ""):gsub("\r$", ""):gsub(ANSI, "")

  local dir = line:match(ENTER_DIR)
  if dir then
    dir = common.normalize_path(dir)
    if not common.is_absolute_path(dir) then
      dir = common.normalize_path(current_dir(state) .. PATHSEP .. dir)
    end
    table.insert(state.dirs, dir)
    return
  end
  if line:match(LEAVE_DIR) then
    if #state.dirs > 0 then table.remove(state.dirs) end
    return
  end

  local before = #state.items
  local file, l, col, sev, msg = line:match(DIAG_WITH_COL)
  if not file then
    file, l, sev, msg = line:match(DIAG)
    col = nil
  end

  if file then
    local severity = sev and SEVERITIES[sev:lower()]
    if severity then
      add_item(state, file, l, col, severity, msg)
    end
  else
    -- clang-style linker errors: `prog.c:5: undefined reference to 'x'`
    local lf, ll, lmsg = line:match("^(.-):(%d+):%s*(.-)$")
    if lf and (lmsg:match("^undefined reference") or
        lmsg:match("^multiple definition") or
        lmsg:match("^relocation ")) then
      add_item(state, lf, ll, 1, "error", lmsg)
    end
  end

  if #state.items > before then return state.items[#state.items] end
end


---Parse a whole block of output.
---@param text string
---@param cwd? string
---@return plugins.build.state
function M.parse(text, cwd)
  local state = M.new_state(cwd)
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    M.feed(state, line)
  end
  return state
end


-- Task configuration ---------------------------------------------------------

local function read_task_file(path)
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then return false end
  local chunk, err = loadfile(path)
  if not chunk then
    core.error("build: cannot load %q: %s", path, err)
    return true
  end
  local ok, result = core.try(chunk)
  if not ok then
    core.error("build: error in %q: %s", path, tostring(result))
    return true
  end
  if type(result) ~= "table" then
    core.error("build: %q must return a table", path)
    return true
  end
  return true, result
end


local function append_tasks(result, out)
  local list = result.tasks or result

  -- list form: { { name = "build", ... }, ... }
  for _, task in ipairs(list) do
    if type(task) == "table" and type(task.command) == "string" then
      table.insert(out, task)
    end
  end

  -- map form: { build = { command = "..." }, ... } (sorted for stability)
  local names = {}
  for key, task in pairs(list) do
    if type(key) == "string" and type(task) == "table"
        and type(task.command) == "string" then
      table.insert(names, key)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local task = list[name]
    task.name = task.name or name
    table.insert(out, task)
  end
end


local function collect_tasks()
  local raw = {}

  local global_found, global_result = read_task_file(
    USERDIR .. PATHSEP .. config.plugins.build.file)
  if global_found and global_result then append_tasks(global_result, raw) end

  local project = project_path()
  local project_found, project_result = false, nil
  if project then
    project_found, project_result = read_task_file(
      project .. PATHSEP .. ".max-xl" .. PATHSEP .. config.plugins.build.file)
    if project_found and project_result then append_tasks(project_result, raw) end
  end

  -- No build.lua anywhere: reuse the action buttons, if the plugin is loaded.
  if not global_found and not project_found then
    local ok, actions = pcall(require, "plugins.actions")
    if ok and type(actions.get_actions) == "function" then
      for _, action in ipairs(actions.get_actions()) do
        if type(action.command) == "string" then
          table.insert(raw, {
            name = action.name or action.label,
            command = action.command,
            cwd = action.cwd,
          })
        end
      end
    end
  end

  -- De-duplicate by name; the last definition wins (project over user).
  local order, by_name = {}, {}
  for _, task in ipairs(raw) do
    local name = task.name
    if name and name ~= "" then
      if not by_name[name] then table.insert(order, name) end
      by_name[name] = task
    end
  end

  local result = {}
  for _, name in ipairs(order) do table.insert(result, by_name[name]) end
  return result
end


---(Re)load the task definitions from the configuration files.
function M.reload()
  tasks = collect_tasks()
  loaded_project = project_path()
  core.log_quiet("build: loaded %d task(s)", #tasks)
end


---@return plugins.build.task[]
function M.get_tasks()
  return tasks
end


---Find a task by name.
---@param name string
---@return plugins.build.task|nil
function M.get_task(name)
  for _, task in ipairs(tasks) do
    if task.name == name then return task end
  end
end


---Task used by `build:run` (F7).
---@return plugins.build.task|nil
function M.default_task()
  for _, task in ipairs(tasks) do
    if task.default then return task end
  end
  return M.get_task(config.plugins.build.default_task) or tasks[1]
end


---Information about the most recent run (nil before the first one).
function M.last()
  return last
end


-- Status bar ----------------------------------------------------------------

local function update_status()
  if not status_item then return end
  if last then status_item:show() else status_item:hide() end
  core.redraw = true
end


local function setup_status_item()
  if not core.status_view then return end
  local StatusView = require "core.statusview"
  status_item = core.status_view:add_item({
    name = "build:status",
    alignment = StatusView.Item.RIGHT,
    tooltip = "Build status — click to show the problems",
    visible = false,
    get_item = function()
      if not last then return {} end
      if last.running then return { style.dim, "build: running" } end
      local n_err, n_warn = 0, 0
      for _, d in ipairs(last.items or {}) do
        if d.severity == "error" then n_err = n_err + 1
        elseif d.severity == "warning" then n_warn = n_warn + 1 end
      end
      if n_err == 0 and n_warn == 0 then
        if last.code == nil or last.code == 0 then
          return { style.accent, "build: ok" }
        end
        return { style.warn, "build: failed" }
      end
      local parts = {}
      if n_err > 0 then table.insert(parts, string.format("%d error(s)", n_err)) end
      if n_warn > 0 then table.insert(parts, string.format("%d warning(s)", n_warn)) end
      return { n_err > 0 and style.warn or style.accent,
        "build: " .. table.concat(parts, ", ") }
    end,
    command = function(button)
      if button ~= "left" then return end
      if last and #(last.items or {}) > 0 then
        get_problems().view:show()
      else
        M.run()
      end
    end,
  })
end


-- Running -------------------------------------------------------------------

---Run a task (by name or table). Falls back to the default task.
---@param task? string|plugins.build.task
---@return boolean started
function M.run(task)
  if type(task) == "string" then task = M.get_task(task) end
  task = task or M.default_task()
  if not task then
    core.error("build: no tasks configured (see %s/build.lua)", USERDIR)
    return false
  end
  if type(task.command) ~= "string" or task.command:match("^%s*$") then
    core.error("build: task %q has no command", tostring(task.name))
    return false
  end

  local ok, console = pcall(require, "plugins.console")
  if not ok or not console or type(console.run) ~= "function" then
    core.error("build: the console plugin is required to run tasks")
    return false
  end
  if console:is_running() then
    core.error("A command is already running (see Console)")
    return false
  end

  local cwd = resolve_cwd(task)
  local use_matcher = task.matcher ~= false and config.plugins.build.matcher ~= false
  local state = M.new_state(cwd)
  local custom = type(task.matcher) == "function" and task.matcher or nil

  last = { task = task, running = true, items = state.items }
  get_problems().clear("build")
  update_status()

  console:run(task.command, {
    cwd = cwd,
    on_line = function(line)
      if custom then
        local item = custom(line, state)
        if type(item) == "table" and item.file then
          add_item(state, item.file, item.line, item.col,
            item.severity or "error", item.message or line)
        end
      elseif use_matcher then
        M.feed(state, line)
      end
      last.items = state.items
    end,
    on_exit = function(code)
      last.running = false
      last.code = code
      last.items = state.items
      if use_matcher or custom then get_problems().set("build", state.items) end
      update_status()
      if code ~= 0 and #state.items > 0
          and config.plugins.build.auto_open_problems then
        get_problems().view:show()
      end
    end,
  })
  return true
end


---Stop the running task.
function M.cancel()
  local ok, console = pcall(require, "plugins.console")
  if ok and console and console.is_running and console:is_running() then
    console:kill()
  end
end


-- Commands ------------------------------------------------------------------

command.add(nil, {
  ["build:run"] = function()
    M.run()
  end,

  ["build:pick"] = function()
    if #tasks == 0 then
      core.error("build: no tasks configured")
      return
    end
    local names = {}
    for _, task in ipairs(tasks) do table.insert(names, task.name) end
    core.command_view:enter("Run Build Task", {
      submit = function(text)
        if M.get_task(text) then M.run(text) end
      end,
      suggest = function() return names end,
    })
  end,

  ["build:cancel"] = function()
    M.cancel()
  end,

  ["build:reload"] = function()
    M.reload()
  end,
})

keymap.add {
  ["f7"] = "build:run",
  ["shift+f7"] = "build:pick",
  ["ctrl+shift+b"] = "build:run",
}


-- Load the tasks now and refresh whenever the root project changes.
setup_status_item()
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
