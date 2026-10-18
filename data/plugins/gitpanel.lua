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

config.plugins.gitpanel = common.merge({
  size = 280 * SCALE,
  visible = false,
}, config.plugins.gitpanel)

---@class plugins.gitpanel : core.view
local GitPanel = View:extend()

function GitPanel:__tostring() return "GitPanel" end

function GitPanel:new()
  GitPanel.super.new(self)
  self.scrollable = false
  self.visible = config.plugins.gitpanel.visible
  self.init_size = true
  self.target_size = config.plugins.gitpanel.size
  self.font = style.font:copy(13 * SCALE)
  self.repo = nil
  self.branch = ""
  self.files = {}
  self.selected = 0
  self.hovered = 0
  self.hovered_control = nil
  self.status = "No repository"
  self.status_kind = "idle"
  self.results_scroll = 0
  self.R = {}
end

function GitPanel:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function GitPanel:get_name() return "Git" end

function GitPanel:on_scale_change(new_scale)
  self.font = style.font:copy(13 * new_scale)
end

function GitPanel:set_status(msg, kind)
  self.status = msg
  self.status_kind = kind or "idle"
  core.redraw = true
end

-- Backend ---------------------------------------------------------------------
-- Local git commands run synchronously via io.popen: they finish in
-- milliseconds, while the process API's stream:read("*a") never observes
-- EOF and yields forever. Push/pull may take seconds on the network;
-- GIT_TERMINAL_PROMPT=0 keeps them from hanging on auth prompts.
local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@return boolean ok, string output (stdout+stderr, first line useful on error)
local function git_run(repo, args)
  local parts = { "env", "GIT_TERMINAL_PROMPT=0", "git", "-C", repo }
  for _, a in ipairs(args) do table.insert(parts, a) end
  local cmd = ""
  for i, p in ipairs(parts) do
    cmd = cmd .. (i > 1 and " " or "") .. (i <= 4 and p or sh_quote(p))
  end
  local fp = io.popen(cmd .. " 2>&1", "r")
  if not fp then return false, "could not spawn git" end
  local out = fp:read("*a") or ""
  local ok, _, code = fp:close()
  return ok and code == 0, out
end

local function find_git_root(start)
  local dir = start
  for _ = 1, 25 do
    if not dir then return nil end
    local info = system.get_file_info(dir .. PATHSEP .. ".git")
    if info then return dir end
    local parent = common.dirname(dir)
    if not parent or parent == dir then return nil end
    dir = parent
  end
end

function GitPanel:resolve_repo()
  local start
  local av = core.active_view
  if av and av:is(DocView) and av.doc and av.doc.abs_filename then
    start = common.dirname(av.doc.abs_filename)
  elseif core.last_active_view and core.last_active_view:is(DocView)
      and core.last_active_view.doc and core.last_active_view.doc.abs_filename then
    start = common.dirname(core.last_active_view.doc.abs_filename)
  elseif core.root_project() then
    start = core.root_project().path
  end
  local found = start and find_git_root(start) or nil
  -- sticky fallback: opening scratch tabs (e.g. diffs) must not lose
  -- the repo while it is still the panel's context.
  if found then return found end
  return self.repo
end

local function parse_status(out)
  local files = {}
  for line in out:gmatch("[^\n]+") do
    if #line >= 4 then
      local x, y, path = line:sub(1, 1), line:sub(2, 2), line:sub(4)
      local arrow = path:find(" -> ", 1, true)
      if arrow then path = path:sub(arrow + 4) end
      if path ~= "" then
        local group
        if x == "?" then
          group = "untracked"
        elseif y ~= " " then
          group = "changes"
        else
          group = "staged"
        end
        table.insert(files, { path = path, x = x, y = y, group = group })
      end
    end
  end
  -- stable order: changes, staged, untracked, then path
  local order = { changes = 1, staged = 2, untracked = 3 }
  table.sort(files, function(a, b)
    if order[a.group] ~= order[b.group] then
      return order[a.group] < order[b.group]
    end
    return a.path < b.path
  end)
  return files
end

