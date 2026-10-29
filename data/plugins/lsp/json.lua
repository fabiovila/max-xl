-- Minimal JSON (RFC 8259) implementation used by the LSP client.
--
-- The editor ships no JSON library and the LSP wire format needs both
-- directions, so this module keeps a small, dependency-free parser/encoder.
-- It handles the whole spec: nested structures, escapes, \uXXXX (including
-- surrogate pairs), numbers, booleans and null.
--
-- Usage:
--   local json = require "plugins.lsp.json"
--   local t = json.decode('{"a":[1,2]}')
--   local s = json.encode({ a = { 1, 2 } })
--
-- Empty tables encode as `{}`; wrap them in `json.array()` to force `[]`.

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MT = {}
---Mark a table as a JSON array (needed for empty arrays).
---@param t? table
---@return table
function json.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

local ESCAPES = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

-- Decoder --------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

local function parser_new(text)
  return setmetatable({ s = text, i = 1, n = #text }, Parser)
end

function Parser:skip_ws()
  local i = self.s:find("[^ \t\r\n]", self.i)
  self.i = i or (self.n + 1)
end

function Parser:peek()
  return self.s:sub(self.i, self.i)
end

function Parser:literal(word)
  if self.s:sub(self.i, self.i + #word - 1) ~= word then
    error("invalid literal at " .. self.i)
  end
  self.i = self.i + #word
end

function Parser:string()
  -- self.i points at the opening quote
  self.i = self.i + 1
  local buf = {}
  while true do
    local j = self.s:find('["\\]', self.i)
    if not j then error("unterminated string") end
    table.insert(buf, self.s:sub(self.i, j - 1))
    if self.s:sub(j, j) == '"' then
      self.i = j + 1
      return table.concat(buf)
    end

    local e = self.s:sub(j + 1, j + 1)
    if e == "u" then
      local hex = self.s:sub(j + 2, j + 5)
      local code = tonumber(hex, 16)
      if not code then error("invalid \\u escape") end
      local nextpos = j + 6
      -- surrogate pair
      if code >= 0xD800 and code <= 0xDBFF then
        local low = self.s:match("^\\u(%x%x%x%x)", nextpos)
        local low_code = low and tonumber(low, 16)
        if low_code and low_code >= 0xDC00 and low_code <= 0xDFFF then
          code = 0x10000 + (code - 0xD800) * 0x400 + (low_code - 0xDC00)
          nextpos = nextpos + 6
        end
      end
      table.insert(buf, utf8.char(code))
      self.i = nextpos
    else
      local ch = ESCAPES[e]
      if not ch then error("invalid escape \\" .. e) end
      table.insert(buf, ch)
      self.i = j + 2
    end
  end
end

function Parser:number()
  local num = self.s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", self.i)
  if not num or num == "" then error("invalid number at " .. self.i) end
  self.i = self.i + #num
  local value = tonumber(num)
  if value == nil then error("invalid number '" .. num .. "'") end
  return value
end

function Parser:array()
  local arr = {}
  self.i = self.i + 1
  self:skip_ws()
  if self:peek() == "]" then
    self.i = self.i + 1
    return arr
  end
  while true do
    table.insert(arr, self:value())
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "]" then
      self.i = self.i + 1
      return arr
    else
      error("expected ',' or ']' at " .. self.i)
    end
  end
end

function Parser:object()
  local obj = {}
  self.i = self.i + 1
  self:skip_ws()
  if self:peek() == "}" then
    self.i = self.i + 1
    return obj
  end
  while true do
    self:skip_ws()
    if self:peek() ~= '"' then error("expected object key at " .. self.i) end
    local key = self:string()
    self:skip_ws()
    if self:peek() ~= ":" then error("expected ':' at " .. self.i) end
    self.i = self.i + 1
    obj[key] = self:value()
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "}" then
      self.i = self.i + 1
      return obj
    else
      error("expected ',' or '}' at " .. self.i)
    end
  end
end

function Parser:value()
  self:skip_ws()
  local c = self:peek()
  if c == "{" then return self:object() end
  if c == "[" then return self:array() end
  if c == '"' then return self:string() end
  if c == "t" then self:literal("true") return true end
  if c == "f" then self:literal("false") return false end
  if c == "n" then self:literal("null") return json.null end
  if c == "-" or c:match("%d") then return self:number() end
  error("unexpected character at " .. self.i)
end

---Decode a JSON string.
---@param text string
---@return any|nil value
---@return string|nil error
function json.decode(text)
  if type(text) ~= "string" then return nil, "expected a string" end
  local ok, result = pcall(function()
    local parser = parser_new(text)
    local value = parser:value()
    parser:skip_ws()
    if parser.i <= parser.n then error("trailing data at " .. parser.i) end
    return value
  end)
  if not ok then return nil, tostring(result) end
  return result
end

-- Encoder --------------------------------------------------------------------

local ENCODE_ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(str)
  return '"' .. str:gsub('[%z\1-\31\\"]', function(c)
    return ENCODE_ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  if getmetatable(t) == ARRAY_MT then return true end
  local n = #t
  if n == 0 then return false end
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    count = count + 1
  end
  return count == n
end

local function encode_value(value, out)
  local t = type(value)
  if value == json.null then
    table.insert(out, "null")
  elseif t == "nil" then
    table.insert(out, "null")
  elseif t == "boolean" then
    table.insert(out, value and "true" or "false")
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      table.insert(out, "null")
    elseif math.type(value) == "integer" then
      table.insert(out, tostring(value))
    else
      table.insert(out, string.format("%.14g", value))
    end
  elseif t == "string" then
    table.insert(out, encode_string(value))
  elseif t == "table" then
    if is_array(value) then
      table.insert(out, "[")
      for i = 1, #value do
        if i > 1 then table.insert(out, ",") end
        encode_value(value[i], out)
      end
      table.insert(out, "]")
    else
      local keys = {}
      for k in pairs(value) do
        if type(k) == "string" then table.insert(keys, k) end
      end
      table.sort(keys)
      table.insert(out, "{")
      for i, key in ipairs(keys) do
        if i > 1 then table.insert(out, ",") end
        table.insert(out, encode_string(key))
        table.insert(out, ":")
        encode_value(value[key], out)
      end
      table.insert(out, "}")
    end
  else
    error("cannot encode a " .. t)
  end
end

---Encode a Lua value as JSON.
---@param value any
---@return string
function json.encode(value)
  local out = {}
  encode_value(value, out)
  return table.concat(out)
end

return json
