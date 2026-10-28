-- Max XL end-to-end suite.
--
-- Runs inside the editor: the runner (tests/run-e2e.sh) installs this file
-- as the user init.lua in an isolated LITE_USERDIR, drives the app through
-- its real commands, and checks PASS lines in $E2E_LOG.
-- Paths come from $E2E_FIX (fixtures root); defaults keep ad-hoc runs working.
local core = require "core"
local command = require "core.command"
local style = require "core.style"

local FIX = os.getenv("E2E_FIX") or "/tmp/opencode"
local LOGPATH = os.getenv("E2E_LOG") or (FIX .. "/e2e.log")
local MARKER = FIX .. "/maxxl-marker.log"
local LXTEST = FIX .. "/lxtest"
local GITREPO = FIX .. "/gitrepo"

local function log(msg)
  local fp = io.open(LOGPATH, "a")
  if fp then fp:write(msg .. "\n") fp:close() end
end

local git_panel = nil
do
  local nag_show = core.nag_view.show
  core.nag_view.show = function(self, title, ...)
    local fp = io.open(LOGPATH, "a")
    if fp then
      fp:write("NAG SHOWN: " .. tostring(title) .. "\n" .. debug.traceback("", 2) .. "\n")
      fp:close()
    end
    return nag_show(self, title, ...)
  end
end
core.add_thread(function()
  local last = ""
  for i = 1, 480 do
    coroutine.yield(0.25)
    local ok, cur, title = pcall(function()
      local av = core.active_view
      if av == nil then return "nil", "-" end
      return tostring(av), tostring(av.get_title and av:get_title() or "-")
    end)
    if not ok then cur, title = "watcher-error", tostring(cur) end
    if cur ~= last then
      local fp = io.open(LOGPATH, "a")
      if fp then
        fp:write(string.format("ACTIVE %d: %s title=%s\n", i, cur, title))
        fp:close()
      end
      last = cur
    end
  end
end)
core.add_thread(function()
  for i = 1, 70 do
    coroutine.yield(2)
    local fp = io.open(LOGPATH, "a")
    if fp then fp:write(string.format("HEARTBEAT %d\n", i)) fp:close() end
  end
end)