function GitPanel:refresh()
  local repo = self:resolve_repo()
  if not repo then
    self.repo = nil
    self.branch = ""
    self.files = {}
    self.selected = 0
    self:set_status("No repository", "idle")
    core.redraw = true
    return
  end
  self.repo = repo
  local ok_branch, branch = git_run(repo, { "branch", "--show-current" })
  self.branch = ok_branch and (branch:gsub("%s+$", "")) or ""
  if self.branch == "" then self.branch = "(detached)" end
  local ok, out = git_run(repo,
    { "-c", "core.quotepath=off", "status", "--porcelain=v1", "-uall" })
  if not ok then
    self:set_status("git status failed", "warn")
    core.error("%s", out:gsub("\n", " "):gsub("^%s+", ""):sub(1, 160))
    core.redraw = true
    return
  end
  self.files = parse_status(out)
  self.selected = #self.files > 0 and 1 or 0
  self.results_scroll = 0
  if #self.files == 0 then
    self:set_status("Working tree clean", "info")
  else
    local n_staged, n_changes, n_untracked = 0, 0, 0
    for _, f in ipairs(self.files) do
      if f.group == "staged" then n_staged = n_staged + 1
      elseif f.group == "changes" then n_changes = n_changes + 1
      else n_untracked = n_untracked + 1 end
    end
    self:set_status(string.format("%d staged, %d changes, %d untracked",
      n_staged, n_changes, n_untracked), "info")
  end
  core.redraw = true
end

-- Mutations -----------------------------------------------------------------

function GitPanel:selected_file()
  return self.files[self.selected]
end

function GitPanel:run_git(args, what, after)
  if not self.repo then
    self:set_status("No repository", "idle")
    return
  end
  local ok, out = git_run(self.repo, args)
  if not ok then
    self:set_status(what .. " failed", "warn")
    core.error("%s", out:gsub("\n", " "):gsub("^%s+", ""):sub(1, 200))
    return
  end
  core.log("%s: %s", what, table.concat(args, " "))
  if after then after() end
  self:refresh()
end

function GitPanel:stage_selection()
  local f = self:selected_file()
  if not f then return end
  self:run_git({ "add", "--", f.path }, "Staged " .. f.path)
end

function GitPanel:unstage_selection()
  local f = self:selected_file()
  if not f then return end
  self:run_git({ "restore", "--staged", "--", f.path }, "Unstaged " .. f.path)
end

function GitPanel:discard_selection(confirmed)
  local f = self:selected_file()
  if not f then return end
  if not confirmed then
    core.nag_view:show("Discard changes",
      string.format("Discard all changes in %q?", f.path),
      { { text = "Yes", default_yes = true }, { text = "No", default_no = true } },
      function(item)
        if item.text == "Yes" then self:discard_selection(true) end
      end)
    return
  end
  if f.group == "untracked" then
    local abs = self.repo .. PATHSEP .. f.path
    local ok, err = os.remove(abs)
    if not ok then
      core.error("Couldn't delete %q: %s", f.path, err)
      return
    end
    core.log("Deleted %q", f.path)
    self:refresh()
  else
    self:run_git({ "checkout", "--", f.path }, "Discarded " .. f.path)
  end
end

function GitPanel:commit(message)
  if not message or message == "" then
    core.error("Commit message is empty")
    return
  end
  self:run_git({ "commit", "-m", message }, "Committed")
end

function GitPanel:push()
  self:run_git({ "push" }, "Pushed")
end

function GitPanel:pull()
  self:run_git({ "pull", "--ff-only" }, "Pulled")
end

function GitPanel:diff_selection()
  local f = self:selected_file()
  if not f or not self.repo then return end
  local args = f.group == "staged"
    and { "diff", "--cached", "--", f.path }
    or { "diff", "--", f.path }
  local ok, out = git_run(self.repo, args)
  if not ok then
    core.error("%s", out:gsub("\n", " "):sub(1, 200))
    return
  end
  if out == "" then out = "(no diff)\n" end
  local doc = Doc()
  doc:insert(1, 1, out)
  doc:clean()
  doc.filename = "diff: " .. f.path
  local dv = core.root_view:open_doc(doc)
  dv.doc:set_selection(1, 1)
end

function GitPanel:open_selection()
  local f = self:selected_file()
  if not f or not self.repo then return false end
  local ok = core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(self.repo .. PATHSEP .. f.path))
    core.root_view.root_node:update_layout()
    dv.doc:set_selection(1, 1)
  end)
  return ok
end

-- Visibility ----------------------------------------------------------------

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
    if tree and tree.visible and panel.visible then
      panel.visible = false
      core.redraw = true
    end
  end
end

function GitPanel:show()
  ensure_tree_toggle_wrapped(self)
  local ab_ok, ab = pcall(require, "plugins.activitybar")
  if ab_ok then ab.show_only("git") end
  local tree = get_treeview()
  if tree then tree.visible = false end
  self.visible = true
  core.set_active_view(self)
  self:refresh()
  core.redraw = true
end

function GitPanel:hide(restore_tree)
  if not self.visible then return end
  self.visible = false
  if restore_tree == nil or restore_tree then
    local tree = get_treeview()
    if tree then tree.visible = true end
  end
  core.redraw = true
