-- mod-version:4
-- Language Server Protocol client.
--
-- Talks JSON-RPC over stdio to one server process per project root, using the
-- same `core.process` pipes the GDB and console plugins use. The default
-- configuration starts `clangd` for C/C++ files; other servers can be added
-- through `config.plugins.lsp.servers`.
--
-- What the editor gains:
--   * diagnostics in the Problems panel (Ctrl+Shift+M), updated as you type;
--   * real completions in the autocomplete box (typing or Ctrl+Space);
--   * go to definition (F12) and references (Shift+F12);
--   * hover with type/signature info (Ctrl+Shift+H);
--   * document symbols (Ctrl+Alt+O), rename (F2) and formatting (Alt+Shift+F).
--
-- Server configuration (fields can be set per server):
--   command       table|string   command line (default: { "clangd" })
--   files         string[]       Lua patterns of handled files
--   language      table          extension -> LSP languageId
--   root_markers  string[]       files/dirs that mark a project root
--   init_options  table          initializationOptions sent to the server
--
-- Example:
--   config.plugins.lsp.servers.clangd = {
--     command = { "clangd", "--background-index", "--clang-tidy" },
--   }

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local process = require "core.process"
local Doc = require "core.doc"
local RootView = require "core.rootview"
local json = require "plugins.lsp.json"

config.plugins.lsp = common.merge({
  -- Start a server when a matching file is opened.
  auto_start = true,
  -- Ask servers for completions while typing.
  auto_complete = true,
  -- Seconds of idle time before pending edits are pushed to the server.
  change_delay = 0.25,
  -- Log the server stderr to the editor log.
  log_stderr = false,
  -- Hover popup tuning.
  hover_max_width = 560,
  hover_max_lines = 18,
  hover_timeout = 10,
  -- Additional servers / overrides, keyed by name.
  servers = {},
}, config.plugins.lsp)

local M = { sessions = {} }

-- Forward declarations used by the session methods below.
local update_status

---@type plugins.problems|nil|false
local problems
local function get_problems()
  if problems == nil then
    local ok, mod = pcall(require, "plugins.problems")
    problems = ok and mod or false
  end
  return problems or nil
end

local function set_diagnostics(source, items)
  local registry = get_problems()
  if registry then registry.set(source, items) end
end

local function clear_diagnostics(source)
  local registry = get_problems()
  if registry then registry.clear(source) end
end

-- Small utilities ------------------------------------------------------------

local function split_command(cmd)
  local args = {}
  for arg in cmd:gmatch("%S+") do table.insert(args, arg) end
  return args
end

local function doc_text(doc)
  -- Lite XL keeps the newline at the end of every line.
  return table.concat(doc.lines, "")
end

---A document line without its trailing newline (LSP positions never include it).
local function doc_line(doc, line)
  return (doc.lines[line] or ""):gsub("\n$", "")
end

