-- mod-version:4
-- GDB integration: a small GDB/MI2 client spoken over pipes.
--
-- GDB is driven through its machine interface (`--interpreter=mi2`), so no
-- external frontend or Python is needed. The editor reads MI records,
-- keeps the debuggee state (frames, variables, registers, threads) and the
-- UI plugin (`plugins.gdbui`) draws it.
--
-- Launch configurations are plain Lua tables. They can live in the user
-- config (`config.plugins.gdb.configs`) or in `<project>/.max-xl/debug.lua`:
--
--   return {
--     {
--       name = "local",
--       program = "${workspace}/build/app",
--       args = { "--verbose" },
--       stop_at_entry = true,
--     },
--     {
--       name = "arm via qemu",
--       gdb = "gdb",
--       program = "${workspace}/build/app-arm",
--       target = "localhost:1234",          -- gdbserver / qemu-arm -g 1234
--       target_type = "remote",             -- gdbserver/qemu; OpenOCD uses extended-remote
--     },
--     {
--       name = "arm bare metal",
--       gdb = "arm-none-eabi-gdb",
--       program = "${workspace}/build/firmware.elf",
--       target = "localhost:3333",
--       target_type = "extended-remote",
--       init_commands = { "monitor reset halt" },
--       pre_launch = "openocd -f board/st_nucleo_f4.cfg",
--     },
--   }
--
-- Paths support ${workspace}, ${file}, ${fileDir}, ${fileBasename},
-- ${fileBasenameNoExt}, ${fileExtname} and ${env:NAME}.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local process = require "core.process"

config.plugins.gdb = common.merge({
  -- GDB binary used when a configuration does not set its own (`gdb`,
  -- `gdb-multiarch`, `arm-none-eabi-gdb`, `aarch64-linux-gnu-gdb`, …).
  gdb = "gdb",
  -- Extra arguments passed to GDB before any configuration is applied.
  args = {},
  -- Launch configurations (see the header comment for the fields).
  configs = {},
  -- Per-project file, loaded from <project>/.max-xl/<name>.
  config_file = "debug.lua",
  -- Open the source file and jump to the line when the target stops.
  auto_open_source = true,
  -- Timeout for startup commands and for connecting to a remote target.
  launch_timeout = 25,
  connect_timeout = 10,
  -- Registers shown in the debug panel (ARM friendly by default).
  show_registers = true,
  -- Store breakpoints per project in USERDIR/<file>.
  breakpoint_file = "gdb-breakpoints.lua",
  -- Background of the line where the target is stopped.
  stop_line_color = { 0.95, 0.60, 0.15, 40 },
  -- Breakpoint dot color.
  breakpoint_color = { 0.90, 0.25, 0.30, 255 },
}, config.plugins.gdb)

local M = {
  state = "idle",         -- idle | starting | running | paused | exited
  session = nil,
  last_config = nil,
  breakpoints = {},       -- [abs_path] = { [line] = breakpoint }
}


local listeners = {}

---Subscribe to a driver event. Events: "state" (state), "output" (text,
---kind), "stop" (location, payload), "jump" (file, line), "update"
---(generic), "exit" ().
function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