end

function GitPanel:toggle()
  if self.visible then self:hide(true) else self:show() end
end

-- Layout / drawing -----------------------------------------------------------

function GitPanel:update()
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "gitpanel")
  end
  GitPanel.super.update(self)
end

local function status_color(panel)
  local C = panel.C or style.panel_theme()
  if panel.status_kind == "info" then return C.text end
  if panel.status_kind == "active" then return C.accent end
  if panel.status_kind == "warn" then return C.warn end
  return C.dim
end

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

function GitPanel:layout()
  local font = self.font or style.font
  local pad = style.padding.x
  local x = self.position.x + math.floor(pad / 2)
  local w = self.size.x - pad
  local y = self.position.y + style.padding.y
  local L = {}
  local line_h = font:get_height()
  local btn_h = math.floor(line_h * 1.2) + style.padding.y * 2
  local small_h = math.floor(btn_h * 0.95)

  L.header_h = line_h + style.padding.y
  L.header = { x = x, y = y, w = w, h = L.header_h }
  y = y + L.header_h + 10

  local b3 = math.floor((w - 12) / 3)
  L.btn_push = { x = x, y = y, w = b3, h = small_h }
  L.btn_pull = { x = x + b3 + 6, y = y, w = b3, h = small_h }
  L.btn_refresh = { x = x + (b3 + 6) * 2, y = y, w = w - (b3 + 6) * 2, h = small_h }
  y = y + small_h + 6

  L.btn_commit = { x = x, y = y, w = w, h = btn_h }
  y = y + btn_h + 6

  local b2 = math.floor((w - 6) / 2)
  L.btn_stage = { x = x, y = y, w = b2, h = small_h }
  L.btn_unstage = { x = x + b2 + 6, y = y, w = w - (b2 + 6), h = small_h }
  y = y + small_h + 6
  L.btn_discard = { x = x, y = y, w = b2, h = small_h }
  L.btn_diff = { x = x + b2 + 6, y = y, w = w - (b2 + 6), h = small_h }
  y = y + small_h + 6

  L.status_h = line_h + 4
  L.status = { x = x, y = y, w = w, h = L.status_h }
  y = y + L.status_h + 4

  L.results = { x = self.position.x, y = y, w = self.size.x, h = self.position.y + self.size.y - y }
  L.row_h = line_h + style.padding.y
  return L
end

local function badge_text(f)
  if f.group == "untracked" then return "?" end
  if f.group == "staged" then return f.x ~= " " and f.x or "S" end
  return f.y ~= " " and f.y or "M"
end