---Return the LSP end position (0-based line, UTF-16 character) of a text.
local function text_end_position(text)
  local line, pos = 0, 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then
      local tail = text:sub(pos)
      return line, M.col_to_utf16(tail, #tail + 1)
    end
    line = line + 1
    pos = nl + 1
  end
end

local function active_doc_view()
  local av = core.active_view
  if av and av.doc then return av end
end

local function uri_encode(byte)
  return string.format("%%%02X", byte:byte())
end

---Convert an absolute path into a `file://` URI.
---@param path string
---@return string
function M.uri_from_path(path)
  path = common.normalize_path(path)
  if PLATFORM == "Windows" then
    path = path:gsub("\\", "/")
    if not path:match("^/") then path = "/" .. path end
  end
  local escaped = path:gsub("[^%w%-%._~!$&'()*+,;=:@/]", uri_encode)
  return "file://" .. escaped
end

---Convert a `file://` URI back into a path.
---@param uri string
---@return string
function M.path_from_uri(uri)
  local path = uri:gsub("^file://", "")
  path = path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if PLATFORM == "Windows" and path:match("^/%a:") then
    path = path:sub(2)
  end
  return common.normalize_path(path)
end

---Return the number of bytes in the UTF-8 sequence starting with `byte`.
---Malformed input is treated as a single byte so column mapping never throws.
local function utf8_sequence_length(byte)
  if byte < 0xC0 then return 1 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  if byte < 0xF8 then return 4 end
  return 1
end

---Byte column -> UTF-16 code units (LSP positions).
---@param line string
---@param col integer 1-based byte column
---@return integer
function M.col_to_utf16(line, col)
  local units, pos = 0, 1
  while pos < col do
    local byte = line:byte(pos)
    if not byte then break end
    local length = utf8_sequence_length(byte)
    if length == 4 then
      units = units + 2
    else
      units = units + 1
    end
    pos = pos + length
  end
  return units
end

---UTF-16 code units -> byte column.
---@param line string
---@param character integer 0-based UTF-16 offset
---@return integer 1-based byte column
function M.utf16_to_col(line, character)
  local units, pos = 0, 1
  while pos <= #line do
    if units >= character then return pos end
    local length = utf8_sequence_length(line:byte(pos))
    local width = length == 4 and 2 or 1
    if units + width > character then return pos end
    units = units + width
    pos = pos + length
  end
  return #line + 1
end

local function lsp_position(doc, line, col)
  return { line = line - 1, character = M.col_to_utf16(doc_line(doc, line), col) }
end

local function doc_uri(doc)
  return M.uri_from_path(doc.abs_filename)
end

-- Server configuration -------------------------------------------------------

local DEFAULT_SERVERS = {
  clangd = {
    command = { "clangd" },
    files = {
      "%.c$", "%.h$", "%.cc$", "%.cpp$", "%.cxx$", "%.c++$",
      "%.hpp$", "%.hh$", "%.hxx$", "%.h++$", "%.m$", "%.mm$", "%.cu$",
    },
    language = {
      c = "c", h = "c", cc = "cpp", cpp = "cpp", cxx = "cpp", ["c++"] = "cpp",
      hpp = "cpp", hh = "cpp", hxx = "cpp", ["h++"] = "cpp",
      m = "objective-c", mm = "objective-cpp", cu = "cuda",
    },
    root_markers = {
      "compile_commands.json", "compile_flags.txt", ".clangd",
      "build/compile_commands.json", "CMakeLists.txt", "meson.build",
      "Makefile", ".git",
    },
    init_options = {},
  },
}

---Servers to consider, user-defined ones first (so they win during lookup).
---A server set to `false` in `config.plugins.lsp.servers` disables the built-in.
---@return table[]
local function ordered_servers()
  local user = config.plugins.lsp.servers or {}
  local out, disabled = {}, {}
  local names = {}
  for name, cfg in pairs(user) do
    if cfg == false then
      disabled[name] = true
    else
      table.insert(names, name)
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local cfg = common.merge(DEFAULT_SERVERS[name] or {}, user[name])
    cfg.name = name
    table.insert(out, cfg)
  end
  local defaults = {}
  for name in pairs(DEFAULT_SERVERS) do
    if not disabled[name] and not user[name] then
      table.insert(defaults, name)
    end
  end
  table.sort(defaults)
  for _, name in ipairs(defaults) do
    local cfg = common.merge({}, DEFAULT_SERVERS[name])
    cfg.name = name
    table.insert(out, cfg)
  end
  return out
end

---Find the server that handles a document.
---@param doc core.doc
---@return table|nil
function M.find_server(doc)
  local name = doc.abs_filename or doc.filename
  if not name then return end
  for _, server in ipairs(ordered_servers()) do
    if common.match_pattern(name, server.files or {}) then
      return server
    end
  end
end

---Find the project root used for a server session.
---@param doc core.doc
---@param server table
---@return string
function M.find_root(doc, server)
  local abs = doc.abs_filename
  local dir = common.dirname(abs)

  local stop
  for _, project in ipairs(core.projects) do
    if common.path_belongs_to(abs, project.path)
        and (not stop or #project.path > #stop) then
      stop = project.path
    end
  end

  local markers = server.root_markers or { "compile_commands.json", ".git" }
  local d = dir
  while d and d ~= "" do
    for _, marker in ipairs(markers) do
      if system.get_file_info(d .. PATHSEP .. marker) then return d end
    end
    if stop and d == stop then break end
    local parent = common.dirname(d)
    if parent == d or parent == "" then break end
    d = parent
  end
  return stop or dir
end

-- Hover popup ----------------------------------------------------------------

local hover = {
  visible = false,
  position = { x = 0, y = 0 },
  size = { x = 0, y = 0 },
  lines = {},
  expires = 0,
}
M.ui = { hover = hover }

local function hide_hover()
  if hover.visible then
    hover.visible = false
    core.redraw = true
  end
end

local function hover_font()
  return style.code_font
end

local function wrap_text(text, font, max_width)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      table.insert(lines, "")
    else
      local line = ""
      for word in raw:gmatch("%S+%s*") do
        if line ~= "" and font:get_width(line .. word) > max_width then
          table.insert(lines, (line:gsub("%s+$", "")))
          line = word
        else
          line = line .. word
        end
      end
      table.insert(lines, (line:gsub("%s+$", "")))
    end
  end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end

local function markup_text(contents)
  if type(contents) == "string" then return contents end
  if type(contents) ~= "table" then return "" end
  if contents.value then return tostring(contents.value) end
  local parts = {}
  for _, part in ipairs(contents) do
    local text = markup_text(part)
    if text ~= "" then table.insert(parts, text) end
  end
  return table.concat(parts, "\n")
end

local function sanitize_markup(text)
  text = text:gsub("\r", "")
  text = text:gsub("```[%w+%-]*\n?", "")
  text = text:gsub("`([^`]*)`", "%1")
  text = text:gsub("%*%*([^*]-)%*%*", "%1")
  return text
end

local function show_hover(text)
  text = sanitize_markup(text)
  if text:match("^%s*$") then return end

  local font = hover_font()
  local max_width = config.plugins.lsp.hover_max_width - style.padding.x * 2
  local lines = wrap_text(text, font, max_width)
  local max_lines = config.plugins.lsp.hover_max_lines
  if #lines > max_lines then
    lines = { table.unpack(lines, 1, max_lines) }
    lines[#lines] = lines[#lines] .. " …"
  end

  local pad = style.padding.x
  local lh = font:get_height()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, font:get_width(line))
  end
  width = math.min(width + pad * 2, config.plugins.lsp.hover_max_width)
  local height = #lines * lh + pad * 2

  local mouse = core.root_view.mouse
  local x, y
  local dv = active_doc_view()
  if dv then
    -- Show the popup under the caret: hover works without ever using the mouse.
    local line, col = dv.doc:get_selection()
    x, y = dv:get_line_screen_position(line, col)
    y = y + dv:get_font():get_height() + 4
  else
    x = (mouse and mouse.x or 0) + 16
    y = (mouse and mouse.y or 0) + 16
  end
  if x + width > core.root_view.size.x then
    x = math.max(0, core.root_view.size.x - width - 4)
  end
  if y + height > core.root_view.size.y then
    y = math.max(0, y - height - (dv and dv:get_font():get_height() or 0) * 2)
  end

  hover.lines = lines
  hover.position.x, hover.position.y = x, y
  hover.size.x, hover.size.y = width, height
  hover.expires = system.get_time() + config.plugins.lsp.hover_timeout
  hover.visible = true
  core.redraw = true
end

local function draw_hover()
  if not hover.visible then return end
  if system.get_time() > hover.expires then
    hover.visible = false
    return
  end
  local font = hover_font()
  local pad = style.padding.x
  local lh = font:get_height()
  local x, y, w, h = hover.position.x, hover.position.y, hover.size.x, hover.size.y

  renderer.draw_rect(x, y, w, h, style.background2 or style.background)
  renderer.draw_rect(x, y, w, 1, style.divider)
  renderer.draw_rect(x, y + h - 1, w, 1, style.divider)
  renderer.draw_rect(x, y, 1, h, style.divider)
  renderer.draw_rect(x + w - 1, y, 1, h, style.divider)

  core.push_clip_rect(x, y, w, h)
  local ty = y + pad
  for _, line in ipairs(hover.lines) do
    common.draw_text(font, style.text, line, "left", x + pad, ty, w - pad * 2, lh)
    ty = ty + lh
  end
  core.pop_clip_rect()
end

local base_draw = RootView.draw
function RootView:draw(...)
  base_draw(self, ...)
  draw_hover()
end

local base_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(...)
  hide_hover()
  return base_mouse_pressed(self, ...)
end

-- Session ---------------------------------------------------------------------

local Session = {}
Session.__index = Session

local SEVERITY = { [1] = "error", [2] = "warning", [3] = "info", [4] = "info" }

function Session:new(server, root)
  local session = setmetatable({}, Session)
  session.server = server
  session.root = root
  session.key = server.name .. "\0" .. root
  session.state = "starting"
  session.next_id = 0
  session.pending = {}
  session.queue = {}
  session.open_uris = {}
  session.versions = {}
  session.sent = {}
  session.diags = {}
  session.dirty = {}
  session.after_ready = {}
  session.sync_kind = 1
  session.problems_source = string.format("lsp:%s:%s", server.name, root)
  return session
end

function Session:owns(doc)
  if not doc.abs_filename then return false end
  local abs = doc.abs_filename
  if not common.path_belongs_to(abs, self.root) then return false end
  return common.match_pattern(abs, self.server.files or {}) and true or false
end

function Session:send(message)
  table.insert(self.queue, message)
end

function Session:notify(method, params)
  self:send({ jsonrpc = "2.0", method = method, params = params })
end

function Session:request(method, params, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.pending[id] = callback
  self:send({ jsonrpc = "2.0", id = id, method = method, params = params })
  return id
end

function Session:language_id(doc)
  local ext = (doc.abs_filename or ""):match("%.([%w_+]+)$")
  local map = self.server.language or {}
  return map[ext or ""] or (ext == "c" and "c" or "cpp")
end

function Session:initialize_params()
  return {
    clientInfo = { name = "max-xl" },
    rootPath = self.root,
    rootUri = M.uri_from_path(self.root),
    capabilities = {
      general = { positionEncodings = { "utf-16" } },
      workspace = {
        workspaceFolders = false,
        configuration = false,
        applyEdit = false,
      },
      textDocument = {
        synchronization = { dynamicRegistration = false, didSave = true },
        completion = {
          completionItem = {
            snippetSupport = false,
            documentationFormat = { "plaintext", "markdown" },
          },
          contextSupport = true,
        },
        hover = { contentFormat = { "plaintext", "markdown" } },
        definition = { linkSupport = true },
        references = {},
        documentSymbol = { hierarchicalDocumentSymbolSupport = true },
        formatting = {},
        rename = {},
      },
    },
    initializationOptions = self.server.init_options or {},
  }
end

function Session:start()
  local cmd = self.server.command or { "clangd" }
  if type(cmd) == "string" then cmd = split_command(cmd) end

  local ok, proc = pcall(process.start, cmd, { cwd = self.root })
  if not ok or not proc then
    self.state = "error"
    self.error = tostring(proc)
    core.error("lsp: cannot start %s: %s", self.server.name, tostring(proc))
    return false
  end

  self.proc = proc
  core.add_thread(function() self:read_loop() end)
  core.add_thread(function() self:write_loop() end)
  core.add_thread(function() self:error_loop() end)

  self:request("initialize", self:initialize_params(), function(result, err)
    if err then
      self.state = "error"
      self.error = err.message or "initialize failed"
      core.error("lsp: %s: %s", self.server.name, self.error)
      update_status()
      return
    end

    local caps = (result and result.capabilities) or {}
    local sync = caps.textDocumentSync
    if type(sync) == "table" then
      self.sync_kind = sync.change or 1
    elseif type(sync) == "number" then
      self.sync_kind = sync
    end
    self.state = "ready"
    self:notify("initialized", {})
    for _, doc in ipairs(core.docs) do
      if self:owns(doc) then self:open_doc(doc) end
    end
    for _, fn in ipairs(self.after_ready) do fn(self) end
    self.after_ready = {}
    update_status()
  end)

  return true
end

function Session:write_loop()
  local stdin = self.proc.stdin
  while self.state ~= "stopped" do
    local message = table.remove(self.queue, 1)
    if message then
      local body = json.encode(message)
      stdin:write(string.format("Content-Length: %d\r\n\r\n%s", #body, body))
    else
      coroutine.yield(0.02)
    end
  end
end

function Session:error_loop()
  local stream = self.proc.stderr
  while self.state ~= "stopped" do
    local ok, line = pcall(stream.read, stream, "*l", { timeout = 0.5 })
    if ok and line and config.plugins.lsp.log_stderr then
      core.log_quiet("lsp[%s]: %s", self.server.name, line)
    elseif not ok and not self.proc:running() then
      break
    end
  end
end

function Session:read_message()
  local stream = self.proc.stdout
  local length
  while true do
    local ok, line = pcall(stream.read, stream, "*l", { timeout = 0.5 })
    if not ok then
      if not self.proc:running() then return nil end
    elseif line == nil then
      return nil
    else
      -- `read("line")` keeps a trailing `\r` from CRLF framing.
      line = line:gsub("\r$", "")
      if line == "" then
        break
      end
      local n = line:match("^Content%-Length:%s*(%d+)")
      if n then length = tonumber(n) end
    end
  end
  if not length then
    core.log_quiet("lsp[%s]: missing Content-Length header", self.server.name)
    return nil
  end

  while true do
    local ok, body = pcall(stream.read, stream, length, { timeout = 30 })
    if ok and body and #body >= length then
      return body:sub(1, length)
    elseif ok and body and not self.proc:running() then
      return nil
    elseif not ok and not self.proc:running() then
      return nil
    end
    -- Timed out or short read while the server is still alive: retry.
  end
end

function Session:read_loop()
  while true do
    local body = self:read_message()
    if not body then break end
    local message = json.decode(body)
    if message then
      self:dispatch(message)
    else
      core.log_quiet("lsp[%s]: invalid JSON", self.server.name)
    end
  end
  self:on_exit()
end

function Session:dispatch(message)
  if message.id ~= nil and message.method == nil then
    local callback = self.pending[message.id]
    self.pending[message.id] = nil
    if callback then callback(message.result, message.error) end
    return
  end

  local method = message.method
  if method == "textDocument/publishDiagnostics" then
    self:on_diagnostics(message.params or {})
  elseif method == "window/showMessage" then
    core.log("%s: %s", self.server.name, (message.params or {}).message or "")
  elseif method == "window/logMessage" then
    if config.plugins.lsp.log_stderr then
      core.log_quiet("%s: %s", self.server.name, (message.params or {}).message or "")
    end
  elseif method == "$/progress" then
    -- ignore
  elseif message.id ~= nil then
    -- Server request we do not implement (workspace/configuration, ...).
    self:send({ jsonrpc = "2.0", id = message.id, result = json.null })
  end
end

function Session:on_diagnostics(params)
  local uri = params.uri
  if not uri then return end
  local file = M.path_from_uri(uri)
  local list = {}

  -- Find the open doc, if any, to convert UTF-16 columns to bytes.
  local doc
  for _, d in ipairs(core.docs) do
    if d.abs_filename == file then doc = d break end
  end

  for _, diagnostic in ipairs(params.diagnostics or {}) do
    local range = diagnostic.range or {}
    local start = range.start or {}
    local line = (start.line or 0) + 1
    local col = (start.character or 0) + 1
    if doc and doc.lines[line] then
      col = M.utf16_to_col(doc_line(doc, line), start.character or 0)
    end
    table.insert(list, {
      file = file,
      line = line,
      col = col,
      severity = SEVERITY[diagnostic.severity] or "info",
      message = diagnostic.message or "",
      source = self.problems_source,
    })
  end

  self.diags[uri] = list

  local all = {}
  for _, items in pairs(self.diags) do
    for _, item in ipairs(items) do table.insert(all, item) end
  end
  set_diagnostics(self.problems_source, all)
  update_status()
end

function Session:open_doc(doc)
  if self.state ~= "ready" or not self:owns(doc) then return end
  local uri = doc_uri(doc)
  if self.open_uris[uri] then return end
  local text = doc_text(doc)
  self.open_uris[uri] = doc
  self.versions[uri] = 1
  self.sent[uri] = text
  self:notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = self:language_id(doc),
      version = 1,
      text = text,
    },
  })
end

function Session:mark_dirty(doc, kind)
  self.dirty[doc] = { time = system.get_time(), kind = kind }
end

function Session:flush_doc(doc)
  if self.state ~= "ready" or not doc.abs_filename then return end
  if not self.dirty[doc] then return end
  self.dirty[doc] = nil

  local uri = doc_uri(doc)
  if not self.open_uris[uri] then self:open_doc(doc) end
  self.versions[uri] = (self.versions[uri] or 1) + 1

  local text = doc_text(doc)
  local changes
  if self.sync_kind == 2 then
    -- Incremental servers need a range expressed against the previous
    -- document state, so use the text we last sent them.
    local end_line, end_char = text_end_position(self.sent[uri] or "")
    changes = { {
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = end_line, character = end_char },
      },
      text = text,
    } }
  else
    changes = { { text = text } }
  end
  self.sent[uri] = text

  self:notify("textDocument/didChange", {
    textDocument = { uri = uri, version = self.versions[uri] },
    contentChanges = changes,
  })
