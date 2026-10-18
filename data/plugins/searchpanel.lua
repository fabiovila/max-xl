-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local Doc = require "core.doc"
local DocView = require "core.docview"
local search = require "core.doc.search"
local translate = require "core.doc.translate"

config.plugins.searchpanel = common.merge({
  size = 240 * SCALE,
  visible = false,
  max_results = 5000,
}, config.plugins.searchpanel)

---@class plugins.searchpanel : core.view
local SearchPanel = View:extend()

local function field_text(doc)
  return doc:get_text(1, 1, #doc.lines, math.huge)
end

local function field_set_text(doc, text, select_all)
  doc:remove(1, 1, math.huge, math.huge)
  if text ~= "" then doc:text_input(text) end
  if select_all then
    doc:set_selection(1, 1, #doc.lines, math.huge)
  else
    doc:set_selection(#doc.lines, math.huge)
  end
end

local function insert_unique(t, v)
  for i = 1, #t do
    if t[i] == v then table.remove(t, i) break end
  end
  table.insert(t, 1, v)
end

local function trim_preview(s, max_len)
  max_len = max_len or 200
  s = s:gsub("\n", " "):gsub("%s+", " ")
  if #s > max_len then s = s:sub(1, max_len) .. "…" end
  return s
end

-- Theme support: colors resolve through `style.panel_theme()`
-- (see data/core/style.lua), so `style.search = {...}` rebrands this
-- panel. Every key falls back to a core color.

---@class plugins.searchpanel : core.view
local SearchPanel = View:extend()

function SearchPanel:__tostring() return "SearchPanel" end

function SearchPanel:new()
  SearchPanel.super.new(self)
  self.scrollable = false
  self.visible = config.plugins.searchpanel.visible
  self.init_size = true
  self.target_size = config.plugins.searchpanel.size
  self.find_doc = Doc()
  self.replace_doc = Doc()
  self.font = style.font:copy(13 * SCALE)
  self.focus = "find"
  self.case_sensitive = false
  self.whole_word = false
  self.use_regex = false
  self.scope = "file" -- "file" | "open" | "project"
  self.results = {}
  self.selected = 0
  self.hovered = 0
  self.hovered_control = nil
  self.status = "Type to search"
  self.status_kind = "idle" -- idle | info | active | warn (set via set_status)
  self.searching = false
  self.search_token = 0
  self.files_scanned = 0
  self.target_view = nil
  self.target_doc = nil
  self.results_scroll = 0
  self.find_scroll = { x = 0, y = 0 }
  self.replace_scroll = { x = 0, y = 0 }
  self.dirty = false
  self.last_edit = 0
  self.results_key = nil
  self.R = {}
end

function SearchPanel:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function SearchPanel:get_name() return "Search" end
function SearchPanel:supports_text_input() return true end

function SearchPanel:on_scale_change(new_scale)
  self.font = style.font:copy(13 * new_scale)
end

---Returns the resolved theme colors (core colors merged with
---`style.search` overrides). Useful for theme authors and tests.
function SearchPanel:get_theme() return style.panel_theme() end

function SearchPanel:get_opts()
  return {
    wrap = true,
    no_case = not self.case_sensitive,
    regex = self.use_regex,
    whole_word = self.whole_word,
  }
end

function SearchPanel:get_find_text() return field_text(self.find_doc) end
function SearchPanel:get_replace_text() return field_text(self.replace_doc) end

---@param msg string
---@param kind? string "idle" | "info" | "active" | "warn"
function SearchPanel:set_status(msg, kind)
  self.status = msg
  self.status_kind = kind or "idle"
  core.redraw = true
end

local function status_color(panel)
  local C = panel.C or style.panel_theme()
  if panel.status_kind == "info" then return C.text end
  if panel.status_kind == "active" then return C.accent end
  if panel.status_kind == "warn" then return C.warn end
  return C.dim
end

function SearchPanel:validate_regex()
  if not self.use_regex then return true end
  local text = self:get_find_text()
  if text == "" then return true end
  local ok, re = pcall(regex.compile, text, self.case_sensitive and "" or "i")
  if not ok or not re then
    self:set_status("Invalid regex", "warn")
    return false
  end
  return true
end

function SearchPanel:get_target_docview()
  if self.target_view and self.target_view.doc then
    local ok = false
    for _, doc in ipairs(core.docs) do
      if doc == self.target_view.doc then ok = true break end
    end
    if ok then return self.target_view end
  end
  local av = core.active_view
  if av and av:is(DocView) then return av end
  if core.last_active_view and core.last_active_view:is(DocView) then
    return core.last_active_view
  end
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(DocView) then return view end
  end
end

function SearchPanel:remember_target(view)
  if view and view:is(DocView) then
    self.target_view = view
    self.target_doc = view.doc
  end
end

function SearchPanel:prefill_from_selection(select_all)
  local av = core.active_view
  if av and av:is(DocView) and av.doc then
    self:remember_target(av)
    local text = av.doc:get_text(av.doc:get_selection())
    if text ~= "" and not text:find("\n", 1, true) then
      field_set_text(self.find_doc, text, select_all)
      return true
    end
  end
  return false
end

-- Header + controls geometry. Keep in one place so draw and
-- mouse handling agree on coordinates.
function SearchPanel:layout()
  local font = self.font or style.font
  local pad = style.padding.x
  local x = self.position.x + math.floor(pad / 2)
  local w = self.size.x - pad
  local y = self.position.y + style.padding.y
  local L = {}
  local line_h = font:get_height()
  local field_box_h = line_h * 3 + style.padding.y * 2
  local btn_h = math.floor(line_h * 1.2) + style.padding.y * 2
  local small_h = math.floor(btn_h * 0.95)

  L.header_h = line_h + style.padding.y
  L.header = { x = x, y = y, w = w, h = L.header_h }
  y = y + L.header_h + 10

  L.find = { x = x, y = y, w = w, h = field_box_h }
  y = y + field_box_h + 6
  L.replace = { x = x, y = y, w = w, h = field_box_h }
  y = y + field_box_h + 6

  local tog_w = math.floor((w - 12) / 3)
  L.tog_case = { x = x, y = y, w = tog_w, h = small_h }
  L.tog_word = { x = x + tog_w + 6, y = y, w = tog_w, h = small_h }
  L.tog_regex = { x = x + (tog_w + 6) * 2, y = y, w = w - (tog_w + 6) * 2, h = small_h }
  y = y + small_h + 6

  local sc_w = math.floor((w - 12) / 3)
  L.scope_file = { x = x, y = y, w = sc_w, h = small_h }
  L.scope_open = { x = x + sc_w + 6, y = y, w = sc_w, h = small_h }
  L.scope_project = { x = x + (sc_w + 6) * 2, y = y, w = w - (sc_w + 6) * 2, h = small_h }
  y = y + small_h + 6

  local bcol = math.floor((w - 18) / 4)
  L.btn_prev = { x = x, y = y, w = bcol, h = btn_h }
  L.btn_next = { x = x + bcol + 6, y = y, w = bcol, h = btn_h }
  L.btn_replace = { x = x + (bcol + 6) * 2, y = y, w = bcol, h = btn_h }
  L.btn_all = { x = x + (bcol + 6) * 3, y = y, w = w - (bcol + 6) * 3, h = btn_h }
  y = y + btn_h + 6

  L.status_h = font:get_height() + 4
  L.status = { x = x, y = y, w = w, h = L.status_h }
  y = y + L.status_h + 4

  L.results = { x = self.position.x, y = y, w = self.size.x, h = self.position.y + self.size.y - y }
  L.row_h = font:get_height() + style.padding.y
  return L
end

function SearchPanel:search_key()
  return table.concat({
    self.scope, self:get_find_text(),
    self.case_sensitive and "cs" or "ci",
    self.whole_word and "ww" or "nw",
    self.use_regex and "re" or "plain",
  }, "\0")
end

function SearchPanel:results_current()
  return self.results_key == self:search_key()
end

function SearchPanel:schedule_search()
  self.dirty = true
  self.last_edit = system.get_time()
end

function SearchPanel:refresh(reason)
  self.dirty = false
  local text = self:get_find_text()
  if text == "" then
    self.search_token = self.search_token + 1
    self.searching = false
    self.results = {}
    self.selected = 0
    self.results_scroll = 0
    self:set_status("Type to search", "idle")
    core.redraw = true
    return
  end
  if not self:validate_regex() then
    self.results = {}
    self.selected = 0
    self.results_key = nil
    core.redraw = true
    return
  end
  -- Don't pollute the find history with intermediate prefixes while typing.
  if reason ~= "type" then insert_unique(core.previous_find, text) end
  if self.scope == "file" then
    self:run_file_search(reason)
  elseif self.scope == "open" then
    self:run_open_search()
  else
    self:run_project_search()
  end
end

function SearchPanel:current_count_label()
  if #self.results == 0 then return "No results" end
  return string.format("%d of %d", self.selected, #self.results)
end

function SearchPanel:find_is_multiline()
  return self:get_find_text():find("\n", 1, true) ~= nil
end

-- Byte offset of each line start in a `doc.lines`-style array
-- (entries keep their trailing newline).
local function line_starts(lines)
  local starts, acc = { 1 }, 1
  for i, ln in ipairs(lines) do
    acc = acc + #ln
    starts[i + 1] = acc
  end
  return starts
end

local function offset_to_pos(starts, lines, o)
  local line = 1
  for i = 1, #lines do
    if starts[i] <= o then line = i else break end
  end
  return line, common.clamp(o - starts[line] + 1, 1, #lines[line])
end

---Matches `text` against a raw string (whole document or file content).
---Unlike `search.find_all`, this also matches across line breaks.
---@return table list of `{s=integer,e=integer}` inclusive byte offsets
function SearchPanel:match_in_text(haystack, text, opts)
  local results = {}
  if text == "" or not haystack then return results end
  local H, P = haystack, text
  if opts.no_case and not opts.regex then
    H, P = H:lower(), P:lower()
  end
  if opts.regex then
    local flags = opts.no_case and "ims" or "ms"
    local ok, re = pcall(regex.compile, text, flags)
    if not ok or not re then return results end
    local from, guard = 1, 0
    while from <= #H + 1 do
      local ok2, s, e = pcall(regex.cmatch, re, H, from)
      if not ok2 or not s then break end
      e = e - 1
      if not opts.whole_word or search.has_word_boundary(H, s, e) then
        table.insert(results, { s = s, e = e })
      end
      local next_from = (e or s) + 1
      if next_from <= from then next_from = from + 1 end
      from = next_from
      guard = guard + 1
      if guard > 100000 then break end
    end
  else
    local from = 1
    while true do
      local s, e = H:find(P, from, true)
      if not s then break end
      if not opts.whole_word or search.has_word_boundary(H, s, e) then
        table.insert(results, { s = s, e = e })
      end
      from = e + 1
    end
  end
  return results
end

---Finds every match in a doc. Single-line queries use the core engine;
---queries containing a newline are matched against the whole text so
---they can span lines. Returns `{line,col,line2,col2}` (end exclusive).
function SearchPanel:find_in_doc(doc, text, opts)
  if not text:find("\n", 1, true) then
    return search.find_all(doc, text, opts)
  end
  local haystack = doc:get_text(1, 1, math.huge, math.huge)
  local starts = line_starts(doc.lines)
  local results = {}
  for _, m in ipairs(self:match_in_text(haystack, text, opts)) do
    local l1, c1 = offset_to_pos(starts, doc.lines, m.s)
    local l2, c2 = offset_to_pos(starts, doc.lines, m.e + 1)
    table.insert(results, { line = l1, col = c1, line2 = l2, col2 = c2 })
  end
  return results
end

function SearchPanel:run_file_search(reason)
  local dv = self:get_target_docview()
  if not dv or not dv.doc then
    self.results = {}
    self.selected = 0
    self:set_status("No file open", "idle")
    core.redraw = true
    return
  end
  self:remember_target(dv)
  local text = self:get_find_text()
  local matches = self:find_in_doc(dv.doc, text, self:get_opts())
  self.results = {}
  for _, m in ipairs(matches) do
    local preview = trim_preview(dv.doc.lines[m.line] or "")
    table.insert(self.results, {
      doc = dv.doc, line = m.line, col = m.col,
      line2 = m.line2, col2 = m.col2, preview = preview,
    })
  end
  -- Select the match closest at/after the doc cursor so the
  -- background document tracks what the panel found.
  local cl1, cc1 = dv.doc:get_selection()
  self.selected = 0
  for i, r in ipairs(self.results) do
    if r.line > cl1 or (r.line == cl1 and r.col >= cc1) then
      self.selected = i
      break
    end
  end
  if self.selected == 0 and #self.results > 0 then self.selected = 1 end
  if #self.results == 0 then
    self:set_status("No results", "idle")
  else
    self:set_status(self:current_count_label(), "info")
    if reason ~= "nav" then self:apply_selection(false) end
  end
  self.results_key = self:search_key()
  self:ensure_selected_visible()
  core.redraw = true
end

function SearchPanel:run_open_search()
  local text = self:get_find_text()
  local opts = self:get_opts()
  self.results = {}
  local max = config.plugins.searchpanel.max_results
  for _, doc in ipairs(core.docs) do
    local ok, matches = pcall(self.find_in_doc, self, doc, text, opts)
    if ok and matches then
      for _, m in ipairs(matches) do
        local preview = trim_preview(doc.lines[m.line] or "")
        table.insert(self.results, {
          doc = doc, label = doc:get_name(),
          line = m.line, col = m.col, line2 = m.line2, col2 = m.col2,
          preview = preview,
        })
        if #self.results >= max then break end
      end
    end
    if #self.results >= max then break end
  end
  self.selected = #self.results > 0 and 1 or 0
  self:set_status(#self.results == 0 and "No results"
    or string.format("%d match(es) in open files", #self.results),
    #self.results == 0 and "idle" or "info")
  self.results_key = self:search_key()
  self:ensure_selected_visible()
  core.redraw = true
end

function SearchPanel:run_project_search()
  self.search_token = self.search_token + 1
  local token = self.search_token
  local text = self:get_find_text()
  local opts = self:get_opts()
  self.results = {}
  self.selected = 0
  self.results_scroll = 0
  self.searching = true
  self.results_key = nil
  self.files_scanned = 0
  self:set_status("Searching…", "active")
  core.redraw = true
  local max = config.plugins.searchpanel.max_results
  local multiline = text:find("\n", 1, true) ~= nil
  core.add_thread(function()
    local count = 0
    for _, project in ipairs(core.projects) do
      for _, file in project:files() do
        if token ~= self.search_token then return end
        if file.type == "file" then
          count = count + 1
          self.files_scanned = count
          if multiline then
            local fp = io.open(file.filename, "r")
            if fp then
              local content = fp:read("*a")
              fp:close()
              if content then
                -- split keeping newlines for offset mapping
                local lines, s = {}, 1
                while true do
                  local e = content:find("\n", s, true)
                  if not e then
                    table.insert(lines, content:sub(s))
                    break
                  end
                  table.insert(lines, content:sub(s, e))
                  s = e + 1
                end
                local starts = line_starts(lines)
                for _, m in ipairs(self:match_in_text(content, text, opts)) do
                  local l1, c1 = offset_to_pos(starts, lines, m.s)
                  local l2, c2 = offset_to_pos(starts, lines, m.e + 1)
                  table.insert(self.results, {
                    file = file.filename, line = l1, col = c1,
                    line2 = l2, col2 = c2,
                    preview = trim_preview(lines[l1]:gsub("\n$", "")),
                  })
                  if #self.results >= max then break end
                end
              end
              if token ~= self.search_token then return end
              if count % 25 == 0 then
                self:set_status(string.format("Searching… (%d files, %d matches)",
                  count, #self.results), "active")
                core.redraw = true
                coroutine.yield(0)
              end
            end
          else
          local fp = io.open(file.filename, "r")
          if fp then
            local n = 1
            for line in fp:lines() do
              local matches = search.find_all_in_line(line, text, opts)
              for _, m in ipairs(matches) do
                local start = math.max(m.s - 60, 1)
                local preview = trim_preview(
                  (start > 1 and "…" or "") .. line:sub(start, start + 200))
                table.insert(self.results, {
                  file = file.filename, line = n, col = m.s,
                  line2 = n, col2 = m.e + 1, preview = preview,
                })
                if #self.results >= max then break end
              end
              if #self.results >= max then break end
              if n % 100 == 0 then
                self:set_status(string.format("Searching… (%d files, %d matches)",
                  count, #self.results), "active")
                coroutine.yield(0)
              end
              if token ~= self.search_token then fp:close() return end
              n = n + 1
            end
            fp:close()
            if count % 25 == 0 then
              self:set_status(string.format("Searching… (%d files, %d matches)",
                count, #self.results), "active")
              core.redraw = true
              coroutine.yield(0)
            end
          end
          end
        end
        if #self.results >= max then break end
      end
      if #self.results >= max then break end
    end
    if token ~= self.search_token then return end
    self.searching = false
    self.selected = #self.results > 0 and 1 or 0
    if #self.results >= max then
      self:set_status(string.format("Showing first %d matches", max), "info")
    elseif #self.results == 0 then
      self:set_status("No results", "idle")
    else
      self:set_status(string.format("%d match(es) in project", #self.results), "info")
    end
    self.results_key = self:search_key()
    self:ensure_selected_visible()
    core.redraw = true
  end)
end

function SearchPanel:ensure_selected_visible()
  local L = self.R.results or self:layout().results
  local row_h = (self.font or style.font):get_height() + style.padding.y
  if self.selected < 1 or L.h <= 0 then self.results_scroll = 0 return end
  local y_rel = (self.selected - 1) * row_h
  if y_rel < self.results_scroll then
    self.results_scroll = y_rel
  elseif y_rel + row_h > self.results_scroll + L.h then
    self.results_scroll = y_rel + row_h - L.h
  end
  local max = math.max(0, #self.results * row_h - L.h)
  self.results_scroll = common.clamp(self.results_scroll, 0, max)
end

function SearchPanel:find_docview_for(doc)
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(DocView) and view.doc == doc then return view end
  end
end

---Jumps to the given result. When `stay` is true the panel keeps
---keyboard focus afterwards (used by clicks and panel buttons).
function SearchPanel:goto_result(idx, stay)
  local r = self.results[idx]
  if not r then return false end
  self.selected = idx
  if self.scope == "file" then self:set_status(self:current_count_label(), "info") end
  local ok = core.try(function()
    local dv
    if r.doc then
      dv = self:find_docview_for(r.doc)
      if not dv then dv = core.root_view:open_doc(r.doc) end
      self:remember_target(dv)
    elseif r.file then
      dv = core.root_view:open_doc(core.open_doc(r.file))
      self:remember_target(dv)
    end
    if dv then
      local l2, c2 = r.line2, r.col2
      -- Clamp columns changed by edits since the search ran.
      l2 = common.clamp(l2, 1, #dv.doc.lines)
      c2 = common.clamp(c2, 1, #dv.doc.lines[l2])
      local l1 = common.clamp(r.line, 1, #dv.doc.lines)
      local c1 = common.clamp(r.col, 1, #dv.doc.lines[l1])
      dv.doc:set_selection(l2, c2, l1, c1)
      dv:scroll_to_line(l1, true)
    end
  end)
  self:ensure_selected_visible()
  core.redraw = true
  if stay and ok then core.set_active_view(self) end
  return ok
end

function SearchPanel:apply_selection(stay)
  if self.selected >= 1 then self:goto_result(self.selected, stay) end
end

function SearchPanel:go_next()
  if #self.results == 0 then return end
  local next_idx = self.selected + 1
  if next_idx > #self.results then next_idx = 1 end
  local stay = core.active_view == self
  self:goto_result(next_idx, stay)
  if self.scope == "file" then self:set_status(self:current_count_label(), "info") end
end

function SearchPanel:go_prev()
  if #self.results == 0 then return end
  local prev_idx = self.selected - 1
  if prev_idx < 1 then prev_idx = #self.results end
  local stay = core.active_view == self
  self:goto_result(prev_idx, stay)
  if self.scope == "file" then self:set_status(self:current_count_label(), "info") end
end

local function plain_replacement(new)
  return new
end

---Computes the replacement text for one matched substring.
function SearchPanel:replacement_for(matched, new)
  if not self.use_regex then return plain_replacement(new) end
  -- "s" (dot-all) only when the query spans lines, so single-line
  -- patterns keep matching within one line as before.
  local dotall = self:get_find_text():find("\n", 1, true) and "s" or ""
  local flags = (self.case_sensitive and "m" or "im") .. dotall
  local re, err = regex.compile(self:get_find_text(), flags)
  if not re then return nil, err end
  local ok, res = pcall(regex.gsub, re, matched, new)
  if not ok then return nil, res end
  return res, nil
end

---Replaces the currently selected match (file scope) or the match
---under the cursor, then advances to the next one.
function SearchPanel:replace_one()
  local text = self:get_find_text()
  if text == "" then self:set_status("Nothing to replace", "idle") return 0 end
  if not self:validate_regex() then return 0 end
  local new = self:get_replace_text()
  if self.scope ~= "file" then
    core.error("Replace-one is only available in file scope; use Replace-all for '%s'", self.scope)
    return 0
  end
  local dv = self:get_target_docview()
  if not dv then self:set_status("No file open", "idle") return 0 end
  self:remember_target(dv)
  local doc = dv.doc
  local l1, c1, l2, c2 = doc:get_selection(true)
  local sel = doc:get_text(l1, c1, l2, c2)
  local matches_here = false
  if sel ~= "" then
    local opts = self:get_opts()
    if self.use_regex then
      local dotall = text:find("\n", 1, true) and "s" or ""
      local re = regex.compile(text, (self.case_sensitive and "" or "i") .. dotall)
      if re then
        local s, e = regex.cmatch(re, sel)
        matches_here = s == 1 and e and (e - 1) == #sel
        -- Whole-word on a lone selection: boundaries are the
        -- surrounding document characters.
        if matches_here and self.whole_word then
          local before = doc:get_text(l1, c1 - 1, l1, c1)
          local after = doc:get_text(l2, c2, l2, c2 + 1)
          if search.is_word_char(before:sub(-1)) then matches_here = false end
          if search.is_word_char(after:sub(1, 1)) then matches_here = false end
        end
      end
    else
      local a, b = sel, text
      if not self.case_sensitive then a, b = a:lower(), b:lower() end
      matches_here = (a == b)
      if matches_here and self.whole_word then
        local before = doc:get_text(l1, c1 - 1, l1, c1)
        local after = doc:get_text(l2, c2, l2, c2 + 1)
        if search.is_word_char(before:sub(-1)) then matches_here = false end
        if search.is_word_char(after:sub(1, 1)) then matches_here = false end
      end
    end
  end
  if matches_here then
    local repl, err = self:replacement_for(sel, new)
    if repl == nil then self:set_status("Replace failed", "warn") return 0 end
    doc:insert(l2, c2, repl)
    doc:remove(l1, c1, l2, c2)
    -- Park the cursor past the replacement so the follow-up search
    -- lands on the next match instead of re-matching the same spot.
    doc:set_selection(doc:position_offset(l1, c1, #repl))
    insert_unique(core.previous_replace, new)
    core.log("Replaced 1 instance of %q with %q", text, new)
    self:refresh("nav")
    self:apply_selection(false)
    if self.scope == "file" then self:set_status(self:current_count_label(), "info") end
    return 1
  end
  -- Selection is not a match: jump to the nearest match instead.
  if #self.results == 0 or not self:results_current() then
    self:refresh("nav")
    self:apply_selection(false)
  else
    self:go_next()
  end
  return 0
end

---Replaces every match, honouring the current scope.
function SearchPanel:replace_all(confirmed)
  local text = self:get_find_text()
  if text == "" then self:set_status("Nothing to replace", "idle") return end
  if not self:validate_regex() then return end
  local new = self:get_replace_text()
  if self.scope == "file" then
    local n = self:replace_all_in_doc(self:get_target_docview(), text, new)
    if n == nil then return end
    insert_unique(core.previous_replace, new)
    self:set_status(string.format("Replaced %d", n), "info")
    core.log("Replaced %d instance(s) of %q with %q", n, text, new)
    self:refresh("nav")
    self:set_status(string.format("Replaced %d", n), "info")
  elseif self.scope == "open" then
    local total, files = 0, 0
    for _, doc in ipairs(core.docs) do
      local dv = self:find_docview_for(doc)
      local n = self:replace_all_in_doc(dv or { doc = doc }, text, new)
      if n and n > 0 then total, files = total + n, files + 1 end
    end
    insert_unique(core.previous_replace, new)
    core.log("Replaced %d instance(s) in %d open file(s)", total, files)
    self:refresh("nav")
    self:set_status(string.format("Replaced %d in %d file(s)", total, files), "info")
  else
    self:replace_all_in_project(text, new, confirmed)
  end
end

---Bottom-up replacement so earlier offsets stay valid.
---@return integer? count or nil on failure
function SearchPanel:replace_all_in_doc(dv, text, new)
  if not dv or not dv.doc then self:set_status("No file open", "idle") return nil end
  local doc = dv.doc
  local ok, matches = pcall(self.find_in_doc, self, doc, text, self:get_opts())
  if not ok then self:set_status("Search failed", "warn") return nil end
  if #matches == 0 then return 0 end
  local n = 0
  for i = #matches, 1, -1 do
    local m = matches[i]
    local matched = doc:get_text(m.line, m.col, m.line2, m.col2)
    local repl, err = self:replacement_for(matched, new)
    if repl == nil then self:set_status("Replace failed", "warn") return nil end
    if repl ~= matched then
      doc:insert(m.line2, m.col2, repl)
      doc:remove(m.line, m.col, m.line2, m.col2)
    end
    n = n + 1
  end
  return n
end

function SearchPanel:open_doc_for_file(file)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == file or doc.filename == file then return doc end
  end
end

function SearchPanel:replace_all_in_project(text, new, confirmed)
  -- Project replace works off the current result list (re-matching each
  -- file freshly at apply time), so it never rescans the project
  -- synchronously and never applies stale offsets.
  if self.searching then
    self:set_status("Wait for the search to finish…", "active")
    core.redraw = true
    return
  end
  if #self.results == 0 or not self:results_current() then
    self:set_status("No results — wait for the search…", "idle")
    self:refresh("opt")
    return
  end
  local max = config.plugins.searchpanel.max_results
  if #self.results >= max then
    self:set_status("Too many matches — refine the query first", "warn")
    core.error("Refusing project replace: result list is capped at %d", max)
    return
  end
  local files = {}
  for _, r in ipairs(self.results) do
    if r.file then files[r.file] = true end
  end
  local nfiles = 0
  for _ in pairs(files) do nfiles = nfiles + 1 end
  if nfiles == 0 then
    self:set_status("Project scope has no file results", "idle")
    return
  end
  if not confirmed then
    core.nag_view:show(
      "Replace in project",
      string.format("Replace %d instance(s) of %q in %d file(s)?", #self.results, text, nfiles),
      { { text = "Yes", default_yes = true }, { text = "No", default_no = true } },
      function(item)
        if item.text == "Yes" then self:replace_all_in_project(text, new, true) end
      end
    )
    return
  end
  local opts = self:get_opts()
  local done, done_files = 0, 0
  for file in pairs(files) do
    local doc = self:open_doc_for_file(file)
    if doc then
      local ok, matches = pcall(self.find_in_doc, self, doc, text, opts)
      if ok and matches then
        local n = 0
        for i = #matches, 1, -1 do
          local m = matches[i]
          local matched = doc:get_text(m.line, m.col, m.line2, m.col2)
          local repl = self:replacement_for(matched, new)
          if repl == nil then break end
          if repl ~= matched then
            doc:insert(m.line2, m.col2, repl)
            doc:remove(m.line, m.col, m.line2, m.col2)
          end
          n = n + 1
        end
        if n > 0 then done, done_files = done + n, done_files + 1 end
      end
    else
      local fp = io.open(file, "r")
      if fp then
        local lines = {}
        for line in fp:lines() do table.insert(lines, line) end
        fp:close()
        local n = 0
        for lineno, line in ipairs(lines) do
          local ms = search.find_all_in_line(line, text, opts)
          if #ms > 0 then
            table.sort(ms, function(a, b) return a.s > b.s end)
            for _, m in ipairs(ms) do
              local matched = line:sub(m.s, m.e)
              local repl = self:replacement_for(matched, new)
              if repl == nil then break end
              line = line:sub(1, m.s - 1) .. repl .. line:sub(m.e + 1)
              n = n + 1
            end
            lines[lineno] = line
          end
        end
        if n > 0 then
          local out = io.open(file, "w")
          if out then
            for _, line in ipairs(lines) do out:write(line, "\n") end
            out:close()
            done, done_files = done + n, done_files + 1
          else
            core.error("Couldn't write %q", file)
          end
        end
      end
    end
  end
  insert_unique(core.previous_replace, new)
  core.log("Replaced %d instance(s) in %d file(s)", done, done_files)
  self:refresh("nav")
  self:set_status(string.format("Replaced %d in %d file(s)", done, done_files), "info")
end

-- Field editing -----------------------------------------------------------

function SearchPanel:focused_doc()
  return self.focus == "replace" and self.replace_doc or self.find_doc
end

function SearchPanel:after_edit()
  core.blink_reset()
  self:schedule_search()
  core.redraw = true
end

function SearchPanel:on_text_input(text)
  if core.active_view ~= self then return end
  if self.focus ~= "find" and self.focus ~= "replace" then return end
  if text ~= "" then self:focused_doc():text_input(text) end
  self:after_edit()
end

function SearchPanel:field_backspace()
  self:focused_doc():delete_to_cursor(nil, translate.previous_char)
  self:after_edit()
end

function SearchPanel:field_delete()
  self:focused_doc():delete_to_cursor(nil, translate.next_char)
  self:after_edit()
end

function SearchPanel:field_move(fn, select)
  local doc = self:focused_doc()
  if select then doc:select_to_cursor(nil, fn) else doc:move_to_cursor(nil, fn) end
  core.blink_reset()
  core.redraw = true
end

local function field_prev_line(doc, line, col)
  return doc:sanitize_position(line - 1, col)
end

local function field_next_line(doc, line, col)
  return doc:sanitize_position(line + 1, col)
end

function SearchPanel:field_home(select)
  self:field_move(translate.start_of_line, select)
end

function SearchPanel:field_end(select)
  self:field_move(translate.end_of_line, select)
end

function SearchPanel:field_select_all()
  local doc = self:focused_doc()
  doc:set_selection(1, 1, #doc.lines, math.huge)
  core.redraw = true
end

function SearchPanel:field_copy()
  local doc = self:focused_doc()
  local text = doc:get_text(doc:get_selection())
  system.set_clipboard(text)
end

function SearchPanel:field_cut()
  local doc = self:focused_doc()
  local l1, c1, l2, c2 = doc:get_selection()
  local text = doc:get_text(l1, c1, l2, c2)
  system.set_clipboard(text)
  if l1 ~= l2 or c1 ~= c2 then doc:delete_to_cursor(nil, 0) end
  self:after_edit()
end

function SearchPanel:field_paste()
  local text = system.get_clipboard() or ""
  if text ~= "" then self:focused_doc():text_input(text) end
  self:after_edit()
end

function SearchPanel:field_undo()
  self:focused_doc():undo()
  self:after_edit()
end

function SearchPanel:field_redo()
  self:focused_doc():redo()
  self:after_edit()
end

function SearchPanel:cycle_focus(dir)
  self.focus = (self.focus == "find") and "replace" or "find"
  if dir == nil then
    -- tab always toggles; explicit arg kept for symmetry
  end
  core.blink_reset()
  core.redraw = true
end

-- Visibility / treeview alternation ---------------------------------------

local function get_treeview()
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if tostring(view) == "TreeView" then return view end
  end
end

local tree_toggle_wrapped = false
local function ensure_tree_toggle_wrapped(panel)
  if tree_toggle_wrapped then return end
  local cmd = command.map["treeview:toggle"]
  if not cmd then return end
  tree_toggle_wrapped = true
  local orig = cmd.perform
  cmd.perform = function(...)
    orig(...)
    local tree = get_treeview()
    -- Showing the explorer hides the search panel and vice versa.
    if tree and tree.visible and panel.visible then
      panel.visible = false
      core.redraw = true
    end
  end
end

function SearchPanel:show(prefill)
  ensure_tree_toggle_wrapped(self)
  local tree = get_treeview()
  if tree then tree.visible = false end
  if not self.visible then
    self.visible = true
    if prefill == nil or prefill then
      if not self:prefill_from_selection(true) and self:get_find_text() == "" then
        -- keep previous text; just select it for quick overwrite
        self.find_doc:set_selection(1, 1, #self.find_doc.lines, math.huge)
      end
    end
    self.focus = "find"
    core.set_active_view(self)
    self:refresh("show")
  else
    core.set_active_view(self)
  end
  core.redraw = true
end

function SearchPanel:hide(restore_tree)
  if not self.visible then return end
  self.visible = false
  self.search_token = self.search_token + 1
  self.searching = false
  if restore_tree == nil or restore_tree then
    local tree = get_treeview()
    if tree then tree.visible = true end
  end
  local dv = self:get_target_docview()
  if dv then core.set_active_view(dv) end
  core.redraw = true
end

function SearchPanel:toggle()
  if self.visible then
    self:hide(true)
  else
    self:show(true)
  end
end

-- Update ------------------------------------------------------------------

function SearchPanel:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "searchpanel")
  end
  if self.dirty and system.get_time() - self.last_edit > 0.15 then
    self:refresh("type")
  end
  -- drive the field caret blink (DocView only does this for itself)
  if not config.disable_blink and system.window_has_focus(core.window) and self == core.active_view then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end
  SearchPanel.super.update(self)
end

-- Drawing -----------------------------------------------------------------

local function draw_button(self, r, text, active, hovered, accent_active)
  local C = self.C or style.panel_theme()
  local font = self.font or style.font
  local bg = C.field_bg
  local fg = C.text
  if active then
    bg = accent_active and C.accent or C.highlight
    fg = accent_active and C.panel_bg or C.accent
  elseif hovered then
    bg = C.highlight
  end
  renderer.draw_rect(r.x, r.y, r.w, r.h, bg)
  renderer.draw_rect(r.x, r.y, r.w, 1, C.border)
  renderer.draw_rect(r.x, r.y + r.h - 1, r.w, 1, C.border)
  renderer.draw_rect(r.x, r.y, 1, r.h, C.border)
  renderer.draw_rect(r.x + r.w - 1, r.y, 1, r.h, C.border)
  common.draw_text(font, fg, text, "center", r.x, r.y, r.w, r.h)
end

local function field_cursor(doc)
  local _, _, l2, c2 = doc:get_selection()
  return l2, c2
end

function SearchPanel:draw_field(r, doc, placeholder, focused)
  local C = self.C or style.panel_theme()
  renderer.draw_rect(r.x, r.y, r.w, r.h, C.field_bg)
  local is_active = focused and core.active_view == self
  local border = is_active and C.focus or C.border
  renderer.draw_rect(r.x, r.y, r.w, 1, border)
  renderer.draw_rect(r.x, r.y + r.h - 1, r.w, 1, border)
  renderer.draw_rect(r.x, r.y, 1, r.h, border)
  renderer.draw_rect(r.x + r.w - 1, r.y, 1, r.h, border)

  local pad_x, pad_y = 8, style.padding.y
  local text = field_text(doc)
  local font = self.font or style.font
  local line_h = font:get_height()
  core.push_clip_rect(r.x + 1, r.y, r.w - 2, r.h)
  local scroll = doc == self.find_doc and self.find_scroll or self.replace_scroll

  local l1, c1, l2, c2 = doc:get_selection(true)
  local n = #doc.lines
  for i = 1, n do
    local y = r.y + pad_y + (i - 1) * line_h - scroll.y
    if y + line_h >= r.y and y <= r.y + r.h then
      local ltext = doc.lines[i]:gsub("\n$", "")
      local x0 = r.x + pad_x - scroll.x
      if c1 ~= c2 and not (i < l1 or i > l2) then
        local sc = (i == l1) and c1 or 1
        local ec = (i == l2) and c2 or (#ltext + 1)
        if ec > sc then
          local x1 = x0 + font:get_width(ltext:sub(1, sc - 1))
          local x2 = x0 + font:get_width(ltext:sub(1, ec - 1))
          renderer.draw_rect(x1, y, x2 - x1, line_h, C.selection)
        end
      end
      if ltext ~= "" then
        renderer.draw_text(font, ltext, x0, y, C.text)
      end
    end
  end
  if text == "" then
    renderer.draw_text(font, placeholder,
      r.x + pad_x - scroll.x, r.y + pad_y - scroll.y, C.dim)
  end
  -- caret
  local cl, cc = field_cursor(doc)
  if is_active
      and not config.disable_blink
      and (core.blink_timer - core.blink_start) % config.blink_period < config.blink_period / 2 then
    local cline = (doc.lines[cl] or ""):gsub("\n$", "")
    local cx = r.x + pad_x + font:get_width(cline:sub(1, cc - 1)) - scroll.x
    local cy = r.y + pad_y + (cl - 1) * line_h - scroll.y
    renderer.draw_rect(cx, cy, style.caret_width, line_h, C.caret)
  end
  -- keep cursor visible
  if focused then
    local cline = (doc.lines[cl] or ""):gsub("\n$", "")
    local cursor_x = font:get_width(cline:sub(1, cc - 1))
    local max_vis = r.w - pad_x * 2
    if cursor_x - scroll.x > max_vis then
      scroll.x = cursor_x - max_vis
    elseif cursor_x - scroll.x < 0 then
      scroll.x = cursor_x
    end
    local cursor_y = (cl - 1) * line_h
    local max_vis_y = r.h - pad_y * 2
    if cursor_y - scroll.y > max_vis_y - line_h then
      scroll.y = cursor_y - (max_vis_y - line_h)
    elseif cursor_y - scroll.y < 0 then
      scroll.y = cursor_y
    end
  end
  core.pop_clip_rect()
end

function SearchPanel:draw()
  if not self.visible then return end
  if self.size.x < 10 then return end
  self.C = style.panel_theme()
  local C = self.C
  local F = self.font or style.font
  self:draw_background(C.panel_bg)
  local L = self:layout()
  self.R = L
  local hovered = self.hovered_control

  -- header: filled theme band + close
  renderer.draw_rect(L.header.x, L.header.y, L.header.w, L.header.h, C.header_bg)
  local ix = common.draw_text(style.icon_font, C.header_text, "L", "left",
    L.header.x + 6, L.header.y, L.header.w - 24, L.header.h)
  common.draw_text(F, C.header_text, "SEARCH", "left",
    ix + 6, L.header.y, L.header.w - 24, L.header.h)
  local close = { x = L.header.x + L.header.w - 24, y = L.header.y, w = 24, h = L.header.h }
  self.R.close = close
  if hovered == "close" then
    renderer.draw_rect(close.x, close.y, close.w, close.h, C.highlight)
  end
  common.draw_text(F, C.header_text, "x", "center", close.x, close.y, close.w, close.h)

  self:draw_field(L.find, self.find_doc, "Find", self.focus == "find")
  self:draw_field(L.replace, self.replace_doc, "Replace", self.focus == "replace")

  draw_button(self, L.tog_case, "Aa", self.case_sensitive, hovered == "case", true)
  draw_button(self, L.tog_word, "W", self.whole_word, hovered == "word", true)
  draw_button(self, L.tog_regex, ".*", self.use_regex, hovered == "regex", true)

  local scope_active = { file = self.scope == "file", open = self.scope == "open", project = self.scope == "project" }
  draw_button(self, L.scope_file, "File", scope_active.file, hovered == "scope_file", true)
  draw_button(self, L.scope_open, "Open", scope_active.open, hovered == "scope_open", true)
  draw_button(self, L.scope_project, "Project", scope_active.project, hovered == "scope_project", true)

  draw_button(self, L.btn_prev, "<", false, hovered == "prev", false)
  draw_button(self, L.btn_next, ">", false, hovered == "next", false)
  draw_button(self, L.btn_replace, "Rep", false, hovered == "replace_one", false)
  draw_button(self, L.btn_all, "All", false, hovered == "replace_all", false)

  common.draw_text(F, status_color(self), self.status, "left",
    L.status.x, L.status.y, L.status.w, L.status.h)

  -- results
  local res = L.results
  if res.h > 0 then
    core.push_clip_rect(res.x, res.y, res.w, res.h)
    local row_h = L.row_h
    local ox = res.x + math.floor(style.padding.x / 2)
    local first = math.max(1, math.floor(self.results_scroll / row_h) + 1)
    local y = res.y + (first - 1) * row_h - self.results_scroll
    for i = first, #self.results do
      if y > res.y + res.h then break end
      local r = self.results[i]
      if i == self.selected then
        renderer.draw_rect(res.x, y, res.w, row_h, C.highlight)
      elseif i == self.hovered then
        local c = { table.unpack(C.highlight) }
        c[4] = 100
        renderer.draw_rect(res.x, y, res.w, row_h, c)
      end
      local label
      local root = core.root_project()
      if r.file then
        label = string.format("%s:%d",
          root and root:normalize_path(r.file) or r.file, r.line)
      elseif r.label then
        label = string.format("%s:%d", r.label, r.line)
      else
        label = string.format("%d", r.line)
      end
      local lx = common.draw_text(F, C.dim, label .. "  ", "left", ox, y, res.w, row_h)
      local preview_color = i == self.selected and C.match or C.text
      common.draw_text(F, preview_color,
        r.preview, "left", lx, y, res.x + res.w - lx, row_h)
      y = y + row_h
    end
    if #self.results == 0 and not self.searching then
      common.draw_text(F, C.dim, "No results", "left", ox, res.y + 4, res.w, row_h)
    end
    core.pop_clip_rect()
    -- scrollbar
    local content_h = #self.results * row_h
    if content_h > res.h and res.h > 0 then
      local bar_h = math.max(20, res.h * res.h / content_h)
      local bar_y = res.y + (self.results_scroll / content_h) * res.h
      bar_y = math.min(bar_y, res.y + res.h - bar_h)
      renderer.draw_rect(res.x + res.w - 5, bar_y, 4, bar_h, C.dim)
    end
  end
end

-- Mouse -------------------------------------------------------------------

local function in_rect(x, y, r)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function SearchPanel:field_pos_from_xy(doc, r, x, y)
  local pad_x, pad_y = 8, style.padding.y
  local font = self.font or style.font
  local line_h = font:get_height()
  local scroll = doc == self.find_doc and self.find_scroll or self.replace_scroll
  local line = math.floor((y - (r.y + pad_y) + scroll.y) / line_h) + 1
  line = common.clamp(line, 1, #doc.lines)
  local ltext = (doc.lines[line] or ""):gsub("\n$", "")
  local rel = x - (r.x + pad_x) + scroll.x
  local col = 1
  for i = 1, #ltext + 1 do
    local w = font:get_width(ltext:sub(1, i - 1))
    if w >= rel then col = i break end
    col = i + 1
  end
  col = common.clamp(col, 1, #ltext + 1)
  while col > 1 and common.is_utf8_cont(ltext, col) do col = col - 1 end
  return line, col
end

function SearchPanel:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return false end
  if button ~= "left" then return true end
  local L = self.R
  if in_rect(x, y, L.close) then self:hide(true) return true end
  if in_rect(x, y, L.find) then
    self.focus = "find"
    core.set_active_view(self)
    local line, col = self:field_pos_from_xy(self.find_doc, L.find, x, y)
    if clicks >= 2 then
      self.find_doc:set_selection(1, 1, #self.find_doc.lines, math.huge)
    else
      self.find_doc:set_selection(line, col)
    end
    core.blink_reset()
    core.redraw = true
    return true
  end
  if in_rect(x, y, L.replace) then
    self.focus = "replace"
    core.set_active_view(self)
    local line, col = self:field_pos_from_xy(self.replace_doc, L.replace, x, y)
    if clicks >= 2 then
      self.replace_doc:set_selection(1, 1, #self.replace_doc.lines, math.huge)
    else
      self.replace_doc:set_selection(line, col)
    end
    core.blink_reset()
    core.redraw = true
    return true
  end
  if in_rect(x, y, L.tog_case) then self.case_sensitive = not self.case_sensitive self:refresh("opt") return true end
  if in_rect(x, y, L.tog_word) then self.whole_word = not self.whole_word self:refresh("opt") return true end
  if in_rect(x, y, L.tog_regex) then self.use_regex = not self.use_regex self:refresh("opt") return true end
  if in_rect(x, y, L.scope_file) then self.scope = "file" self:refresh("opt") return true end
  if in_rect(x, y, L.scope_open) then self.scope = "open" self:refresh("opt") return true end
  if in_rect(x, y, L.scope_project) then self.scope = "project" self:refresh("opt") return true end
  if in_rect(x, y, L.btn_prev) then self:go_prev() core.set_active_view(self) return true end
  if in_rect(x, y, L.btn_next) then self:go_next() core.set_active_view(self) return true end
  if in_rect(x, y, L.btn_replace) then self:replace_one() core.set_active_view(self) return true end
  if in_rect(x, y, L.btn_all) then self:replace_all(false) core.set_active_view(self) return true end
  local res = L.results
  if res and x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
    local row_h = L.row_h
    local idx = math.floor((y - res.y + self.results_scroll) / row_h) + 1
    if self.results[idx] then
      self.selected = idx
      self:goto_result(idx, true)
    end
    return true
  end
  return true
end

function SearchPanel:on_mouse_moved(x, y, ...)
  if not self.visible then return end
  local L = self.R
  self.hovered = 0
  local control = nil
  local function check(name, r)
    if in_rect(x, y, r) then control = name return true end
    return false
  end
  if check("close", L.close) then
  elseif check("case", L.tog_case) then
  elseif check("word", L.tog_word) then
  elseif check("regex", L.tog_regex) then
  elseif check("scope_file", L.scope_file) then
  elseif check("scope_open", L.scope_open) then
  elseif check("scope_project", L.scope_project) then
  elseif check("prev", L.btn_prev) then
  elseif check("next", L.btn_next) then
  elseif check("replace_one", L.btn_replace) then
  elseif check("replace_all", L.btn_all) then
  elseif check("find", L.find) then
  elseif check("replace", L.replace) then
  end
  if not control and L.results then
    local res = L.results
    if x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
      local idx = math.floor((y - res.y + self.results_scroll) / L.row_h) + 1
      if self.results[idx] then self.hovered = idx control = "result" end
    end
  end
  if control ~= self.hovered_control then
    self.hovered_control = control
    local tips = {
      close = "Close search (show explorer)",
      case = "Match case (Aa)",
      word = "Whole word (W)",
      regex = "Regular expression (.*)",
      prev = "Previous match (Shift+Enter)",
      next = "Next match (Enter)",
      replace_one = "Replace current match",
      replace_all = "Replace all matches",
      scope_file = "Search in current file",
      scope_open = "Search in open files",
      scope_project = "Search in project",
      find = "Find text (multi-line: Ctrl+Shift+Enter = newline)",
      replace = "Replacement text (multi-line)",
    }
    if control and tips[control] then
      core.status_view:show_tooltip(tips[control])
    else
      core.status_view:remove_tooltip()
    end
    core.redraw = true
  end
  self.cursor = (control == "find" or control == "replace") and "ibeam" or "arrow"
end

function SearchPanel:on_mouse_left()
  self.hovered_control = nil
  core.status_view:remove_tooltip()
end

function SearchPanel:on_mouse_wheel(y, x)
  if not self.visible then return false end
  local res = self.R.results
  if not res or res.h <= 0 then return false end
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  if mx >= res.x and my >= res.y and mx < res.x + res.w and my < res.y + res.h then
    local row_h = self.R.row_h or ((self.font or style.font):get_height() + style.padding.y)
    self.results_scroll = self.results_scroll - y * row_h * 3
    local max = math.max(0, #self.results * row_h - res.h)
    self.results_scroll = common.clamp(self.results_scroll, 0, max)
    core.redraw = true
    return true
  end
  return false
end

-- Instantiate ---------------------------------------------------------------

local view = SearchPanel()
do
  local node = core.root_view:get_active_node()
  view.node = node:split("left", view, { x = true }, true)
end

-- Track the last focused document so file-scope search and replace
-- keep working after the panel itself becomes the active view.
local orig_set_active_view = core.set_active_view
function core.set_active_view(v, ...)
  orig_set_active_view(v, ...)
  local active = core.next_active_view or core.active_view
  if active and active ~= view and active:is(DocView) then
    view:remember_target(active)
  end
end

-- Commands ------------------------------------------------------------------

local function panel_visible() return view.visible end
local function field_active()
  if core.active_view == view and (view.focus == "find" or view.focus == "replace") then
    return true, view
  end
  return false
end

command.add(nil, {
  ["search-panel:toggle"] = function() view:toggle() end,
  ["search-panel:show"] = function() view:show(true) end,
})

local function panel_has_query()
  return view.visible and view:get_find_text() ~= ""
end

command.add(panel_visible, {
  ["search-panel:replace-all"] = function() view:replace_all(false) end,
  ["search-panel:set-scope-file"] = function() view.scope = "file" view:refresh("opt") end,
  ["search-panel:set-scope-open"] = function() view.scope = "open" view:refresh("opt") end,
  ["search-panel:set-scope-project"] = function() view.scope = "project" view:refresh("opt") end,
})

-- F3/Shift+F3 navigate the panel while it has a query; otherwise they
-- fall through to the classic find-replace commands.
command.add(panel_has_query, {
  ["search-panel:next"] = function() view:go_next() end,
  ["search-panel:previous"] = function() view:go_prev() end,
})

command.add(SearchPanel, {
  ["search-panel:hide"] = function(v) v:hide(true) end,
  ["search-panel:focus-find"] = function(v) v.focus = "find" core.blink_reset() core.redraw = true end,
  ["search-panel:focus-replace"] = function(v) v.focus = "replace" core.blink_reset() core.redraw = true end,
  ["search-panel:focus-next"] = function(v) v:cycle_focus() end,
  ["search-panel:focus-previous"] = function(v) v:cycle_focus() end,
  ["search-panel:confirm"] = function(v)
    if v.focus == "replace" then v:replace_one() else v:go_next() end
  end,
  ["search-panel:replace-one"] = function(v) v:replace_one() end,
  ["search-panel:toggle-case"] = function(v) v.case_sensitive = not v.case_sensitive v:refresh("opt") end,
  ["search-panel:toggle-word"] = function(v) v.whole_word = not v.whole_word v:refresh("opt") end,
  ["search-panel:toggle-regex"] = function(v) v.use_regex = not v.use_regex v:refresh("opt") end,
})

command.add(field_active, {
  ["search-panel:field-backspace"] = function(v) v:field_backspace() end,
  ["search-panel:field-delete"] = function(v) v:field_delete() end,
  ["search-panel:field-move-left"] = function(v) v:field_move(translate.previous_char, false) end,
  ["search-panel:field-move-right"] = function(v) v:field_move(translate.next_char, false) end,
  ["search-panel:field-select-left"] = function(v) v:field_move(translate.previous_char, true) end,
  ["search-panel:field-select-right"] = function(v) v:field_move(translate.next_char, true) end,
  ["search-panel:field-move-word-left"] = function(v) v:field_move(translate.previous_word_start, false) end,
  ["search-panel:field-move-word-right"] = function(v) v:field_move(translate.next_word_end, false) end,
  ["search-panel:field-select-word-left"] = function(v) v:field_move(translate.previous_word_start, true) end,
  ["search-panel:field-select-word-right"] = function(v) v:field_move(translate.next_word_end, true) end,
  ["search-panel:field-home"] = function(v) v:field_home(false) end,
  ["search-panel:field-end"] = function(v) v:field_end(false) end,
  ["search-panel:field-select-home"] = function(v) v:field_home(true) end,
  ["search-panel:field-select-end"] = function(v) v:field_end(true) end,
  ["search-panel:field-move-up"] = function(v) v:field_move(field_prev_line, false) end,
  ["search-panel:field-move-down"] = function(v) v:field_move(field_next_line, false) end,
  ["search-panel:field-select-up"] = function(v) v:field_move(field_prev_line, true) end,
  ["search-panel:field-select-down"] = function(v) v:field_move(field_next_line, true) end,
  ["search-panel:field-newline"] = function(v)
    v:focused_doc():text_input("\n")
    v:after_edit()
  end,
  ["search-panel:field-select-all"] = function(v) v:field_select_all() end,
  ["search-panel:field-copy"] = function(v) v:field_copy() end,
  ["search-panel:field-cut"] = function(v) v:field_cut() end,
  ["search-panel:field-paste"] = function(v) v:field_paste() end,
  ["search-panel:field-undo"] = function(v) v:field_undo() end,
  ["search-panel:field-redo"] = function(v) v:field_redo() end,
})

keymap.add {
  ["ctrl+shift+f"] = "search-panel:toggle",
  ["f3"] = "search-panel:next",
  ["shift+f3"] = "search-panel:previous",
  ["escape"] = "search-panel:hide",
  ["return"] = "search-panel:confirm",
  ["shift+return"] = "search-panel:previous",
  ["tab"] = "search-panel:focus-next",
  ["shift+tab"] = "search-panel:focus-previous",
  ["ctrl+f"] = "search-panel:focus-find",
  ["ctrl+r"] = "search-panel:focus-replace",
  ["ctrl+return"] = "search-panel:replace-one",
  ["ctrl+shift+return"] = "search-panel:field-newline",
  ["up"] = "search-panel:field-move-up",
  ["down"] = "search-panel:field-move-down",
  ["shift+up"] = "search-panel:field-select-up",
  ["shift+down"] = "search-panel:field-select-down",
  ["backspace"] = "search-panel:field-backspace",
  ["delete"] = "search-panel:field-delete",
  ["left"] = "search-panel:field-move-left",
  ["right"] = "search-panel:field-move-right",
  ["shift+left"] = "search-panel:field-select-left",
  ["shift+right"] = "search-panel:field-select-right",
  ["ctrl+left"] = "search-panel:field-move-word-left",
  ["ctrl+right"] = "search-panel:field-move-word-right",
  ["ctrl+shift+left"] = "search-panel:field-select-word-left",
  ["ctrl+shift+right"] = "search-panel:field-select-word-right",
  ["home"] = "search-panel:field-home",
  ["end"] = "search-panel:field-end",
  ["shift+home"] = "search-panel:field-select-home",
  ["shift+end"] = "search-panel:field-select-end",
  ["ctrl+a"] = "search-panel:field-select-all",
  ["ctrl+c"] = "search-panel:field-copy",
  ["ctrl+x"] = "search-panel:field-cut",
  ["ctrl+v"] = "search-panel:field-paste",
  ["ctrl+z"] = "search-panel:field-undo",
  ["ctrl+y"] = "search-panel:field-redo",
}

-- Register the search button on the activity bar (panel selector).
local ok_activitybar, activitybar = pcall(require, "plugins.activitybar")
if ok_activitybar then
  activitybar.add_button({
    id = "search",
    symbol = "L",
    tooltip = "Search",
    show = function()
      activitybar.show_only("search")
      view:show(true)
    end,
    hide = function() view:hide(false) end,
    is_active = function() return view.visible end,
  })
end

return view