function GitPanel:draw()
  if not self.visible then return end
  if self.size.x < 10 then return end
  self.C = style.panel_theme()
  local C = self.C
  local F = self.font or style.font
  self:draw_background(C.panel_bg)
  local L = self:layout()
  self.R = L
  local hovered = self.hovered_control

  -- header: branch band + close
  renderer.draw_rect(L.header.x, L.header.y, L.header.w, L.header.h, C.header_bg)
  local title = "GIT" .. (self.branch ~= "" and ("  " .. self.branch) or "")
  if self.repo then
    title = title .. "  " .. common.basename(self.repo)
  end
  common.draw_text(F, C.header_text, title, "left",
    L.header.x + 6, L.header.y, L.header.w - 24, L.header.h)
  local close = { x = L.header.x + L.header.w - 24, y = L.header.y, w = 24, h = L.header.h }
  self.R.close = close
  if hovered == "close" then
    renderer.draw_rect(close.x, close.y, close.w, close.h, C.highlight)
  end
  common.draw_text(F, C.header_text, "x", "center", close.x, close.y, close.w, close.h)

  draw_button(self, L.btn_push, "Push", false, hovered == "push", false)
  draw_button(self, L.btn_pull, "Pull", false, hovered == "pull", false)
  draw_button(self, L.btn_refresh, "Refresh", false, hovered == "refresh", false)
  draw_button(self, L.btn_commit, "Commit…", false, hovered == "commit", true)
  draw_button(self, L.btn_stage, "Stage", false, hovered == "stage", false)
  draw_button(self, L.btn_unstage, "Unstage", false, hovered == "unstage", false)
  draw_button(self, L.btn_discard, "Discard", false, hovered == "discard", false)
  draw_button(self, L.btn_diff, "Diff", false, hovered == "diff", false)

  common.draw_text(F, status_color(self), self.status, "left",
    L.status.x, L.status.y, L.status.w, L.status.h)

  local res = L.results
  if res.h > 0 then
    core.push_clip_rect(res.x, res.y, res.w, res.h)
    local row_h = L.row_h
    local ox = res.x + math.floor(style.padding.x / 2)
    local first = math.max(1, math.floor(self.results_scroll / row_h) + 1)
    local y = res.y + (first - 1) * row_h - self.results_scroll
    local last_group
    for i = first, #self.files do
      if y > res.y + res.h then break end
      local f = self.files[i]
      if f.group ~= last_group then
        local label = f.group == "changes" and "CHANGES"
          or f.group == "staged" and "STAGED" or "UNTRACKED"
        y = y + 2
        common.draw_text(F, C.dim, label, "left", ox, y, res.w, row_h)
        y = y + row_h
        last_group = f.group
      end
      if y > res.y + res.h then break end
      if i == self.selected then
        renderer.draw_rect(res.x, y, res.w, row_h, C.highlight)
      elseif i == self.hovered then
        local c = { table.unpack(C.highlight) }
        c[4] = 100
        renderer.draw_rect(res.x, y, res.w, row_h, c)
      end
      local badge = badge_text(f)
      local bx = common.draw_text(F, C.accent, badge .. "  ", "left", ox, y, res.w, row_h)
      local preview = i == self.selected and C.match or C.text
      common.draw_text(F, preview, f.path, "left", bx, y, res.x + res.w - bx, row_h)
      y = y + row_h
    end
    if #self.files == 0 then
      common.draw_text(F, C.dim, "No changes", "left", ox, res.y + 4, res.w, row_h)
    end
    core.pop_clip_rect()
    local content_h = #self.files * row_h
    if content_h > res.h and res.h > 0 then
      local bar_h = math.max(20, res.h * res.h / content_h)
      local bar_y = res.y + (self.results_scroll / content_h) * res.h
      bar_y = math.min(bar_y, res.y + res.h - bar_h)
      renderer.draw_rect(res.x + res.w - 5, bar_y, 4, bar_h, C.dim)
    end
  end
end