end

function Session:save_doc(doc)
  local uri = doc_uri(doc)
  if not self.open_uris[uri] then return end
  -- Make sure the server has the bytes being saved.
  self:flush_doc(doc)
  self:notify("textDocument/didSave", { textDocument = { uri = uri } })
end

function Session:close_doc(doc)
  local uri = doc_uri(doc)
  if not self.open_uris[uri] then return end
  self.open_uris[uri] = nil
  self.sent[uri] = nil
  self.versions[uri] = nil
  self:notify("textDocument/didClose", { textDocument = { uri = uri } })
end

function Session:tick(now)
  if self.state ~= "ready" then return end
  for doc, info in pairs(self.dirty) do
    if now - info.time >= config.plugins.lsp.change_delay then
      self:flush_doc(doc)
    end
  end
end

function Session:on_exit()
  if self.state == "stopped" then return end
  self.state = "stopped"
  self.dirty = {}
  clear_diagnostics(self.problems_source)
  M.sessions[self.key] = nil
  update_status()
end

function Session:stop()
  if self.state == "stopped" then return end
  self.state = "stopped"
  self.dirty = {}
  clear_diagnostics(self.problems_source)
  if self.proc and self.proc:running() then
    self.proc:kill()
  end
  M.sessions[self.key] = nil
  update_status()
