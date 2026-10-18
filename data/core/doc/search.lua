local search = {}

local default_opt = {}


local function pattern_lower(str)
  if str:sub(1, 1) == "%" then
    return str
  end
  return str:lower()
end


local function init_args(doc, line, col, text, opt)
  opt = opt or default_opt
  line, col = doc:sanitize_position(line, col)

  if opt.no_case and not opt.regex then
    text = text:lower()
  end

  return doc, line, col, text, opt
end

-- This function is needed to uniform the behavior of
-- `regex:cmatch` and `string.find`.
local function regex_func(text, re, index, _)
  local s, e = re:cmatch(text, index)
  return s, e and e - 1
end

local function rfind(func, text, pattern, index, plain)
  local s, e = func(text, pattern, 1, plain)
  local last_s, last_e
  if index < 0 then index = #text - index + 1 end
  while e and e <= index do
    last_s, last_e = s, e
    s, e = func(text, pattern, s + 1, plain)
  end
  return last_s, last_e
end


---@param c string?
---@return boolean
function search.is_word_char(c)
  return c ~= nil and c ~= "" and c:match("[%w_]") ~= nil
end


---Checks if the match at byte offsets `s, e` (inclusive) sits on word
---boundaries. `line_text` must be the original (non-lowercased) line since
---only ASCII word characters matter, but indices must match the searched text.
---@param line_text string
---@param s integer
---@param e integer
---@return boolean
function search.has_word_boundary(line_text, s, e)
  if not s then return false end
  -- Zero-width regex matches (e < s) always count as a boundary hit;
  -- they carry no word characters themselves.
  if e < s then return true end
  local before = s > 1 and line_text:sub(s - 1, s - 1) or nil
  local after = e < #line_text and line_text:sub(e + 1, e + 1) or nil
  -- A trailing newline is a non-word character, so a match ending at
  -- the newline (e == #line_text) trivially satisfies the end boundary.
  if before and search.is_word_char(before) then return false end
  if after and search.is_word_char(after) then return false end
  return true
end


local function compile_pattern(text, opt)
  local plain = not opt.pattern
  local pattern = text
  local search_func = string.find
  if opt.regex then
    local re, err = regex.compile(text, opt.no_case and "i" or "")
    if not re then return nil, nil, plain, err end
    pattern = re
    search_func = regex_func
  end
  return pattern, search_func, plain, nil
end


function search.find(doc, line, col, text, opt)
  doc, line, col, text, opt = init_args(doc, line, col, text, opt)
  if text == "" then return end
  local pattern, search_func, plain, err = compile_pattern(text, opt)
  if err then return end
  local whole_word = opt.whole_word
  local start, finish, step = line, #doc.lines, 1
  if opt.reverse then
    start, finish, step = line, 1, -1
  end
  for line = start, finish, step do
    local line_text = doc.lines[line]
    local searched_text = line_text
    if opt.no_case and not opt.regex then
      searched_text = line_text:lower()
    end
    if opt.reverse then
      local idx = col - 1
      while true do
        local s, e = rfind(search_func, searched_text, pattern, idx, plain)
        if not s then break end
        if not whole_word or search.has_word_boundary(line_text, s, e) then
          local line2 = line
          -- If we've matched the newline too,
          -- return until the initial character of the next line.
          if e >= #doc.lines[line] then
            line2 = line + 1
            e = 0
          end
          -- Avoid returning matches that go beyond the last line.
          -- This is needed to avoid selecting the "last" newline.
          if line2 <= #doc.lines then
            return line, s, line2, e + 1
          end
          break
        end
        idx = s - 1
        if idx < 1 then break end
      end
    else
      local from = col
      while true do
        local s, e = search_func(searched_text, pattern, from, plain)
        if not s then break end
        if not whole_word or search.has_word_boundary(line_text, s, e) then
          local line2 = line
          -- If we've matched the newline too,
          -- return until the initial character of the next line.
          if e >= #doc.lines[line] then
            line2 = line + 1
            e = 0
          end
          -- Avoid returning matches that go beyond the last line.
          -- This is needed to avoid selecting the "last" newline.
          if line2 <= #doc.lines then
            return line, s, line2, e + 1
          end
          break
        end
        from = s + 1
        if from > #searched_text + 1 then break end
      end
    end
    col = opt.reverse and -1 or 1
  end

  if opt.wrap then
    opt = {
      no_case = opt.no_case,
      regex = opt.regex,
      pattern = opt.pattern,
      reverse = opt.reverse,
      whole_word = opt.whole_word,
    }
    if opt.reverse then
      return search.find(doc, #doc.lines, #doc.lines[#doc.lines], text, opt)
    else
      return search.find(doc, 1, 1, text, opt)
    end
  end
end


---Finds every match of `text` in `doc`.
---@param doc core.doc
---@param text string
---@param opt? table supports `no_case`, `regex`, `pattern`, `whole_word`
---@return table matches list of `{line=integer,col=integer,line2=integer,col2=integer}`
function search.find_all(doc, text, opt)
  opt = opt or default_opt
  if text == "" then return {} end
  local results = {}
  local o = {
    wrap = false,
    no_case = opt.no_case,
    regex = opt.regex,
    pattern = opt.pattern,
    whole_word = opt.whole_word,
  }
  local line, col = 1, 1
  local guard = 0
  while true do
    local l1, c1, l2, c2 = search.find(doc, line, col, text, o)
    if not l1 then break end
    table.insert(results, { line = l1, col = c1, line2 = l2, col2 = c2 })
    line, col = l2, c2
    -- Guard against zero-width matches (e.g. regex `x*?`) looping forever.
    if line == l1 and col <= c1 then col = c1 + 1 end
    if line > #doc.lines then break end
    local llen = #doc.lines[line]
    if col > llen + 1 then
      line, col = line + 1, 1
      if line > #doc.lines then break end
    end
    guard = guard + 1
    if guard > 1000000 then break end
  end
  return results
end


---Finds every match of `text` inside a single raw line of text.
---Used for project-wide search where files are read line by line instead
---of being opened as documents.
---@param line_text string raw line, newline stripped or not (indices still work)
---@param text string
---@param opt? table supports `no_case`, `regex`, `whole_word`
---@return table matches list of `{s=integer,e=integer}` with inclusive byte offsets
function search.find_all_in_line(line_text, text, opt)
  opt = opt or default_opt
  if text == "" or not line_text then return {} end
  local searched_text = line_text
  local pattern_text = text
  if opt.no_case and not opt.regex then
    searched_text = line_text:lower()
    pattern_text = text:lower()
  end
  local plain = not opt.pattern
  local pattern = pattern_text
  local search_func = string.find
  if opt.regex then
    local re, err = regex.compile(text, opt.no_case and "i" or "")
    if not re then return {} end
    pattern = re
    search_func = regex_func
  end
  local results = {}
  local from = 1
  local guard = 0
  while from <= #searched_text + 1 do
    local s, e
    if opt.regex then
      s, e = search_func(searched_text, pattern, from)
    else
      s, e = string.find(searched_text, pattern_text, from, plain)
    end
    if not s then break end
    if not opt.whole_word or search.has_word_boundary(line_text, s, e) then
      table.insert(results, { s = s, e = e })
    end
    local next_from = (e or s) + 1
    if next_from <= from then next_from = from + 1 end
    from = next_from
    guard = guard + 1
    if guard > 100000 then break end
  end
  return results
end


return search