local function emit(event, ...)
  for _, fn in ipairs(listeners[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then core.error("debug listener error: %s", err) end
  end
end

local function set_state(state)
  if M.state == state then return end
  M.state = state
  emit("state", state)
  core.redraw = true
end

function M.set_state(state) set_state(state) end

local function output(text, kind)
  if text == nil then return end
  emit("output", text, kind or "output")
end

-- MI parsing -----------------------------------------------------------------

local parser = {}

---Decode an MI C string starting at `i` (which must point at the opening
---quote). Returns the decoded string and the index after the closing quote.
function parser.parse_cstring(s, i)
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local n = s:sub(i + 1, i + 1)
      if n == "n" then out[#out + 1] = "\n"; i = i + 2
      elseif n == "t" then out[#out + 1] = "\t"; i = i + 2
      elseif n == "r" then out[#out + 1] = "\r"; i = i + 2
      elseif n == "a" then out[#out + 1] = "\a"; i = i + 2
      elseif n == "b" then out[#out + 1] = "\b"; i = i + 2
      elseif n == "f" then out[#out + 1] = "\f"; i = i + 2
      elseif n == "v" then out[#out + 1] = "\v"; i = i + 2
      elseif n == "e" then out[#out + 1] = "\27"; i = i + 2
      elseif n:match("%d") then
        local oct = s:sub(i + 1, i + 3):match("^%d+")
        out[#out + 1] = string.char(tonumber(oct, 8) % 256)
        i = i + 1 + #oct
      else
        out[#out + 1] = n
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), i
end

---Parse one MI value: C string, tuple `{...}`, list `[...]` or scalar.
function parser.parse_value(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return parser.parse_cstring(s, i)
  elseif c == "{" or c == "[" then
    local is_list = c == "["
    local close = is_list and "]" or "}"
    local t = {}
    i = i + 1
    while i <= #s do
      local ch = s:sub(i, i)
      if ch == close then return t, i + 1 end
      if ch == "," or ch == " " or ch == "\r" or ch == "\n" then
        i = i + 1
      elseif ch == "{" or ch == "[" or ch == '"' then
        -- nested value without a name, e.g. ranges=[{from="…",to="…"}]
        local val, ni = parser.parse_value(s, i)
        if ni <= i then return t, i end
        t[#t + 1] = val
        i = ni
      else
        local name, val, ni = parser.parse_result(s, i)
        if not name or ni <= i then
          -- make progress even on malformed input
          i = math.max(ni or i, i + 1)
        else
          if is_list then t[#t + 1] = val end
          t[name] = val
          i = ni
        end
      end
    end
    return t, i
  else
    local j = i
    while j <= #s do
      local ch = s:sub(j, j)
      if ch == "," or ch == "}" or ch == "]" then break end
      j = j + 1
    end
    if j == i then return nil, i + 1 end
    local v = s:sub(i, j - 1):match("^%s*(.-)%s*$")
    if v == "null" or v == "" then v = nil end
    return v, j
  end
end

---Parse `name=value` at `i`. Returns nil if there is no `=`.
function parser.parse_result(s, i)
  local j = i
  while j <= #s do
    local ch = s:sub(j, j)
    if ch == "=" then break end
    if ch == "," or ch == "}" or ch == "]" then return nil end
    j = j + 1
  end
  if j > #s then return nil end
  local name = s:sub(i, j - 1):match("^%s*(.-)%s*$")
  local val, ni = parser.parse_value(s, j + 1)
  return name, val, ni
end

---Parse a comma separated `name=value` list.
function parser.parse_results(s, i)
  local res = {}
  i = i or 1
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "," or ch == " " or ch == "\r" or ch == "\n" then
      i = i + 1
    elseif ch == "}" or ch == "]" then
      break
    else
      local name, val, ni = parser.parse_result(s, i)
      if not name then break end
      res[name] = val
      i = ni
    end
  end
  return res, i
end

---Parse one MI output line. Returns token (or nil), record kind and payload.
---For result/async records payload.class holds done/running/stopped/error/…
function parser.parse_record(line)
  local token, kind, rest = line:match("^(%d*)([%^%*%+%=%~%@%&])(.*)$")
  if not kind then return nil end
  local payload
  if kind == "~" or kind == "@" or kind == "&" then
    local q = rest:find('"', 1, true)
    if q then
      payload = parser.parse_cstring(rest, q)
    else
      payload = rest
    end
  else
    local class, after = rest:match("^([^,]*)(.*)$")
    payload = parser.parse_results(after, 1)
    payload.class = class
  end
  return (token ~= "" and tonumber(token) or nil), kind, payload
end

M.parse = parser
M.parse_record = parser.parse_record

-- Helpers --------------------------------------------------------------------

function M.quote(value)
  value = tostring(value)
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  return '"' .. value .. '"'
end

local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function join_path(a, b)
  if not a or a == "" then return b end
  if is_absolute(b) then return b end
  return a .. PATHSEP .. b
end

local function project_path()
  local project = core.root_project()
  if project and project.path then return project.path end
  return system.absolute_path(".") or "."
end

local function current_file()
  local av = core.active_view
  if av and av.doc and av.doc.abs_filename then return av.doc.abs_filename end
end

local function substitute(value)
  if type(value) ~= "string" then return value end
  value = value:gsub("%${env:([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end)
  return (value:gsub("%${([%w_]+)}", function(key)
    local file = current_file() or ""
    local dir = file:match("^(.*)[/\\][^/\\]*$") or ""
    local base = file:match("([^/\\]+)$") or ""
    local stem = base:gsub("%.[^%.]*$", "")
    local ext = base:match("(%.[^%.]*)$") or ""
    if key == "workspace" or key == "workspaceFolder" then return project_path() end
    if key == "file" then return file end
    if key == "fileDir" then return dir end
    if key == "fileBasename" then return base end
    if key == "fileBasenameNoExt" then return stem end
    if key == "fileExtname" then return ext end
    return "${" .. key .. "}"
  end))
end

---Split a command line into arguments, honouring single/double quotes.
function M.split_args(str)
  local args, cur, quote = {}, {}, nil
  for c in str:gmatch(".") do
    if quote then
      if c == quote then quote = nil else cur[#cur + 1] = c end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == " " or c == "\t" then
      if #cur > 0 then args[#args + 1] = table.concat(cur); cur = {} end
    else
      cur[#cur + 1] = c
    end
  end
  if #cur > 0 then args[#args + 1] = table.concat(cur) end
  return args
end

-- Launch configurations -------------------------------------------------------

local function normalize_config(c)
  if type(c) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(c) do out[k] = v end
  out.name = tostring(out.name or out.program or "default")
  for _, key in ipairs({ "program", "cwd", "target", "gdb", "pre_launch_script" }) do
    if type(out[key]) == "string" then out[key] = substitute(out[key]) end
  end
  if type(out.args) == "string" then out.args = M.split_args(substitute(out.args)) end
  if type(out.pre_launch) == "string" then out.pre_launch = substitute(out.pre_launch) end
  if type(out.init_commands) == "table" then
    local list = {}
    for _, cmd in ipairs(out.init_commands) do list[#list + 1] = substitute(cmd) end
    out.init_commands = list
  end
  return out
end

---Load and normalize launch configurations: project file first, then the
---global ones. The project file may return a list or `{ configs = list }`.
---Results are cached per project; pass `true` to re-read the files.
local config_cache = {}

function M.load_configs(refresh)
  local project = project_path()
  if not refresh and config_cache.project == project then
    return config_cache.list
  end
  local list = {}
  local path = project .. PATHSEP .. ".max-xl" .. PATHSEP .. config.plugins.gdb.config_file
  if system.get_file_info(path) then
    local ok, res = pcall(dofile, path)
    if ok and type(res) == "table" then
      local items = res.configs or res
      if items.name and not items[1] then items = { items } end
      for _, c in ipairs(items) do
        local n = normalize_config(c)
        if n then list[#list + 1] = n end
      end
    elseif not ok then
      core.error("debug: could not load %s: %s", path, tostring(res))
    end
  end
  for _, c in ipairs(config.plugins.gdb.configs or {}) do
    local n = normalize_config(c)
    if n then list[#list + 1] = n end
  end
  config_cache.project, config_cache.list = project, list
  return list
end

function M.get_config(name)
  for _, c in ipairs(M.load_configs()) do
    if c.name == name then return c end
  end
end

function M.has_configs()
  return #M.load_configs() > 0
end

-- Breakpoints -----------------------------------------------------------------

local bp_store = nil
local loaded_project = nil

local function bp_store_path()
  return USERDIR .. PATHSEP .. config.plugins.gdb.breakpoint_file
end

local function load_store()
  if bp_store then return bp_store end
  bp_store = {}
  local path = bp_store_path()
  if system.get_file_info(path) then
    local ok, res = pcall(dofile, path)
    if ok and type(res) == "table" then bp_store = res end
  end
  return bp_store
end

local function save_store()
  local path = bp_store_path()
  local fp, err = io.open(path, "w")
  if not fp then
    core.error("debug: could not save breakpoints: %s", tostring(err))
    return
  end
  fp:write("-- Max XL breakpoints (generated file).\nreturn {\n")
  for project, files in pairs(bp_store) do
    fp:write(string.format("  [%q] = {\n", project))
    for file, list in pairs(files) do
      fp:write(string.format("    [%q] = {\n", file))
      for _, bp in ipairs(list) do
        fp:write(string.format("      { line = %d, condition = %s, enabled = %s },\n",
          bp.line, bp.condition and string.format("%q", bp.condition) or "nil",
          bp.enabled == false and "false" or "true"))
      end
      fp:write("    },\n")
    end
    fp:write("  },\n")
  end
  fp:write("}\n")
  fp:close()
end

local function relative_to_project(file)
  local root = project_path() .. PATHSEP
  if file:sub(1, #root) == root then return file:sub(#root + 1) end
  return file
end

---Restore this project's breakpoints from USERDIR (once per project).
function M.load_project_breakpoints()
  local project = project_path()
  if loaded_project == project then return end
  loaded_project = project
  M.breakpoints = {}
  local files = load_store()[project] or {}
  for file, list in pairs(files) do
    local abs = is_absolute(file) and file or join_path(project, file)
    M.breakpoints[abs] = M.breakpoints[abs] or {}
    for _, bp in ipairs(list) do
      bp.file = abs
      M.breakpoints[abs][bp.line] = bp
    end
  end
  emit("breakpoints")
end

local function persist_breakpoints()
  local project = project_path()
  local entry = {}
  for file, lines in pairs(M.breakpoints) do
    local list = {}
    for line, bp in pairs(lines) do
      list[#list + 1] = { line = line, condition = bp.condition, enabled = bp.enabled }
    end
    table.sort(list, function(a, b) return a.line < b.line end)
    if #list > 0 then entry[relative_to_project(file)] = list end
  end
  local store = load_store()
  if next(entry) then store[project] = entry else store[project] = nil end
  save_store()
end

function M.breakpoint_at(file, line)
  if loaded_project ~= project_path() then M.load_project_breakpoints() end
  local lines = M.breakpoints[file]
  return lines and lines[line]
end

function M.iter_breakpoints()
  local out = {}
  for file, lines in pairs(M.breakpoints) do
    for line, bp in pairs(lines) do
      out[#out + 1] = { file = file, line = line, bp = bp }
    end
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  return out
end

local function make_breakpoint(file, line, opts)
  opts = opts or {}
  return {
    file = file,
    line = line,
    enabled = opts.enabled ~= false,
    condition = opts.condition,
    verified = false,
    id = nil,
  }
end

function M.set_breakpoint(file, line, opts)
  if not file or not line then return end
  M.breakpoints[file] = M.breakpoints[file] or {}
  local bp = M.breakpoints[file][line]
  if not bp then
    bp = make_breakpoint(file, line, opts)
    M.breakpoints[file][line] = bp
    if opts and opts.condition then bp.condition = opts.condition end
    if M.session and bp.enabled then M.session:insert_breakpoint(bp) end
  elseif opts then
    if opts.condition ~= nil then
      bp.condition = opts.condition ~= "" and opts.condition or nil
      if M.session then
        if bp.id then
          if bp.condition then
            M.session:send_async("-break-condition " .. bp.id .. " " .. M.quote(bp.condition))
          else
            M.session:send_async("-break-condition " .. bp.id)
          end
        elseif bp.enabled then
          M.session:insert_breakpoint(bp)
        end
      end
    end
    if opts.enabled ~= nil then
      bp.enabled = opts.enabled
      if M.session then
        if bp.enabled then M.session:insert_breakpoint(bp)
        else M.session:delete_breakpoint(bp, false) end
      end
    end
  end
  persist_breakpoints()
  emit("breakpoints")
  core.redraw = true
  return bp
end

function M.toggle_breakpoint(file, line)
  if not file or not line then return end
  local bp = M.breakpoint_at(file, line)
  if bp then
    M.remove_breakpoint(file, line)
  else
    return M.set_breakpoint(file, line)
  end
end

function M.remove_breakpoint(file, line)
  local lines = M.breakpoints[file]
  local bp = lines and lines[line]
  if not bp then return end
  lines[line] = nil
  if next(lines) == nil then M.breakpoints[file] = nil end
  if M.session then M.session:delete_breakpoint(bp, true) end
  persist_breakpoints()
  emit("breakpoints")
  core.redraw = true
end

function M.toggle_breakpoint_enabled(file, line)
  local bp = M.breakpoint_at(file, line)
  if not bp then return end
  M.set_breakpoint(file, line, { enabled = not bp.enabled })
end

function M.clear_breakpoints()
  for _, entry in ipairs(M.iter_breakpoints()) do
    if M.session then M.session:delete_breakpoint(entry.bp, true) end
  end
  M.breakpoints = {}
  persist_breakpoints()
  emit("breakpoints")
  core.redraw = true
end

-- Session ---------------------------------------------------------------------

local Session = {}
Session.__index = Session

function Session.new(cfg)
  local self = setmetatable({}, Session)
  self.cfg = cfg
  self.token = 0
  self.pending = {}
  self.frames = {}
  self.threads = {}
  self.variables = {}
  self.registers = {}
  self.register_names = nil
  self.varobjs = {}
  self.selected_frame = 0
  self.selected_thread = nil
  self.current = nil
  self.prelaunch = nil
  self.exited = false
  return self
end

function Session:next_token()
  self.token = self.token + 1
  return self.token
end

function Session:send(line)
  if not self.proc then return end
  self.proc.stdin:write(line .. "\n")
end

function Session:send_async(mi, cb)
  local token = self:next_token()
  if cb then self.pending[token] = cb end
  self:send(token .. mi)
  return token
end

---Send a command and wait for its result record. Must run in a coroutine.
function Session:request(mi, timeout)
  local token = self:next_token()
  local box = {}
  self.pending[token] = function(rec) box.rec = rec end
  self:send(token .. mi)
  local deadline = system.get_time() + (timeout or config.plugins.gdb.launch_timeout or 25)
  while not box.rec do
    if self.exited or not self.proc then return nil, "gdb exited" end
    if system.get_time() > deadline then
      self.pending[token] = nil
      return nil, "timeout"
    end
    coroutine.yield(0.02)
  end
  local rec = box.rec
  if rec.class == "error" then
    return nil, tostring(rec.msg or "error"), rec
  end
  return rec
end

function Session:log(text, kind)
  output(text, kind)
end

-- Python/extension bootstrap noise printed by some builds of GDB (notably
-- Debian/Ubuntu arm-none-eabi-gdb) right after startup.
local STDERR_NOISE = {
  "^Python Exception",
  "^Installation error",
  "^Could not load the Python gdb module",
  "^Limited Python support is available",
  "^Suggest passing %-%-data%-directory",
}

local function is_noise(text)
  for _, pat in ipairs(STDERR_NOISE) do
    if text:match(pat) then return true end
  end
  return false
end

function Session:handle_stream(kind, text)
  if is_noise(text) then return end
  if kind == "&" then
    output(text, "log")
  elseif kind == "@" then
    output(text, "target")
  else
    output(text, "console")
  end
end

function Session:handle_result(token, payload)
  if token and self.pending[token] then
    local cb = self.pending[token]
    self.pending[token] = nil
    local ok, err = pcall(cb, payload)
    if not ok then core.error("debug callback: %s", err) end
  end
  if payload.class == "error" then
    output("error: " .. tostring(payload.msg or "unknown error"), "error")
  end
end

function Session:handle_async(payload)
  local class = payload.class
  if class == "stopped" then
    self:handle_stopped(payload)
  elseif class == "running" then
    set_state("running")
    self.current = nil
    emit("update")
  elseif class == "breakpoint-modified" or class == "breakpoint-created" then
    self:update_breakpoint(payload.bkpt)
  elseif class == "thread-created" or class == "thread-exited"
      or class == "thread-group-started" or class == "thread-group-exited" then
    self:refresh_threads()
  end
end

function Session:update_breakpoint(bkpt)
  if type(bkpt) ~= "table" or not bkpt.number then return end
  local number = tonumber(bkpt.number)
  for _, entry in ipairs(M.iter_breakpoints()) do
    if entry.bp.id == number then
      entry.bp.verified = bkpt.verified == "y"
      if bkpt.enabled then entry.bp.enabled = bkpt.enabled ~= "n" end
      emit("breakpoints")
      return
    end
  end
end

function Session:handle_line(line)
  if self.stopping or self.exited then return end
  if line == "" then
    return
  end
  if line:match("^%d*%(gdb%)%s*$") then
    return
  end
  local token, kind, payload = parser.parse_record(line)
  if not kind then
    -- Anything that is not an MI record is program output on the shared
    -- stdout (gdb does not wrap the inferior's own stdout).
    output(line, "target")
    return
  end
  if kind == "~" or kind == "@" or kind == "&" then
    self:handle_stream(kind, payload)
  elseif kind == "^" then
    self:handle_result(token, payload)
  elseif kind == "*" or kind == "=" or kind == "+" then
    self:handle_async(payload)
  end
end

function Session:read_loop()
  local stdout, stderr = self.proc.stdout, self.proc.stderr
  while self.proc do
    local got = false
    for _ = 1, 500 do
      local ok, line = pcall(stdout.read, stdout, "*l", { timeout = 0.02 })
      if not ok or line == nil then break end
      got = true
      self:handle_line(line)
    end
    for _ = 1, 100 do
      local ok, line = pcall(stderr.read, stderr, "*l", { timeout = 0.01 })
      if not ok or line == nil then break end
      if line ~= "" and not is_noise(line) then
        output(line, "log")
      end
      got = true
    end
    if not self.proc:running() then break end
    coroutine.yield(got and 0.001 or 0.02)
  end
  self:on_gdb_exit()
end

function Session:handle_stopped(payload)
  local reason = payload.reason
  if reason == "exited-normally" or reason == "exited" then
    set_state("exited")
    self.frames, self.variables, self.registers = {}, {}, {}
    self.current = nil
    output("[inferior exited" .. (payload["exit-code"] and (" with code " .. payload["exit-code"]) or "") .. "]", "info")
    emit("exit")
    return
  end
  if reason == "exited-signalled" then
    set_state("exited")
    self.frames, self.variables, self.registers = {}, {}, {}
    self.current = nil
    output("[inferior killed by signal " .. tostring(payload["signal-name"] or "?") .. "]", "error")
    emit("exit")
    return
  end
  set_state("paused")
  self.selected_frame = 0
  local frame = payload.frame
  if frame then
    local file = frame.fullname or frame.file
    if file and not is_absolute(file) then
      file = join_path(self.cfg.cwd or project_path(), file)
    end
    self.current = {
      reason = reason,
      func = frame.func,
      addr = frame.addr,
      file = file,
      line = tonumber(frame.line),
    }
  else
    self.current = { reason = reason }
  end
  if payload.bkptno then
    for _, entry in ipairs(M.iter_breakpoints()) do
      if tostring(entry.bp.id) == tostring(payload.bkptno) then
        entry.bp.hits = tonumber(payload.times) or ((entry.bp.hits or 0) + 1)
        break
      end
    end
  end
  self:clear_varobjs()
  self:refresh_frames()
  self:refresh_threads()
  self:refresh_variables()
  self:refresh_registers()
  emit("stop", self.current, payload)
  if config.plugins.gdb.auto_open_source and self.current.file and self.current.line then
    emit("jump", self.current.file, self.current.line)
  end
  core.redraw = true
end

function Session:clear_varobjs()
  for _, name in ipairs(self.varobjs) do
    self:send_async("-var-delete " .. name)
  end
  self.varobjs = {}
end

function Session:refresh_frames()
  self:send_async("-stack-list-frames", function(rec)
    if rec.class ~= "done" then return end
    local frames = {}
    local function walk(list)
      for _, item in ipairs(list or {}) do
        local f = item.frame or item
        if f and f.level then frames[#frames + 1] = f end
        if f and f.frames then walk(f.frames) end
      end
    end
    walk(rec.stack)
    table.sort(frames, function(a, b)
      return (tonumber(a.level) or 0) < (tonumber(b.level) or 0)
    end)
    self.frames = frames
    emit("update")
    core.redraw = true
  end)
end

function Session:refresh_threads()
  self:send_async("-thread-info", function(rec)
    if rec.class ~= "done" then return end
    self.threads = rec.threads or {}
    self.selected_thread = rec["current-thread-id"]
    emit("update")
  end)
end

function Session:refresh_variables()
  self:send_async("-stack-list-variables --simple-values", function(rec)
    if rec.class ~= "done" then return end
    local vars = {}
    for _, v in ipairs(rec.variables or {}) do
      vars[#vars + 1] = {
        name = v.name,
        type = v.type,
        value = v.value,
        arg = v.arg == "1",
        expandable = v.value == nil,
        expanded = false,
        children = nil,
        depth = 0,
      }
    end
    self.variables = vars
    emit("update")
    core.redraw = true
  end)
end

function Session:refresh_registers()
  if not config.plugins.gdb.show_registers then return end
  local function fetch_values()
    self:send_async("-data-list-register-values x", function(rec)
      if rec.class ~= "done" then return end
      local names = self.register_names or {}
      local regs = {}
      local re = "^(r%d+|sp|lr|pc|cpsr|xpsr|msp|psp|x%d+|w%d+|fp)$"
      for _, item in ipairs(rec["register-values"] or {}) do
        local idx = tonumber(item.number) + 1
        local name = names[idx]
        if name and name ~= "" and name:match(re) then
          regs[#regs + 1] = { name = name, value = item.value }
        end
      end
      if #regs == 0 then
        for _, item in ipairs(rec["register-values"] or {}) do
          local idx = tonumber(item.number) + 1
          local name = names[idx]
          if name and name ~= "" and #regs < 16 then
            regs[#regs + 1] = { name = name, value = item.value }
          end
        end
      end
      self.registers = regs
      emit("update")
      core.redraw = true
    end)
  end
  if self.register_names then
    fetch_values()
  else
    self:send_async("-data-list-register-names", function(rec)
      if rec.class ~= "done" then return end
      self.register_names = rec["register-names"] or {}
      fetch_values()
    end)
  end
end

function Session:select_frame(level)
  self:send_async("-stack-select-frame " .. level, function(rec)
    if rec.class ~= "done" then return end
    self.selected_frame = tonumber(level) or 0
    self:clear_varobjs()
    self:refresh_variables()
    self:refresh_registers()
    local f = self.frames[self.selected_frame + 1]
    if f then
      local file = f.fullname or f.file
      if file and not is_absolute(file) then
        file = join_path(self.cfg.cwd or project_path(), file)
      end
      if file and f.line then emit("jump", file, tonumber(f.line)) end
    end
    emit("update")
    core.redraw = true
  end)
end

function Session:select_thread(id)
  self:send_async("-thread-select " .. tostring(id), function(rec)
    if rec.class ~= "done" then return end
    self.selected_thread = tostring(id)
    self.selected_frame = 0
    self:clear_varobjs()
    self:refresh_frames()
    self:refresh_variables()
    self:refresh_registers()
    emit("update")
  end)
end

local function flatten_children(rec)
  local out = {}
  for _, item in ipairs(rec.children or {}) do
    local c = item.child or item
    local numchild = tonumber(c.numchild) or 0
    out[#out + 1] = {
      name = c.exp or c.name,
      type = c.type,
      value = c.value,
      varobj = c.name,
      expandable = numchild > 0,
      expanded = false,
      children = nil,
      depth = 0,
    }
  end
  return out
end

---Expand a variable row (locals/args or a child of a var object).
function Session:expand_variable(var)
  if var.children then
    var.expanded = not var.expanded
    emit("update")
    core.redraw = true
    return
  end
  if var.varobj then
    self:send_async("-var-list-children --all-values " .. var.varobj, function(rec)
      if rec.class ~= "done" then return end
      var.children = flatten_children(rec)
      var.expanded = true
      emit("update")
      core.redraw = true
    end)
    return
  end
  self:send_async("-var-create - * " .. M.quote(var.name), function(rec)
    if rec.class ~= "done" then
      output("cannot inspect " .. tostring(var.name) .. ": " .. tostring(rec.msg), "error")
      return
    end
    var.varobj = rec.name
    table.insert(self.varobjs, rec.name)
    self:send_async("-var-list-children --all-values " .. rec.name, function(rec2)
      if rec2.class ~= "done" then return end
      var.children = flatten_children(rec2)
      var.expanded = true
      emit("update")
      core.redraw = true
    end)
  end)
end

function Session:insert_breakpoint(bp)
  local location = bp.file .. ":" .. bp.line
  local cmd = "-break-insert -f "
  if bp.condition and bp.condition ~= "" then
    cmd = cmd .. "-c " .. M.quote(bp.condition) .. " "
  end
  cmd = cmd .. M.quote(location)
  self:send_async(cmd, function(rec)
    if rec.class == "done" and rec.bkpt then
      bp.id = tonumber(rec.bkpt.number)
      bp.verified = rec.bkpt.addr ~= "<PENDING>"
      emit("breakpoints")
    else
      output("breakpoint " .. location .. ": " .. tostring(rec.msg or "failed"), "error")
    end
    core.redraw = true
  end)
end

function Session:delete_breakpoint(bp, forget)
  if bp.id then
    self:send_async("-break-delete " .. bp.id)
    bp.id = nil
  end
  bp.verified = false
  if not forget then bp.id = nil end
end

function Session:insert_all_breakpoints()
  for _, entry in ipairs(M.iter_breakpoints()) do
    if entry.bp.enabled then
      entry.bp.id = nil
      self:insert_breakpoint(entry.bp)
    end
  end
end

function Session:start_prelaunch()
  local cmd = self.cfg.pre_launch
  if not cmd then return end
  local argv
  if type(cmd) == "table" then argv = cmd
  else argv = { "sh", "-c", tostring(cmd) } end
  local ok, proc = pcall(process.start, argv, { cwd = self.cfg.cwd or project_path() })
  if not ok or not proc then
    output("could not start pre-launch command: " .. tostring(proc), "error")
    return
  end
  self.prelaunch = proc
  output("$ " .. (type(cmd) == "table" and table.concat(cmd, " ") or cmd), "info")
  core.add_thread(function()
    while proc:running() do
      local ok1, line = pcall(proc.stdout.read, proc.stdout, "*l", { timeout = 0.1 })
      if ok1 and line then output(line, "log") end
      local ok2, eline = pcall(proc.stderr.read, proc.stderr, "*l", { timeout = 0.1 })
      if ok2 and eline then output(eline, "log") end
      coroutine.yield(0.05)
    end
  end)
end

function Session:kill_prelaunch()
  if self.prelaunch and self.prelaunch:running() then
    self.prelaunch:kill()
  end
  self.prelaunch = nil
end

function Session:spawn()
  local gdb = self.cfg.gdb or config.plugins.gdb.gdb or "gdb"
  local argv = { gdb, "-q", "--interpreter=mi2",
    "-iex", "set pagination off", "-iex", "set confirm off" }
  for _, a in ipairs(config.plugins.gdb.args or {}) do argv[#argv + 1] = a end
  for _, a in ipairs(self.cfg.gdb_args or {}) do argv[#argv + 1] = a end
  local opts = { cwd = self.cfg.cwd or project_path() }
  if self.cfg.env then opts.env = self.cfg.env end
  local ok, proc = pcall(process.start, argv, opts)
  if not ok or not proc then
    return nil, "could not start " .. tostring(gdb) .. ": " .. tostring(proc)
  end
  self.proc = proc
  output("$ " .. table.concat(argv, " "), "info")
  return true
end

function Session:initialize()
  local cfg = self.cfg
  if not self:request("-gdb-set mi-async on", 3) then
    self:request("-gdb-set target-async on", 3)
  end
  self:request("-gdb-set pagination off", 2)
  if cfg.architecture then
    self:request("-interpreter-exec console " .. M.quote("set architecture " .. cfg.architecture), 5)
  end
  if cfg.cwd then
    self:request("-environment-cd " .. M.quote(cfg.cwd), 5)
  end
  for k, v in pairs(cfg.env or {}) do
    self:request("-gdb-set environment " .. M.quote(k .. "=" .. v), 5)
  end
  if cfg.program then
    local rec, err = self:request("-file-exec-and-symbols " .. M.quote(cfg.program), 20)
    if not rec then return nil, "loading " .. cfg.program .. ": " .. tostring(err) end
    if cfg.args and #cfg.args > 0 then
      local quoted = {}
      for _, a in ipairs(cfg.args) do quoted[#quoted + 1] = M.quote(a) end
      self:request("-exec-arguments " .. table.concat(quoted, " "), 5)
    end
  end
  for _, cmd in ipairs(cfg.init_commands or {}) do
    self:request("-interpreter-exec console " .. M.quote(cmd), 15)
  end
  if cfg.target then
    local target_type = cfg.target_type or "extended-remote"
    -- GDB's MI parser wants the remote target unquoted ("host:port");
    -- quoting it makes getaddrinfo treat the whole string as a host name.
    local rec, err = self:request(
      "-target-select " .. target_type .. " " .. cfg.target,
      cfg.connect_timeout or config.plugins.gdb.connect_timeout or 10)
    if not rec then
      return nil, "connecting to " .. cfg.target .. ": " .. tostring(err)
    end
    output("connected to " .. cfg.target, "info")
  end
  if cfg.attach_pid then
    local rec, err = self:request("-target-attach " .. tostring(cfg.attach_pid), 10)
    if not rec then return nil, "attach: " .. tostring(err) end
  end
  self:insert_all_breakpoints()
  local cmd
  if cfg.run_command then
    cmd = cfg.run_command
  elseif cfg.target or cfg.attach_pid then
    cmd = cfg.stop_at_entry and nil or "-exec-continue"
  elseif cfg.stop_at_entry then
    cmd = "-exec-run --start"
  else
    cmd = "-exec-run"
  end
  if not cmd then return true end
  self:send_async(cmd, function(rec)
    if rec.class == "error" then
      if cmd == "-exec-run --start" then
        self:send_async("-exec-run", nil)
      end
    end
  end)
  return true
end

function Session:fail(message)
  output("debug: " .. tostring(message), "error")
  self:kill_prelaunch()
  if self.proc and self.proc:running() then self.proc:kill() end
  self.proc = nil
  self.exited = true
  if M.session == self then
    M.session = nil
    set_state("idle")
  end
end

function Session:on_gdb_exit()
  if self.exited then return end
  self.exited = true
  self:kill_prelaunch()
  if M.session == self then
    M.session = nil
    -- keep the "exited" state visible if the inferior finished first
    if M.state ~= "exited" then set_state("idle") end
    emit("exit")
  end
  core.redraw = true
end

function Session:launch()
  local self_ = self
  core.add_thread(function()
    set_state("starting")
    self_:start_prelaunch()
    if self_.prelaunch and self_.cfg.pre_launch_delay then
      coroutine.yield(self_.cfg.pre_launch_delay)
    elseif self_.prelaunch then
      coroutine.yield(1.0)
    end
    local ok, err = self_:spawn()
    if not ok then self_:fail(err) return end
    core.add_thread(function() self_:read_loop() end)
    coroutine.yield(0.05)
    local ok2, err2 = self_:initialize()
    if not ok2 then self_:fail(err2) end
  end)
end

-- Start / stop / execution ----------------------------------------------------

local function resolve_config(value)
  if type(value) == "table" then return normalize_config(value) end
  if type(value) == "string" then return M.get_config(value) end
end

function M.start(value)
  if M.session then
    if M.state == "paused" then return M.continue() end
    core.error("debug: a session is already %s", M.state)
    return
  end
  M.load_configs(true)
  M.load_project_breakpoints()
  local cfg = resolve_config(value) or M.last_config or M.load_configs()[1]
  if not cfg then
    core.error("debug: no launch configuration (add one to %s or config.plugins.gdb.configs)",
      "<project>/.max-xl/" .. config.plugins.gdb.config_file)
    return
  end
  if not cfg.gdb then cfg.gdb = config.plugins.gdb.gdb end
  M.last_config = cfg
  local session = Session.new(cfg)
  M.session = session
  emit("start", cfg)
  session:launch()
end

function M.start_interactive()
  local configs = M.load_configs()
  if #configs == 0 then
    core.error("debug: no launch configuration (add one to %s or config.plugins.gdb.configs)",
      "<project>/.max-xl/" .. config.plugins.gdb.config_file)
    return
  end
  if #configs == 1 then return M.start(configs[1]) end
  local names = {}
  for _, c in ipairs(configs) do names[#names + 1] = c.name end
  core.command_view:enter("Debug Configuration", {
    text = M.last_config and M.last_config.name or names[1],
    submit = function(text)
      for _, c in ipairs(configs) do
        if c.name == text then return M.start(c) end
      end
      core.error("debug: unknown configuration '%s'", text)
    end,
    suggest = function() return names end,
  })
end

function M.stop()
  local session = M.session
  if not session then
    if M.state == "exited" then set_state("idle") end
    return
  end
  session.stopping = true
  session:send_async("-gdb-exit")
  core.add_thread(function()
    local deadline = system.get_time() + 2
    while session.proc and session.proc:running() and system.get_time() < deadline do
      coroutine.yield(0.05)
    end
    if session.proc and session.proc:running() then session.proc:kill() end
    session:kill_prelaunch()
    if M.session == session then
      M.session = nil
      set_state("idle")
      emit("exit")
    end
  end)
end

function M.restart()
  local session = M.session
  if not session then
    return M.start_interactive()
  end
  -- A remote/attached target cannot be re-run in place: tear the whole
  -- session down (GDB + pre-launch server) and connect again.
  if session.cfg.target or session.cfg.attach_pid then
    local cfg = session.cfg
    local function finish()
      if session.proc and session.proc:running() then session.proc:kill() end
      session:kill_prelaunch()
      if M.session == session then
        M.session = nil
        set_state("idle")
        emit("exit")
      end
      M.start(cfg)
    end
    session.stopping = true
    if session.proc and session.proc:running() then
      session:send_async("-gdb-exit")
      core.add_thread(function()
        local deadline = system.get_time() + 2
        while session.proc and session.proc:running() and system.get_time() < deadline do
          coroutine.yield(0.05)
        end
        finish()
      end)
    else
      finish()
    end
    return
  end
  local was_running = M.state == "running"
  set_state("starting")
  session.selected_frame = 0
  session.current = nil
  session:clear_varobjs()
  local function run()
    session:send_async("-exec-run", function(rec)
      if rec.class == "error" then
        session:send_async("-exec-continue")
      end
    end)
  end
  if was_running then
    session:send_async("-exec-interrupt", function() run() end)
  else
    run()
  end
end

function M.continue()
  local session = M.session
  if not session then return M.start_interactive() end
  if M.state == "exited" then return M.restart() end
  if M.state == "paused" then
    session:send_async("-exec-continue")
  end
end

function M.pause()
  if M.session and M.state == "running" then
    M.session:send_async("-exec-interrupt")
  end
end

local function step(cmd)
  local session = M.session
  if not session or M.state ~= "paused" then return end
  session:send_async(cmd)
end

function M.step_over() step("-exec-next") end
function M.step_into() step("-exec-step") end
function M.step_out() step("-exec-finish") end

function M.run_to_cursor()
  local session = M.session
  local av = core.active_view
  if not session or M.state ~= "paused" or not av or not av.doc then return end
  local file = av.doc.abs_filename
  if not file then return end
  local line = av.doc:get_selection()
  session:send_async("-exec-until " .. M.quote(file .. ":" .. line))
end

---Execute a raw command from the debug console. MI commands (starting with
---'-') are sent verbatim; anything else runs in GDB's CLI.
function M.execute(text)
  local session = M.session
  if not session then
    core.error("debug: no active session")
    return
  end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return end
  if text == "quit" or text == "q" then return M.stop() end
  output("(gdb) " .. text, "info")
  if text:sub(1, 1) == "-" then
    session:send_async(text, function(rec)
      if rec.class ~= "done" and rec.class ~= "running" and rec.class ~= "connected" then
        output(tostring(rec.msg or rec.class), "error")
      end
    end)
  else
    session:send_async("-interpreter-exec console " .. M.quote(text), function(rec)
      if rec.class ~= "done" then
        output(tostring(rec.msg or "command failed"), "error")
      end
    end)
  end
end

-- Convenience queries used by the UI -----------------------------------------

function M.is_running()
  return M.state == "running" or M.state == "starting"
end

function M.is_paused()
  return M.state == "paused"
end

function M.current_location()
  local s = M.session
  if s and s.current then return s.current.file, s.current.line, s.current end
end

function M.is_stopped_at(file, line)
  local s = M.session
  return s and s.current and s.current.file == file and s.current.line == line
end

return M