end

-- Session lookup --------------------------------------------------------------

---@param doc core.doc
---@return Session|nil
function M.session_for_doc(doc)
  local server = M.find_server(doc)
  if not server then return end
  local root = M.find_root(doc, server)
  return M.sessions[server.name .. "\0" .. root]
end

---Return the session for a document, starting the server if needed.
---@param doc core.doc
---@param force? boolean start even when `auto_start` is false
---@return Session|nil
function M.get_or_start(doc)
  local server = M.find_server(doc)
  if not server or not doc.abs_filename then return end
  local root = M.find_root(doc, server)
  local key = server.name .. "\0" .. root
  local session = M.sessions[key]
  if session then return session end
  session = Session:new(server, root)
  M.sessions[key] = session
  if not session:start() then return session end
  update_status()
  return session
end

---Run `fn(session)` as soon as the session is ready (or immediately).
local function with_session(doc, fn)
  local session = M.session_for_doc(doc)
  -- Running a command is an explicit request: start the server even when
  -- `auto_start` is disabled.
  if not session then session = M.get_or_start(doc) end
  if not session then
    core.error("lsp: no language server for this file")
    return
  end
  if session.state == "ready" then
    fn(session)
  elseif session.state == "starting" then
    table.insert(session.after_ready, fn)
  else
    core.error("lsp: %s is not running", session.server.name)
  end