function GitPanel:ensure_selected_visible()
  local L = self.R.results or self:layout().results
  local row_h = (self.font or style.font):get_height() + style.padding.y
  if self.selected < 1 or L.h <= 0 then self.results_scroll = 0 return end
  local y_rel = (self.selected - 1) * row_h
  if y_rel < self.results_scroll then
    self.results_scroll = y_rel
  elseif y_rel + row_h > self.results_scroll + L.h then
    self.results_scroll = y_rel + row_h - L.h
  end
  local max = math.max(0, #self.files * row_h - L.h)
  self.results_scroll = common.clamp(self.results_scroll, 0, max)
end

-- Mouse ---------------------------------------------------------------------

local function in_rect(x, y, r)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function GitPanel:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return false end
  if button ~= "left" then return true end
  local L = self.R
  if in_rect(x, y, L.close) then self:hide(true) return true end
  if in_rect(x, y, L.btn_push) then self:push() return true end
  if in_rect(x, y, L.btn_pull) then self:pull() return true end
  if in_rect(x, y, L.btn_refresh) then self:refresh() return true end
  if in_rect(x, y, L.btn_commit) then command.perform("git-panel:commit") return true end
  if in_rect(x, y, L.btn_stage) then self:stage_selection() return true end
  if in_rect(x, y, L.btn_unstage) then self:unstage_selection() return true end
  if in_rect(x, y, L.btn_discard) then self:discard_selection(false) return true end
  if in_rect(x, y, L.btn_diff) then self:diff_selection() return true end
  local res = L.results
  if res and x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
    local row_h = L.row_h
    local idx = math.floor((y - res.y + self.results_scroll) / row_h) + 1
    if self.files[idx] then
      self.selected = idx
      self:ensure_selected_visible()
      if clicks >= 2 then self:open_selection() end
      core.redraw = true
    end
    return true
  end
  return true
end

function GitPanel:on_mouse_moved(x, y, ...)
  if not self.visible then return end
  local L = self.R
  self.hovered = 0
  local control = nil
  local function check(name, r)
    if in_rect(x, y, r) then control = name return true end
    return false
  end
  if check("close", L.close) then
  elseif check("push", L.btn_push) then
  elseif check("pull", L.btn_pull) then
  elseif check("refresh", L.btn_refresh) then
  elseif check("commit", L.btn_commit) then
  elseif check("stage", L.btn_stage) then
  elseif check("unstage", L.btn_unstage) then
  elseif check("discard", L.btn_discard) then
  elseif check("diff", L.btn_diff) then
  end
  if not control and L.results then
    local res = L.results
    if x >= res.x and y >= res.y and x < res.x + res.w and y < res.y + res.h then
      local idx = math.floor((y - res.y + self.results_scroll) / L.row_h) + 1
      if self.files[idx] then self.hovered = idx control = "result" end
    end
  end
  if control ~= self.hovered_control then
    self.hovered_control = control
    local tips = {
      close = "Close git panel",
      push = "Push to remote",
      pull = "Pull (fast-forward only)",
      refresh = "Refresh status",
      commit = "Commit staged changes",
      stage = "Stage selected file",
      unstage = "Unstage selected file",
      discard = "Discard changes in selected file",
      diff = "Show diff of selected file",
    }
    if control and tips[control] then
      core.status_view:show_tooltip(tips[control])
    else
      core.status_view:remove_tooltip()
    end
    core.redraw = true
  end
  self.cursor = "arrow"
end

function GitPanel:on_mouse_left()
  self.hovered_control = nil
  core.status_view:remove_tooltip()
end

function GitPanel:on_mouse_wheel(y, x)
  if not self.visible then return false end
  local res = self.R.results
  if not res or res.h <= 0 then return false end
  local mx, my = core.root_view.mouse.x, core.root_view.mouse.y
  if mx >= res.x and my >= res.y and mx < res.x + res.w and my < res.y + res.h then
    local row_h = self.R.row_h or ((self.font or style.font):get_height() + style.padding.y)
    self.results_scroll = self.results_scroll - y * row_h * 3
    local max = math.max(0, #self.files * row_h - res.h)
    self.results_scroll = common.clamp(self.results_scroll, 0, max)
    core.redraw = true
    return true
  end
  return false
end

-- Instantiate ---------------------------------------------------------------

local view = GitPanel()
do
  local node = core.root_view:get_active_node()
  view.node = node:split("left", view, { x = true }, true)
end

-- Commands ------------------------------------------------------------------

local function panel_visible() return view.visible end

command.add(nil, {
  ["git-panel:toggle"] = function() view:toggle() end,
  ["git-panel:show"] = function() view:show() end,
})

command.add(panel_visible, {
  ["git-panel:refresh"] = function() view:refresh() end,
  ["git-panel:push"] = function() view:push() end,
  ["git-panel:pull"] = function() view:pull() end,
  ["git-panel:stage"] = function() view:stage_selection() end,
  ["git-panel:unstage"] = function() view:unstage_selection() end,
  ["git-panel:discard"] = function() view:discard_selection(false) end,
  ["git-panel:diff"] = function() view:diff_selection() end,
  ["git-panel:commit"] = function()
    core.command_view:enter("Commit message", {
      submit = function(message) view:commit(message) end,
    })
  end,
})

command.add(GitPanel, {
  ["git-panel:hide"] = function(v) v:hide(true) end,
  ["git-panel:up"] = function(v)
    if #v.files == 0 then return end
    v.selected = v.selected - 1
    if v.selected < 1 then v.selected = #v.files end
    v:ensure_selected_visible()
    core.redraw = true
  end,
  ["git-panel:down"] = function(v)
    if #v.files == 0 then return end
    v.selected = v.selected + 1
    if v.selected > #v.files then v.selected = 1 end
    v:ensure_selected_visible()
    core.redraw = true
  end,
  ["git-panel:open"] = function(v) v:open_selection() end,
})

keymap.add {
  ["ctrl+shift+g"] = "git-panel:toggle",
  ["escape"] = "git-panel:hide",
  ["up"] = "git-panel:up",
  ["down"] = "git-panel:down",
  ["return"] = "git-panel:open",
}

-- Register the git button on the activity bar (panel selector).
local ok_activitybar, activitybar = pcall(require, "plugins.activitybar")
if ok_activitybar then
  activitybar.add_button({
    id = "git",
    tooltip = "Source Control",
    draw = function(r, active, hovered)
      local color = active and style.accent or style.text
      local cx = math.floor(r.x + r.w / 2)
      local top, bottom = r.y + 9, r.y + r.h - 9
      renderer.draw_rect(cx - 6, top + 2, 2, bottom - top - 4, color)
      renderer.draw_rect(cx - 6, top + 2, 10, 2, color)
      renderer.draw_rect(cx - 2, top, 6, 6, color)
      renderer.draw_rect(cx - 6, bottom - 4, 10, 2, color)
      renderer.draw_rect(cx - 2, bottom - 6, 6, 6, color)
    end,
    show = function()
      activitybar.show_only("git")
      view:show()
    end,
    hide = function() view:hide(false) end,
    is_active = function() return view.visible end,
  })
end

return view