core.add_thread(function()
  coroutine.yield(2)
  local ok, err = pcall(function()
    -- .max-xl project hook ------------------------------------------------
    local mfp = io.open(MARKER, "r")
    local marker = mfp and mfp:read("*a")
    if mfp then mfp:close() end
    log("litexxl marker: " .. tostring(marker and marker:gsub("\n", "|")))
    assert(marker and #marker > 0, ".max-xl/init.lua did not run")

    -- search panel --------------------------------------------------------
    log("toggle_cmd=" .. tostring(command.map["search-panel:toggle"] ~= nil))
    assert(command.map["search-panel:toggle"], "search-panel commands missing")
    assert(command.perform("search-panel:show"), "show failed")
    local panel
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "SearchPanel" then panel = v break end
    end
    assert(panel, "panel view missing")
    assert(panel.visible, "panel not visible after show")

    -- theme overrides + fallbacks -----------------------------------------
    local t0 = panel:get_theme()
    assert(t0.accent == style.accent, "default accent fallback broken")
    style.search = { accent = { 1, 2, 3, 255 } }
    local t1 = panel:get_theme()
    assert(t1.accent[1] == 1 and t1.accent[2] == 2, "style.search override ignored")
    assert(t1.text == style.text, "text fallback broken")
    style.search = nil
    local t2 = panel:get_theme()
    assert(t2.accent == style.accent, "fallback restore broken")
    log("theme ok")

    -- multiline box --------------------------------------------------------
    core.set_active_view(panel)
    assert(command.perform("search-panel:focus-find"), "focus-find failed")
    panel.scope = "file"
    panel.find_doc:remove(1, 1, math.huge, math.huge)
    panel.find_doc:text_input("world")
    assert(command.perform("search-panel:field-newline"), "newline failed")
    panel.find_doc:text_input("nothing")
    assert(panel:get_find_text() == "world\nnothing", "multiline text mismatch")
    assert(command.perform("search-panel:field-move-up"), "move-up failed")
    local _, _, ml, _ = panel.find_doc:get_selection()
    assert(ml == 1, "move-up did not change line")
    assert(command.perform("search-panel:field-move-down"), "move-down failed")
    panel:refresh("test")
    assert(#panel.results == 1, "expected 1 multiline match, got " .. #panel.results)
    local mm = panel.results[1]
    assert(mm.line == 1 and mm.line2 == 2,
      string.format("multiline span wrong: %d-%d", mm.line, mm.line2))
    panel.replace_doc:remove(1, 1, math.huge, math.huge)
    panel.replace_doc:text_input("WORLD")
    panel.focus = "replace"
    assert(command.perform("search-panel:field-newline"), "newline failed")
    panel.replace_doc:text_input("NOTHING")
    panel.focus = "find"
    panel:replace_all(false)
    local mc = panel.target_view.doc:get_text(1, 1, math.huge, math.huge)
    assert(mc:find("hello foo WORLD", 1, true) and mc:find("NOTHING here", 1, true),
      "multiline replace failed: " .. mc:gsub("\n", "|"):sub(1, 100))
    log("multiline ok")

    -- file scope ------------------------------------------------------------
    panel.find_doc:remove(1, 1, math.huge, math.huge)
    panel.find_doc:text_input("foo")
    panel:refresh("test")
    log("file results=" .. #panel.results .. " status=" .. panel.status)
    assert(#panel.results == 4, "expected 4 matches, got " .. #panel.results)
    assert(panel.selected >= 1, "nothing selected")

    panel:go_next()
    log("after next selected=" .. panel.selected)

    panel.whole_word = true
    panel:refresh("test")
    log("word results=" .. #panel.results)
    assert(#panel.results == 3, "expected 3 whole-word, got " .. #panel.results)
    panel.whole_word = false

    panel.case_sensitive = true
    panel:refresh("test")
    log("case results=" .. #panel.results)
    assert(#panel.results == 3, "expected 3 case-sensitive, got " .. #panel.results)
    panel.case_sensitive = false

    panel:refresh("test")
    panel.replace_doc:remove(1, 1, math.huge, math.huge)
    panel.replace_doc:text_input("bar")
    panel:replace_all(false)
    log("replace status=" .. panel.status)
    local content = panel.target_view.doc:get_text(1, 1, math.huge, math.huge)
    assert(not content:lower():find("foo"), "foo still present")
    log("content=" .. content:gsub("\n", "|"):sub(1, 120))

    -- project scope ----------------------------------------------------------
    panel.find_doc:remove(1, 1, math.huge, math.huge)
    panel.find_doc:text_input("foo")
    panel.scope = "project"
    panel:refresh("test")
    local function wait_for(cond, what)
      for i = 1, 100 do
        if cond() then return end
        coroutine.yield(0.2)
      end
      log("state on timeout: git=" .. tostring(git_panel ~= nil))
      error("timeout waiting for " .. what)
    end
    wait_for(function() return not panel.searching end, "project search")
    log("project results=" .. #panel.results .. " status=" .. panel.status)
    assert(#panel.results == 4, "expected 4 project matches, got " .. #panel.results)

    -- toolbar ------------------------------------------------------------------
    local tb
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "ToolbarView" then tb = v break end
    end
    assert(tb, "toolbar missing")
    local has_search, has_saveall, has_add, has_split = false, false, false, false
    for _, b in ipairs(tb.toolbar_commands) do
      if b.command == "search-panel:toggle" then has_search = true end
      if b.command == "doc:save-all" then has_saveall = true end
      if b.command == "core:add-directory" then has_add = true end
      if b.command == "root:split-right" or b.command == "root:split-down" then has_split = true end
    end
    assert(has_search and has_saveall and has_add, "toolbar buttons missing")
    assert(not has_split, "splits should live on the tab bar, not the toolbar")
    local function count_views() return #core.root_view.root_node:get_children() end
    local before = count_views()
    core.set_active_view(panel.target_view or core.last_active_view)
    do
      local av = core.active_view
      log("pre-split active=" .. tostring(av) .. " title=" ..
        tostring(av.get_title and av:get_title() or "-"))
    end
    if not command.perform("root:split-right") then
      log("split failed with active=" .. tostring(core.active_view))
      error("split-right failed")
    end
    assert(count_views() == before + 1, "split did not add a view")
    assert(command.perform("root:split-down"), "split-down failed")
    assert(count_views() == before + 2, "second split did not add a view")
    assert(command.perform("root:close"), "close failed")
    assert(command.perform("root:close"), "close failed")
    assert(count_views() == before, "close did not restore layout")
    log("toolbar splits ok")
    local Node = require "core.node"
    local empty_node = Node()
    command.map["root:split-right"].perform(empty_node)
    command.map["root:split-down"].perform(empty_node)
    assert(empty_node.type == "leaf" and #empty_node.views == 1, "empty split not refused")
    assert(command.map["workspace:reset-layout"], "reset-layout missing")
    log("split guard ok")
    -- the primary flag must exist exactly once (its loss crashed
    -- get_active_node_default on locked nodes)
    local function count_primaries(n)
      if n.type == "leaf" then return n.is_primary_node and 1 or 0 end
      return count_primaries(n.a) + count_primaries(n.b)
    end
    assert(count_primaries(core.root_view.root_node) == 1, "primary flag count wrong")
    log("primary ok")
    -- no-primary fallback (used to crash with an undefined variable):
    -- with the flag stripped and a locked view focused, the default
    -- node must still resolve to an unlocked leaf
    do
      local flagged = {}
      local function strip(n)
        if n.type == "leaf" then
          if n.is_primary_node then
            table.insert(flagged, n)
            n.is_primary_node = nil
          end
          return
        end
        strip(n.a)
        strip(n.b)
      end
      strip(core.root_view.root_node)
      local treeview
      for _, v in ipairs(core.root_view.root_node:get_children()) do
        if tostring(v) == "TreeView" then treeview = v break end
      end
      assert(treeview, "treeview missing for fallback test")
      local saved_active = core.active_view
      core.set_active_view(treeview)
      local ok, node = pcall(function()
        return core.root_view:get_active_node_default()
      end)
      for _, n in ipairs(flagged) do n.is_primary_node = true end
      core.set_active_view(saved_active)
      assert(ok and node and not node.locked, "no-primary fallback failed")
      log("primary fallback ok")
    end

    -- workspace prune on detached nodes: all-empty collapses to one
    -- leaf, mixed keeps the doc view
    do
      local saved_active = core.active_view
      local wsapi = require "plugins.workspace"
      assert(wsapi.prune_empty_leaves, "prune api missing")
      local Node = require "core.node"
      local DocView = require "core.docview"
      local Doc = require "core.doc"
      local r1 = Node("hsplit")
      r1.a, r1.b = Node(), Node("vsplit")
      r1.b.a, r1.b.b = Node(), Node()
      wsapi.prune_empty_leaves(r1)
      assert(r1.type == "leaf" and #r1.views == 1, "all-empty not collapsed")
      local r2 = Node("hsplit")
      r2.a = Node()
      r2.b = Node()
      local dv = DocView(Doc())
      r2.b:add_view(dv)
      wsapi.prune_empty_leaves(r2)
      assert(r2.type == "leaf", "mixed not collapsed")
      assert(r2.views[1] == dv, "doc view lost")
      core.set_active_view(saved_active)
      log("workspace prune ok")
    end

    -- save-all ------------------------------------------------------------------
    local disk = io.open(LXTEST .. "/notes.txt", "r")
    local orig = disk:read("*a")
    disk:close()
    core.set_active_view(panel.target_view or core.last_active_view)
    assert(command.perform("doc:save-all"), "save-all failed")
    local check = io.open(LXTEST .. "/notes.txt", "r")
    local saved = check:read("*a")
    check:close()
    assert(saved:find("another bar line", 1, true), "save-all did not write buffer")
    local rw = io.open(LXTEST .. "/notes.txt", "w")
    rw:write(orig)
    rw:close()
    log("save-all ok")

    -- add external path -----------------------------------------------------------
    local np = #core.projects
    core.add_project(FIX .. "/lxtest2")
    assert(#core.projects == np + 1, "add project failed")
    local tv
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "TreeView" then tv = v break end
    end
    assert(tv, "treeview missing")
    local found = false
    for item in tv:each_item() do
      if item.abs_filename == FIX .. "/lxtest2" then found = true break end
    end
    assert(found, "new project not listed in treeview")
    core.remove_project(core.projects[#core.projects])
    assert(#core.projects == np, "remove project failed")
    log("add-directory ok")

    -- activity bar ------------------------------------------------------------------
    local abmod = require "plugins.activitybar"
    local by_id = {}
    for _, b in ipairs(abmod.buttons) do by_id[b.id] = b end
    assert(by_id.explorer and by_id.search, "activitybar buttons missing")
    local tv2
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "TreeView" then tv2 = v break end
    end
    assert(tv2, "treeview missing")
    by_id.search.show()
    assert(panel.visible and not tv2.visible, "search show failed")
    by_id.explorer.show()
    assert(tv2.visible and not panel.visible, "explorer show failed")
    log("activitybar ok")

    -- tab bar splits ------------------------------------------------------------------
    core.set_active_view(panel.target_view or core.last_active_view)
    local node = core.root_view:get_active_node()
    local res = node:get_split_reserved_width()
    assert(res > 0, "no split reserved width")
    local sx = node.position.x + node.size.x - res + 2
    local sy = node.position.y + 4
    assert(node:get_split_button_at(sx, sy) == 1, "split-right button miss")
    assert(node:get_split_button_at(sx + res / 2 + 1, sy) == 2, "split-down button miss")
    local bn = count_views()
    core.root_view:on_mouse_pressed("left", sx, sy, 1)
    assert(count_views() == bn + 1, "tab split click failed")
    assert(command.perform("root:close"), "close failed")
    assert(count_views() == bn, "close did not restore layout")
    log("tab splits ok")

    -- tab context menu ------------------------------------------------------
    do
      local View = require "core.view"
      local DocView = require "core.docview"

      assert(command.map["context-menu:show"], "context menu command missing")

      -- right-clicking a tab must open the tab menu, not the doc menu
      local tab_node = core.root_view:get_active_node()
      if #tab_node.views < 2 then
        -- ensure there is more than one tab so the side-closing items exist
        core.root_view:open_doc(core.open_doc())
        tab_node = core.root_view:get_active_node()
      end
      assert(#tab_node.views >= 2, "need multiple tabs for the menu test")
      local tx, ty, tw, th = tab_node:get_tab_rect(1)
      local mx, my = tx + math.floor(tw / 2), ty + math.floor(th / 2)
      -- a right-click on a tab must not be consumed by RootView, otherwise
      -- the keymap never gets a chance to open the menu
      local consumed = core.root_view:on_mouse_pressed("right", mx, my, 1)
      assert(consumed == false, "right-click on a tab was consumed")
      command.perform("context-menu:show", mx, my)
      local cm = core.root_view.context_menu
      assert(cm.visible, "tab context menu did not open")
      local seen = {}
      for _, item in ipairs(cm.items) do
        if item.text then seen[item.text] = true end
      end
      cm:hide()
      assert(seen["Close"], "tab menu missing Close")
      assert(seen["Close to the Left"] or seen["Close to the Right"],
             "tab menu missing close-to-side")
      assert(seen["Duplicate to the Right"], "tab menu missing duplicate-right")
      assert(seen["Duplicate Below"], "tab menu missing duplicate-down")
      log("tab menu ok")

      -- reorder/close commands exercised on a throwaway pane built with
      -- plain views (no unsaved-changes prompts)
      local base = count_views()
      local pane = core.root_view:get_active_node():split("right")
      local a, b, c = View(), View(), View()
      local function reset()
        pane.views = { a, b, c }
        pane:set_active_view(b)
      end

      reset()
      command.perform("tab:move-left", pane, b)
      assert(pane:get_view_idx(b) == 1, "move-left failed")
      command.perform("tab:move-right", pane, b)
      assert(pane:get_view_idx(b) == 2, "move-right failed")

      reset()
      command.perform("tab:close-left", pane, b)
      assert(#pane.views == 2 and pane.views[1] == b, "close-left failed")

      reset()
      command.perform("tab:close-right", pane, b)
      assert(#pane.views == 2 and pane.views[2] == b, "close-right failed")

      reset()
      command.perform("tab:close-others", pane, b)
      assert(#pane.views == 1 and pane.views[1] == b, "close-others failed")

      reset()
      command.perform("tab:close-all", pane, b)
      assert(count_views() == base, "close-all did not collapse pane")
      log("tab commands ok")

      -- duplicate a real document into a new pane
      local doc_node = core.root_view:get_active_node()
      local doc_view
      for _, v in ipairs(doc_node.views) do
        if DocView:is_extended_by(v) then doc_view = v break end
      end
      if doc_view then
        local dbase = count_views()
        command.perform("tab:duplicate-right", doc_node, doc_view)
        assert(count_views() == dbase + 1, "duplicate-right did not split")
        local new_node = core.root_view:get_active_node()
        assert(new_node.active_view.doc == doc_view.doc, "duplicate doc mismatch")
        assert(command.perform("root:close"), "close duplicate failed")
        assert(count_views() == dbase, "duplicate not cleaned up")
      end
      log("tab duplicate ok")
    end

    -- git ------------------------------------------------------------------
    local git
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "GitPanel" then git = v break end
    end
    assert(git, "git panel missing")
    git_panel = git
    local gitbtn
    for _, b in ipairs(abmod.buttons) do if b.id == "git" then gitbtn = b break end end
    assert(gitbtn, "git activity button missing")
    core.root_view:open_doc(core.open_doc(GITREPO .. "/f.txt"))
    gitbtn.show()
    assert(git.visible, "git not visible")
    wait_for(function() return git.repo ~= nil and #git.files == 2 end, "initial status")
    assert(git.repo == GITREPO, "wrong repo: " .. tostring(git.repo))
    assert(git.branch ~= "", "no branch detected")
    log("git status ok: " .. git.branch .. " / " .. git.status)
    local fidx
    for i, f in ipairs(git.files) do if f.path == "f.txt" then fidx = i break end end
    assert(fidx, "f.txt not listed")
    git.selected = fidx
    git:stage_selection()
    wait_for(function()
      for _, f in ipairs(git.files) do
        if f.path == "f.txt" and f.group == "staged" then return true end
      end
      return false
    end, "stage")
    log("git stage ok")
    git:diff_selection()
    local found_diff = false
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if v.doc and v.doc.filename == "diff: f.txt" then found_diff = true break end
    end
    assert(found_diff, "diff tab missing")
    log("git diff ok")
    git:commit("xxl e2e")
    wait_for(function() return #git.files == 1 end, "commit")
    log("git commit ok")
    local fp = io.open(GITREPO .. "/f.txt", "w")
    fp:write("line one\ntampered\n")
    fp:close()
    git:refresh()
    wait_for(function() return #git.files == 2 end, "re-dirty")
    for i, f in ipairs(git.files) do if f.path == "f.txt" then git.selected = i break end end
    git:discard_selection(true)
    wait_for(function()
      for _, f in ipairs(git.files) do
        if f.path == "f.txt" then return false end
      end
      return true
    end, "discard")
    local cf = io.open(GITREPO .. "/f.txt", "r")
    local cc = cf:read("*a")
    cf:close()
    assert(cc:find("line two changed", 1, true), "discard did not restore")
    log("git discard ok")

    -- problems ------------------------------------------------------------------
    local bf = io.open(LXTEST .. "/zz-bad.lua", "w")
    bf:write("local x = \n")
    bf:close()
    local problems = require "plugins.problems"
    local pbtn
    for _, b in ipairs(abmod.buttons) do if b.id == "problems" then pbtn = b break end end
    assert(pbtn, "problems activity button missing")
    local badview = core.root_view:open_doc(core.open_doc(LXTEST .. "/zz-bad.lua"))
    core.set_active_view(badview)
    assert(command.perform("doc:save"), "save bad.lua failed")
    local found_bad = false
    for _, d in ipairs(problems.get()) do
      if d.file:find("zz%-bad%.lua$") then
        found_bad = true
        assert(d.severity == "error" and d.line >= 1 and d.message ~= "", "bad diagnostic shape")
      end
    end
    assert(found_bad, "lua diagnostic missing")
    log("problems save-hook ok")
    pbtn.show()
    local ppanel
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if tostring(v) == "ProblemsPanel" then ppanel = v break end
    end
    assert(ppanel and ppanel.visible and not tv2.visible, "problems show failed")
    log("problems show ok")
    core.set_active_view(badview)
    badview.doc:remove(1, 1, math.huge, math.huge)
    badview.doc:text_input("local x = 42\n")
    assert(command.perform("doc:save"), "save fixed failed")
    for _, d in ipairs(problems.get()) do
      assert(not d.file:find("zz%-bad%.lua$"), "diagnostic not cleared")
    end
    log("problems clear ok")

    -- console ----------------------------------------------------------------------
    local cview = require "plugins.console"
    assert(cview and tostring(cview) == "ConsoleView", "console missing")
    local cbtn
    for _, b in ipairs(abmod.buttons) do if b.id == "console" then cbtn = b break end end
    assert(cbtn, "console activity button missing")
    cbtn.show()
    assert(cview:is_open(), "console not visible")
    cview:run("echo hello-console")
    wait_for(function()
      return cview:get_text():find("hello-console", 1, true) ~= nil
    end, "console output")
    wait_for(function() return not cview:is_running() end, "console exit")
    log("console run ok")
    cview:clear()
    assert(cview:get_text() == "", "clear failed")
    cview:run("sleep 30")
    coroutine.yield(1)
    assert(cview:is_running(), "sleep not running")
    cview:kill()
    coroutine.yield(0.5)
    assert(not cview:is_running(), "console kill failed")
    log("console kill ok")

    -- actions plugin (status bar buttons) --------------------------------------------
    local actions = require "plugins.actions"
    assert(actions and actions.reload and actions.run, "actions plugin missing")
    assert(command.map["actions:reload"], "actions:reload command missing")
    assert(command.map["actions:run"], "actions:run command missing")
    do
      local proj = core.root_project().path
      local adir = proj .. "/.max-xl"
      system.mkdir(adir)
      local afp = io.open(adir .. "/actions.lua", "w")
      assert(afp, "cannot write actions.lua")
      afp:write([[
return {
  { label = "e2e-hello", command = "echo e2e-action-ok" },
  { label = "e2e-right", command = "echo x", align = "right" },
}
]])
      afp:close()
      actions.reload()
      local item = core.status_view:get_item("actions:e2e-hello")
      assert(item, "action button not registered on the status bar")
      assert(item.background_color, "action button has no background")
      local ritem = core.status_view:get_item("actions:e2e-right")
      assert(ritem, "right-aligned action button missing")
      -- a shell action must be captured by the console
      cview:clear()
      actions.run({ label = "e2e-hello", command = "echo e2e-action-ok" })
      wait_for(function()
        return cview:get_text():find("e2e-action-ok", 1, true) ~= nil
      end, "action output")
      wait_for(function()
        return cview:get_text():find("%[exit 0%]") ~= nil
      end, "action exit status")
      assert(cview:get_text():find("$ echo e2e-action-ok", 1, true),
        "action command not echoed")
      -- a Lua action must run without error
      local okrun = pcall(actions.run, {
        label = "e2e-lua", command = function() end,
      })
      assert(okrun, "lua action failed")
      -- misconfigured actions must not raise
      pcall(actions.run, { label = "e2e-none" })
      os.remove(adir .. "/actions.lua")
      actions.reload()
    end
    log("actions ok")

    -- terminal -----------------------------------------------------------------------
    local tview = require "plugins.terminal"
    assert(tview and tostring(tview) == "TerminalView", "terminal missing")
    tview:show()
    assert(tview:is_open(), "terminal not open")
    local tnode = core.root_view.root_node:get_node_for_view(tview)
    local tparent = tnode and tnode:get_parent_node(core.root_view.root_node)
    assert(tparent and tparent.type == "vsplit", "terminal not in horizontal split")
    log("terminal placement ok")
    assert(tview:is_running(), "show did not autostart shell")
    assert(tview:start({ "sh", "-c", "echo pty-hello; exit 42" }), "terminal start failed")
    wait_for(function()
      return tview:get_text():find("pty%-hello", 1) ~= nil
    end, "terminal output")
    wait_for(function() return not tview:is_running() end, "terminal exit")
    assert(tview.exit_code == 42, "wrong exit code: " .. tostring(tview.exit_code))
    log("terminal shell ok")
    tview:resize(100, 30)
    assert(tview.cols == 100 and tview.rows == 30, "resize failed")
    assert(tview:start({ "sleep", "30" }), "terminal sleep failed")
    coroutine.yield(1)
    log("sleep state: running=" .. tostring(tview:is_running())
      .. " code=" .. tostring(tview.exit_code))
    assert(tview:is_running(), "sleep not running")
    tview:kill()
    coroutine.yield(0.5)
    assert(not tview:is_running(), "terminal kill failed")
    log("terminal kill ok")

    -- terminal parser: hostile input never freezes the view ------------------
    local tv2 = require "plugins.terminal"
    tv2.lines = {}
    for _ = 1, 24 do table.insert(tv2.lines, tv2:blank_row()) end
    tv2.cx, tv2.cy, tv2.carry, tv2.cols, tv2.rows = 1, 1, "", 80, 24
    tv2.region_top, tv2.region_bottom = 1, 24
    tv2:parse("a\x9bb\x80\xffc")
    assert(tv2:get_text():sub(1, 1) == "a", "parser dropped text")
    assert(tv2:get_text():find("c", 1, true), "parser dropped tail")
    assert(#tv2.carry < 100, "carry runaway on bad bytes")
    tv2:parse("\x1b[3")
    tv2:parse("1mX")
    assert(tv2:get_text():find("X", 1, true), "split CSI broke")
    tv2:parse("a\xe2\x82")
    assert(tv2.carry ~= "", "split utf8 not carried")
    tv2:parse("\xacb")
    assert(tv2:get_text():find("b", 1, true), "split utf8 broke")
    tv2:parse("\x1b[" .. string.rep("1;", 3000))
    assert(#tv2.carry <= 4096, "unterminated sequence runaway")
    log("terminal parser ok")

    -- terminal scroll regression: with a short buffer, linefeed must
    -- advance to a fresh row, never scroll-overwrite the current one
    -- (this exact shape once glued output onto the typed row).
    do
      local tv3 = require "plugins.terminal"
      tv3.lines = { tv3:blank_row() }
      tv3.cx, tv3.cy, tv3.carry, tv3.cols, tv3.rows = 1, 1, "", 80, 7
      tv3.region_top, tv3.region_bottom = 1, 7
      tv3:parse("row1\r\nrow2\r\nPROMPT> ")
      tv3:parse("\rPROMPT> echo hi")
      tv3:parse("\r\nOUT\r\nPROMPT2> ")
      local rows = {}
      for line in (tv3:get_text() .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then table.insert(rows, line) end
      end
      assert(rows[3] == "PROMPT> echo hi", "typed row wrong: " .. tostring(rows[3]))
      assert(rows[4] == "OUT", "output row wrong: " .. tostring(rows[4]))
      assert(rows[5] == "PROMPT2>", "prompt row wrong: " .. tostring(rows[5]))
      assert(tv3.cy == 5, "cursor row wrong: " .. tostring(tv3.cy))
    end
    log("terminal scroll ok")

    -- resize keeps the cursor on the same visible row ----------------------
    do
      local tv4 = require "plugins.terminal"
      tv4.lines = {}
      for i = 1, 10 do
        local row = tv4:blank_row()
        row.ch[1] = tostring(i % 10)
        table.insert(tv4.lines, row)
      end
      tv4.cx, tv4.cy, tv4.carry, tv4.cols, tv4.rows = 1, 10, "", 80, 10
      tv4.region_top, tv4.region_bottom = 1, 10
      tv4:resize(80, 5)
      assert(tv4.cy == 10, "shrink lost cursor: " .. tostring(tv4.cy))
      assert(tv4.lines[10].ch[1] == "0", "shrink moved content")
      tv4:resize(80, 10)
      assert(tv4.cy == 10, "grow moved cursor: " .. tostring(tv4.cy))
      tv4.cx, tv4.cy = 1, 8
      tv4:resize(80, 5)
      -- mid-screen cursor lands on the visible bottom (where fish clamps
      -- it too), never stranded above the viewport
      assert(tv4.cy == 10, "mid shrink broke: " .. tostring(tv4.cy))
    end
    log("terminal resize ok")

    -- scroll region tracks resizes only when full --------------------------------
    do
      local tv5 = require "plugins.terminal"
      tv5.lines = {}
      for _ = 1, 10 do table.insert(tv5.lines, tv5:blank_row()) end
      tv5.cx, tv5.cy, tv5.carry, tv5.cols, tv5.rows = 1, 10, "", 80, 10
      tv5.region_top, tv5.region_bottom = 1, 10
      tv5:resize(80, 5)
      assert(tv5.region_top == 1 and tv5.region_bottom == 5,
        "full region did not shrink")
      tv5:resize(80, 12)
      assert(tv5.region_top == 1 and tv5.region_bottom == 12,
        "full region did not expand")
      tv5.region_top, tv5.region_bottom = 3, 7
      tv5:resize(80, 5)
      assert(tv5.region_top == 3 and tv5.region_bottom == 5,
        "custom region clamp wrong")
      tv5:resize(80, 12)
      -- clamped regions stay clamped (apps like vim re-set them
      -- explicitly after SIGWINCH); only full regions expand
      assert(tv5.region_top == 3 and tv5.region_bottom == 5,
        "custom region must stay put")
    end
    log("terminal region ok")

    -- erase-in-display must not wipe text before the cursor -------------------
    -- (fish repaints its prompt and then sends ESC[J on SIGWINCH)
    do
      local tv6 = require "plugins.terminal"
      tv6.lines = {}
      for _ = 1, 5 do table.insert(tv6.lines, tv6:blank_row()) end
      tv6.cx, tv6.cy, tv6.carry, tv6.cols, tv6.rows = 1, 5, "", 80, 5
      tv6.region_top, tv6.region_bottom = 1, 5
      local function row_text(row)
        local t = {}
        for i = 1, #row.ch do t[i] = row.ch[i] end
        return table.concat(t)
      end
      tv6:parse("PROMPT> ")
      local line = tv6.cy
      tv6:parse("\27[J") -- ED0: erase from cursor to end of screen
      assert(row_text(tv6.lines[line]) == "PROMPT> ",
        "ED0 erased text before the cursor: " .. row_text(tv6.lines[line]))
      -- ED0 must still erase what sits after the cursor on the same line
      tv6:parse("\rAB\27[J")
      assert(row_text(tv6.lines[line]) == "AB",
        "ED0 kept a stale tail: " .. row_text(tv6.lines[line]))
      -- ED1 erases up to the cursor but keeps the tail
      tv6:parse("\rTAIL")
      tv6.cx = 3
      tv6:parse("\27[1J")
      assert(tv6.lines[line].ch[4] == "L",
        "ED1 erased past the cursor: " .. row_text(tv6.lines[line]))
    end
    log("terminal erase ok")

    -- terminal font, padding, selection and scrollback ----------------------
    do
      local tv7 = require "plugins.terminal"
      local pcfg = require("core.config").plugins.terminal
      local old_font, old_size, old_opts = pcfg.font, pcfg.font_size, pcfg.font_options
      pcfg.font = DATADIR .. "/fonts/JetBrainsMono-Regular.ttf"
      pcfg.font_size = 17
      pcfg.font_options = { antialiasing = "grayscale", hinting = "full" }
      local tfont = tv7:get_font()
      assert(tfont and tfont ~= style.code_font, "terminal font not loaded from path")
      assert(tfont:get_height() > 0, "terminal font has no height")
      -- missing glyphs (✓/✗ in fish prompts) are served by a fallback group
      local old_fallback = pcfg.font_fallback
      pcfg.font_fallback = { pcfg.font }
      local grouped = tv7:get_font()
      local paths = grouped and grouped:get_path()
      assert(type(paths) == "table" and #paths == 2,
        "font fallback group not created: " .. tostring(paths))
      pcfg.font_fallback = false
      local plain = tv7:get_font()
      assert(type(plain) == "userdata", "font fallback could not be disabled")
      pcfg.font_fallback = old_fallback
      pcfg.font, pcfg.font_size, pcfg.font_options = old_font, old_size, old_opts
      local padx, pady = tv7:get_padding()
      assert(padx > 0 and pady > 0, "terminal padding default missing")
      log("terminal font/padding ok")

      tv7.lines = {}
      for i = 1, 300 do
        local row = tv7:blank_row()
        local text = "line-" .. i
        for c = 1, #text do row.ch[c] = text:sub(c, c) end
        table.insert(tv7.lines, row)
      end
      tv7.cx, tv7.cy = 1, 300
      tv7.view_top, tv7.sel = nil, nil
      local max_top = tv7:get_max_view_top()
      assert(max_top > 1, "scrollback not scrollable: " .. max_top)
      assert(tv7:get_view_top() == max_top, "view not following the tail")
      tv7:scroll_by(5)
      assert(tv7.view_top == max_top - 5,
        "scroll_by wrong top: " .. tostring(tv7.view_top))
      tv7:scroll_to_bottom()
      assert(tv7.view_top == nil, "scroll_to_bottom did not follow tail")
      tv7:set_view_top(1)
      assert(tv7:get_view_top() == 1, "scroll_to_top failed")
      tv7:scroll_to_bottom()
      log("terminal scrollback ok")

      -- forward selection across lines trims trailing spaces
      tv7.sel = { 3, 3, 4, 2 }
      assert(tv7:get_selection_text() == "ne-3\nli",
        "selection text wrong: " .. string.format("%q", tv7:get_selection_text()))
      local from, to = tv7:get_selection_span(4)
      assert(from == 1 and to == 2, "selection span wrong")
      -- backward drags must yield the same text
      tv7.sel = { 4, 2, 3, 3 }
      assert(tv7:get_selection_text() == "ne-3\nli", "reverse selection text wrong")
      tv7:select_word(7, 2)
      assert(tv7:get_selection_text() == "line-7",
        "word selection wrong: " .. string.format("%q", tv7:get_selection_text()))
      tv7:select_line(9)
      assert(tv7:get_selection_text() == "line-9", "line selection wrong")
      tv7:select_all()
      local all = tv7:get_selection_text()
      assert(all:find("line%-1\n", 1) and all:find("line%-300$"),
        "select all wrong")
      tv7:select_word(10, 2)
      assert(tv7:copy_selection(), "copy_selection failed")
      assert(system.get_clipboard() == "line-10", "clipboard content wrong")
      log("terminal selection ok")

      -- new output must not yank a scrolled-up view, typing must return to tail
      tv7:set_view_top(10)
      local before = tv7.view_top
      tv7:parse("Z")
      assert(tv7.view_top == before, "output moved the scrolled view")
      tv7:on_text_input("q")
      assert(tv7.view_top == nil, "typing did not return to the tail")
      log("terminal follow-tail ok")
    end

    panel:hide(true)
    assert(not panel.visible, "panel still visible")
    log("ALL E2E PASS")
  end)
  if not ok then log("E2E FAIL: " .. tostring(err)) end
  os.exit(ok and 0 or 1)
end)