end

-- Locations -------------------------------------------------------------------

local function open_location(uri, range)
  local file = M.path_from_uri(uri)
  range = range or {}
  local start = range.start or {}
  return core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(file))
    core.root_view.root_node:update_layout()
    local doc = dv.doc
    local line = common.clamp((start.line or 0) + 1, 1, #doc.lines)
    local col = M.utf16_to_col(doc_line(doc, line), start.character or 0)
    doc:set_selection(line, col)
    dv:scroll_to_line(line, true)
  end)
end

local function normalize_locations(result)
  if not result then return {} end
  if result.uri then return { result } end
  local out = {}
  for _, loc in ipairs(result) do
    if loc.targetUri then
      table.insert(out, {
        uri = loc.targetUri,
        range = loc.targetSelectionRange or loc.targetRange,
      })
    elseif loc.uri then
      table.insert(out, loc)
    end
  end
  return out
end

local function show_location_picker(title, locations)
  local labels, by_label = {}, {}
  for _, loc in ipairs(locations) do
    local file = M.path_from_uri(loc.uri)
    local line = ((loc.range or {}).start or {}).line or 0
    local base = string.format("%s:%d", common.basename(file), line + 1)
    local label, n = base, 2
    while by_label[label] do
      label = string.format("%s (%d)", base, n)
      n = n + 1
    end
    by_label[label] = loc
    table.insert(labels, label)
  end
  core.command_view:enter(title, {
    submit = function(text)
      local loc = by_label[text]
      if not loc then
        local best = common.fuzzy_match(labels, text)[1]
        loc = best and by_label[best]
      end
      if loc then open_location(loc.uri, loc.range) end
    end,
    suggest = function(text) return common.fuzzy_match(labels, text) end,
  })
end

-- Requests used by the commands ------------------------------------------------

local function request_location(doc, method, title)
  with_session(doc, function(session)
    session:flush_doc(doc)
    local line, col = doc:get_selection()
    session:request(method, {
      textDocument = { uri = doc_uri(doc) },
      position = lsp_position(doc, line, col),
      context = { includeDeclaration = true },
    }, function(result, err)
      if err then
        core.error("lsp: %s", err.message or "request failed")
        return
      end
      local locations = normalize_locations(result)
      if #locations == 0 then
        core.log("lsp: nothing found")
      elseif #locations == 1 then
        open_location(locations[1].uri, locations[1].range)
      else
        show_location_picker(title, locations)
      end
    end)
  end)
end

---Go to the definition of the symbol under the cursor (F12).
function M.goto_definition()
  local dv = active_doc_view()
  if dv then request_location(dv.doc, "textDocument/definition", "Definitions") end
