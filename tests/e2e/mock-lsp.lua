-- Minimal LSP server used by the e2e suite.
--
-- Speaks the same stdio framing the real client uses, but answers with fixed
-- data so the tests can assert diagnostics, completion, hover, navigation,
-- rename and formatting without depending on clangd.
--
-- Environment:
--   E2E_LSP_JSON  path to the client's json.lua (shared implementation)
--   E2E_LSP_LOG   optional file receiving one line per received method

local json_path = os.getenv("E2E_LSP_JSON")
assert(json_path, "E2E_LSP_JSON is not set")
local json = assert(loadfile(json_path))()

local log_path = os.getenv("E2E_LSP_LOG")
local function log(line)
  if not log_path then return end
  local fp = io.open(log_path, "a")
  if fp then
    fp:write(line .. "\n")
    fp:close()
  end
end

io.stdout:setvbuf("no")

local docs = {}

local function send(message)
  local body = json.encode(message)
  io.write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
  io.flush()
end

local function read_message()
  local length
  while true do
    local line = io.read("l")
    if not line then return nil end
    line = line:gsub("\r$", "")
    if line == "" then break end
    local n = line:match("^Content%-Length:%s*(%d+)")
    if n then length = tonumber(n) end
  end
  if not length then return nil end
  local body = io.read(length)
  if not body then return nil end
  return json.decode(body)
end

local function split_lines(text)
  local lines, start = {}, 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = text:sub(start)
      return lines
    end
    lines[#lines + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
end

local function byte_offset(lines, pos)
  local offset = 0
  for i = 1, pos.line do
    offset = offset + #(lines[i] or "") + 1
  end
  return offset + (pos.character or 0)
end

local function document_end(text)
  local lines = split_lines(text)
  return { line = #lines - 1, character = #lines[#lines] }
end

local function publish_diagnostics(uri)
  local text = docs[uri] or ""
  local diagnostics, line = {}, 0
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local col = raw:find("boom", 1, true)
    if col then
      diagnostics[#diagnostics + 1] = {
        range = {
          start = { line = line, character = col - 1 },
          ["end"] = { line = line, character = col - 1 + 4 },
        },
        severity = 1,
        source = "mock",
        message = "boom is not allowed here",
      }
    end
    line = line + 1
  end
  send {
    jsonrpc = "2.0",
    method = "textDocument/publishDiagnostics",
    params = { uri = uri, diagnostics = diagnostics },
  }
end

local handlers = {}

handlers["initialize"] = function(message)
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      capabilities = {
        textDocumentSync = { openClose = true, change = 2, save = { includeText = false } },
        completionProvider = { triggerCharacters = { "." } },
        hoverProvider = true,
        definitionProvider = true,
        referencesProvider = true,
        documentSymbolProvider = true,
        documentFormattingProvider = true,
        renameProvider = true,
      },
      serverInfo = { name = "mock-lsp", version = "1.0" },
    },
  }
end

handlers["initialized"] = function() end

handlers["shutdown"] = function(message)
  send { jsonrpc = "2.0", id = message.id, result = json.null }
end

handlers["exit"] = function()
  os.exit(0)
end

handlers["textDocument/didOpen"] = function(message)
  local td = message.params.textDocument
  docs[td.uri] = td.text
  log("didOpen " .. td.uri)
  publish_diagnostics(td.uri)
end

handlers["textDocument/didChange"] = function(message)
  local td = message.params.textDocument
  local text = docs[td.uri] or ""
  for _, change in ipairs(message.params.contentChanges or {}) do
    if change.range then
      local lines = split_lines(text)
      local from = byte_offset(lines, change.range.start)
      local to = byte_offset(lines, change.range["end"])
      text = text:sub(1, from) .. change.text .. text:sub(to + 1)
    else
      text = change.text
    end
  end
  docs[td.uri] = text
  log("didChange " .. td.uri .. " version=" .. tostring(td.version))
  publish_diagnostics(td.uri)
end

handlers["textDocument/didSave"] = function(message)
  log("didSave " .. message.params.textDocument.uri)
end

handlers["textDocument/didClose"] = function(message)
  local uri = message.params.textDocument.uri
  docs[uri] = nil
  log("didClose " .. uri)
end

handlers["textDocument/completion"] = function(message)
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      isIncomplete = false,
      items = {
        { label = "mock_alpha", kind = 3, detail = "mock function", insertText = "mock_alpha" },
        { label = "mock_beta", kind = 6, detail = "mock variable", insertText = "mock_beta" },
        { label = "foo", kind = 3, detail = "the sample function", insertText = "foo" },
      },
    },
  }
end

handlers["textDocument/hover"] = function(message)
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = { contents = { kind = "markdown", value = "**mock hover** `int foo(void)`" } },
  }
end

handlers["textDocument/definition"] = function(message)
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      uri = message.params.textDocument.uri,
      range = {
        start = { line = 2, character = 2 },
        ["end"] = { line = 2, character = 6 },
      },
    },
  }
end

handlers["textDocument/references"] = function(message)
  local uri = message.params.textDocument.uri
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      { uri = uri, range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 7 } } },
      { uri = uri, range = { start = { line = 2, character = 9 }, ["end"] = { line = 2, character = 12 } } },
    },
  }
end

handlers["textDocument/documentSymbol"] = function(message)
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      {
        name = "mock_symbol",
        kind = 12,
        range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 10 } },
        selectionRange = { start = { line = 1, character = 2 }, ["end"] = { line = 1, character = 6 } },
      },
    },
  }
end

handlers["textDocument/formatting"] = function(message)
  local uri = message.params.textDocument.uri
  local text = docs[uri] or ""
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      {
        range = { start = { line = 0, character = 0 }, ["end"] = document_end(text) },
        newText = "// formatted\nint foo(void) { return 0; }\n",
      },
    },
  }
end

handlers["textDocument/rename"] = function(message)
  local uri = message.params.textDocument.uri
  send {
    jsonrpc = "2.0",
    id = message.id,
    result = {
      changes = {
        [uri] = {
          {
            range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 7 } },
            newText = message.params.newName,
          },
        },
      },
    },
  }
end

while true do
  local message = read_message()
  if not message then break end
  if message.method then log(message.method) end
  local handler = message.method and handlers[message.method]
  if handler then
    handler(message)
  elseif message.id ~= nil then
    send { jsonrpc = "2.0", id = message.id, result = json.null }
  end
end