end

---List the references to the symbol under the cursor (Shift+F12).
function M.references()
  local dv = active_doc_view()
  if not dv then return end
  with_session(dv.doc, function(session)
    session:flush_doc(dv.doc)
    local line, col = dv.doc:get_selection()
    session:request("textDocument/references", {
      textDocument = { uri = doc_uri(dv.doc) },
      position = lsp_position(dv.doc, line, col),
      context = { includeDeclaration = true },
    }, function(result, err)
      if err then
        core.error("lsp: %s", err.message or "request failed")
        return
      end
      local locations = normalize_locations(result)
      if #locations == 0 then
        core.log("lsp: no references")
        return
      end
      if #locations > 300 then
        locations = { table.unpack(locations, 1, 300) }
      end
      show_location_picker("References", locations)
    end)
  end)
end

---Show type/signature information for the symbol under the cursor.
function M.hover()
  local dv = active_doc_view()
  if not dv then return end
  with_session(dv.doc, function(session)
    session:flush_doc(dv.doc)
    local line, col = dv.doc:get_selection()
    session:request("textDocument/hover", {
      textDocument = { uri = doc_uri(dv.doc) },
      position = lsp_position(dv.doc, line, col),
    }, function(result, err)
      if err then
        core.error("lsp: %s", err.message or "request failed")
        return
      end
      local text = result and markup_text(result.contents) or ""
      if text == "" then return end
      show_hover(text)
    end)
  end)
end

local KIND_NAMES = {
  [1] = "text", [2] = "method", [3] = "function", [4] = "constructor",
  [5] = "field", [6] = "variable", [7] = "class", [8] = "interface",
  [9] = "module", [10] = "property", [11] = "unit", [12] = "value",
  [13] = "enum", [14] = "keyword", [15] = "snippet", [16] = "color",
  [17] = "file", [18] = "reference", [19] = "folder", [20] = "enum member",
  [21] = "constant", [22] = "struct", [23] = "event", [24] = "operator",
  [25] = "type parameter",
}

local function documentation_text(doc)
  if type(doc) == "string" then return doc end
  if type(doc) == "table" and doc.value then return tostring(doc.value) end
  return nil
end

local function snippet_to_text(text)
  text = text:gsub("%${%d+:([^}]*)}", "%1")
  text = text:gsub("%${%d+}", "")
  text = text:gsub("%$%d+", "")
  return text
end

local function map_completions(result)
  local list = result.items or result
  local autocomplete_ok, autocomplete = pcall(require, "plugins.autocomplete")
  if not autocomplete_ok then return {} end

  local items, seen = {}, {}
  for _, completion in ipairs(list or {}) do
    -- Prefer the plain insertion text. `textEdit.newText` may be a snippet or
    -- contain text that only makes sense together with its own range.
    local text = completion.insertText
      or (completion.textEdit and completion.textEdit.newText)
      or completion.label
    if text and completion.insertTextFormat == 2 then
      text = snippet_to_text(text)
    end
    if text and text ~= "" and not text:find("[\n\r]") and not seen[text] then
      seen[text] = true
      local item = autocomplete.item(text,
        completion.detail or KIND_NAMES[completion.kind or 0])
      local desc = documentation_text(completion.documentation)
      if desc then
        desc = sanitize_markup(desc)
        if #desc > 400 then desc = desc:sub(1, 400) .. "…" end
        item.desc = desc
      end
      table.insert(items, item)
      if #items >= 200 then break end
    end
  end
  return items
end

---Trigger LSP completion for the current position (Ctrl+Space).
function M.complete()
  local dv = active_doc_view()
  if not dv then return end
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if ok then autocomplete.open() end
end

---List the symbols of the current document (Ctrl+Alt+O).
function M.symbols()
  local dv = active_doc_view()
  if not dv then return end
  with_session(dv.doc, function(session)
    session:flush_doc(dv.doc)
    session:request("textDocument/documentSymbol", {
      textDocument = { uri = doc_uri(dv.doc) },
    }, function(result, err)
      if err or not result then return end

      local symbols = {}
      local function add(name, uri, range, depth)
        table.insert(symbols, {
          label = string.rep("  ", depth or 0) .. name,
          uri = uri,
          range = range,
        })
      end
      local function walk(list, depth)
        for _, symbol in ipairs(list) do
          if symbol.location then -- SymbolInformation
            add(symbol.name, symbol.location.uri, symbol.location.range, 0)
          else -- DocumentSymbol
            add(symbol.name, doc_uri(dv.doc), symbol.selectionRange or symbol.range, depth)
            if symbol.children then walk(symbol.children, depth + 1) end
          end
        end
      end
      walk(result, 0)

      if #symbols == 0 then
        core.log("lsp: no symbols")
        return
      end

      local labels, by_label = {}, {}
      for _, symbol in ipairs(symbols) do
        local label, n = symbol.label, 2
        while by_label[label] do
          label = string.format("%s (%d)", symbol.label, n)
          n = n + 1
        end
        by_label[label] = symbol
        table.insert(labels, label)
      end
      core.command_view:enter("Go to Symbol", {
        submit = function(text)
          local symbol = by_label[text]
          if not symbol then
            local best = common.fuzzy_match(labels, text)[1]
            symbol = best and by_label[best]
          end
          if symbol then open_location(symbol.uri, symbol.range) end
        end,
        suggest = function(text) return common.fuzzy_match(labels, text) end,
      })
    end)
  end)
end

-- Edits ----------------------------------------------------------------------

---Replace the whole content of a document, preserving Lite XL's invariant that
---every line ends with a newline.
local function replace_document(doc, text)
  text = (text or ""):gsub("\n$", "")
  doc:remove(1, 1, math.huge, math.huge)
  doc:insert(1, 1, text)
end

---True when an LSP range covers the whole document.
local function is_full_range(doc, range)
  local start = range.start or {}
  local finish = range["end"] or {}
  if (start.line or 0) ~= 0 or (start.character or 0) ~= 0 then return false end
  local end_line, end_char = text_end_position(doc_text(doc))
  local line = finish.line or 0
  local character = finish.character or 0
  return line > end_line or (line == end_line and character >= end_char)
end

local function apply_edits(doc, edits)
  if not edits or #edits == 0 then return false end
  if #edits == 1 and edits[1].range and is_full_range(doc, edits[1].range) then
    replace_document(doc, edits[1].newText or "")
    return true
  end

  local sorted = {}
  for _, edit in ipairs(edits) do table.insert(sorted, edit) end
  table.sort(sorted, function(a, b)
    local as, bs = a.range.start, b.range.start
    if as.line ~= bs.line then return as.line > bs.line end
    if as.character ~= bs.character then return as.character > bs.character end
    return (a.range["end"].line or 0) > (b.range["end"].line or 0)
  end)

  for _, edit in ipairs(sorted) do
    local range = edit.range
    local line1 = (range.start.line or 0) + 1
    local col1 = M.utf16_to_col(doc_line(doc, line1), range.start.character or 0)
    local line2 = (range["end"].line or 0) + 1
    local col2 = M.utf16_to_col(doc_line(doc, line2), range["end"].character or 0)
    doc:remove(line1, col1, line2, col2)
    if edit.newText ~= "" then doc:insert(line1, col1, edit.newText) end
  end
  return true
end

---Format the current document through the server (Alt+Shift+F).
function M.format()
  local dv = active_doc_view()
  if not dv then return end
  local doc = dv.doc
  with_session(doc, function(session)
    session:flush_doc(doc)
    local indent_type, indent_size = doc:get_indent_info()
    session:request("textDocument/formatting", {
      textDocument = { uri = doc_uri(doc) },
      options = {
        tabSize = indent_size,
        insertSpaces = indent_type == "soft",
      },
    }, function(result, err)
      if err then
        core.error("lsp: %s", err.message or "format failed")
        return
      end
      if not result or #result == 0 then
        core.log("lsp: nothing to format")
        return
      end
      apply_edits(doc, result)
      core.log("lsp: formatted")
    end)
  end)
end

local function apply_workspace_edit(edit)
  local changes = edit.changes
  if not changes and edit.documentChanges then
    changes = {}
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument and change.edits then
        changes[change.textDocument.uri] = change.edits
      end
    end
  end

  local count = 0
  for uri, edits in pairs(changes or {}) do
    local file = M.path_from_uri(uri)
    local was_open = false
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename == file then was_open = true break end
    end
    local doc = core.open_doc(file)
    if apply_edits(doc, edits) then
      count = count + 1
      if not was_open then doc:save() end
    end
  end
  return count
end

---Rename the symbol under the cursor (F2).
function M.rename()
  local dv = active_doc_view()
  if not dv then return end
  local doc = dv.doc
  local line, col = doc:get_selection()
  local line_text = doc_line(doc, line)
  local word = line_text:sub(1, col):match("([%w_]+)$") or ""

  core.command_view:enter("Rename Symbol", {
    text = word,
    submit = function(new_name)
      if new_name == "" or new_name:match("%s") then
        core.error("lsp: invalid name")
        return
      end
      with_session(doc, function(session)
        session:flush_doc(doc)
        session:request("textDocument/rename", {
          textDocument = { uri = doc_uri(doc) },
          position = lsp_position(doc, line, col),
          newName = new_name,
        }, function(result, err)
          if err then
            core.error("lsp: %s", err.message or "rename failed")
            return
          end
          if not result then return end
          local n = apply_workspace_edit(result)
          core.log("lsp: renamed in %d file(s)", n)
        end)
      end)
    end,
  })
end

-- Commands -------------------------------------------------------------------

---Start the server for the active document (or all open documents).
function M.start()
  local dv = active_doc_view()
  if dv then
    local session = M.get_or_start(dv.doc)
    if session and session.state == "ready" then session:open_doc(dv.doc) end
    return
  end
  for _, doc in ipairs(core.docs) do M.get_or_start(doc) end
end

---Stop every running server.
function M.stop()
  for _, session in pairs(M.sessions) do
    session:stop()
  end
  M.sessions = {}
  update_status()
end

---Restart the server(s) for the active document.
function M.restart()
  M.stop()
  local dv = active_doc_view()
  if dv then M.get_or_start(dv.doc) end
end

command.add(nil, {
  ["lsp:start"] = function() M.start() end,
  ["lsp:stop"] = function() M.stop() end,
  ["lsp:restart"] = function() M.restart() end,
  ["lsp:definition"] = function() M.goto_definition() end,
  ["lsp:references"] = function() M.references() end,
  ["lsp:hover"] = function() M.hover() end,
  ["lsp:hover-hide"] = function() hide_hover() end,
  ["lsp:complete"] = function() M.complete() end,
  ["lsp:symbols"] = function() M.symbols() end,
  ["lsp:format"] = function() M.format() end,
  ["lsp:rename"] = function() M.rename() end,
})

keymap.add {
  ["f12"] = "lsp:definition",
  ["shift+f12"] = "lsp:references",
  ["ctrl+shift+h"] = "lsp:hover",
  ["ctrl+space"] = "lsp:complete",
  ["ctrl+alt+o"] = "lsp:symbols",
  ["alt+shift+f"] = "lsp:format",
  ["f2"] = "lsp:rename",
}

-- Status bar -----------------------------------------------------------------

local status_item

local function session_for_status()
  local dv = active_doc_view()
  if dv then
    local session = M.session_for_doc(dv.doc)
    if session then return session end
  end
  for _, session in pairs(M.sessions) do return session end
end

function update_status()
  if not status_item then return end
  local session = session_for_status()
  if not session then
    status_item:hide()
    core.redraw = true
    return
  end
  status_item:show()
  core.redraw = true
end

local function count_errors(session)
  local n = 0
  for _, items in pairs(session.diags) do
    for _, item in ipairs(items) do
      if item.severity == "error" then n = n + 1 end
    end
  end
  return n
end

if core.status_view then
  local StatusView = require "core.statusview"
  status_item = core.status_view:add_item({
    name = "lsp:status",
    alignment = StatusView.Item.RIGHT,
    tooltip = "Language server — click to show the problems",
    visible = false,
    get_item = function()
      local session = session_for_status()
      if not session then return {} end
      local name = session.server.name
      if session.state == "starting" then
        return { style.dim, "lsp: " .. name .. "…" }
      elseif session.state == "error" then
        return { style.warn, "lsp: " .. name .. " failed" }
      elseif session.state == "stopped" then
        return { style.dim, "lsp: " .. name .. " stopped" }
      end
      local errors = count_errors(session)
      if errors > 0 then
        return { style.warn, string.format("lsp: %s (%d)", name, errors) }
      end
      return { style.accent, "lsp: " .. name }
    end,
    command = function(button)
      if button == "left" then
        local registry = get_problems()
        if registry then registry.view:show() end
      end
    end,
  })
end

-- Document hooks -------------------------------------------------------------

local function session_for_doc_if_active(doc)
  if not config.plugins.lsp.auto_start then
    local session = M.session_for_doc(doc)
    if session then return session end
    return
  end
  return M.get_or_start(doc)
end

---Called when a document is opened.
function M.on_open(doc)
  if not doc.abs_filename then return end
  local session = session_for_doc_if_active(doc)
  if session and session.state == "ready" then
    session:open_doc(doc)
  end
end

---Called after every document edit.
function M.on_text_change(doc, kind)
  hide_hover()
  if not doc.abs_filename then return end
  local session = M.session_for_doc(doc)
  if session and session.state == "ready" and session:owns(doc) then
    session:mark_dirty(doc, kind)
  end
end

---Called after a document is saved.
function M.on_save(doc)
  local session = M.session_for_doc(doc)
  if session and session.state == "ready" then session:save_doc(doc) end
end

---Called when a document is closed.
function M.on_close(doc)
  local session = M.session_for_doc(doc)
  if session then
    session:close_doc(doc)
    session.dirty[doc] = nil
  end
end

local base_open_doc = RootView.open_doc
function RootView:open_doc(doc, ...)
  local view = base_open_doc(self, doc, ...)
  if view and doc then M.on_open(doc) end
  return view
end

local base_text_change = Doc.on_text_change
function Doc:on_text_change(kind)
  base_text_change(self, kind)
  M.on_text_change(self, kind)
end

local base_save = Doc.save
function Doc:save(...)
  local result = table.pack(base_save(self, ...))
  M.on_save(self)
  return table.unpack(result, 1, result.n)
end

local base_close = Doc.on_close
function Doc:on_close()
  base_close(self)
  M.on_close(self)
end

---Ask the server for completions at the cursor.
---@param doc core.doc
---@param callback fun(items: table[], result: any)
---@return boolean started
function M.completions(doc, callback)
  local session = M.session_for_doc(doc)
  if not session or session.state ~= "ready" then return false end
  session:flush_doc(doc)
  local line, col = doc:get_selection()
  session:request("textDocument/completion", {
    textDocument = { uri = doc_uri(doc) },
    position = lsp_position(doc, line, col),
    context = { triggerKind = 1 },
  }, function(result, err)
    if err or not result then return end
    callback(map_completions(result), result)
  end)
  return true
end

-- Autocomplete provider ------------------------------------------------------

do
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if ok and autocomplete.add_provider then
    autocomplete.add_provider(function(doc, partial, generation)
      if not config.plugins.lsp.auto_complete then return end
      M.completions(doc, function(items)
        local av = active_doc_view()
        if not av or av.doc ~= doc then return end
        autocomplete.provide("lsp", generation, items, doc)
      end)
    end)
  end
end

-- Background tick ------------------------------------------------------------

core.add_thread(function()
  while true do
    local now = system.get_time()
    for _, session in pairs(M.sessions) do
      session:tick(now)
    end
    coroutine.yield(0.1)
  end
end)

-- Start servers for files already open when the plugin loads.
if config.plugins.lsp.auto_start then
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename and M.find_server(doc) then
      M.get_or_start(doc)
    end
  end
end

return M
