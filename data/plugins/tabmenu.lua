-- mod-version:4
-- max-xl: tab context menu.
--
-- Right-clicking a tab opens a menu with per-tab actions:
--   close this / others / to the left / to the right / all
--   duplicate the file to the right or below
--   reorder the tab
--   doc helpers (save, copy path, reveal in file tree)
--
-- Right-clicks anywhere else keep the stock context menu behaviour: this
-- plugin wraps the existing `context-menu:show` command and only takes over
-- when the pointer is over a tab.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local ContextMenu = require "core.contextmenu"
local DocView = require "core.docview"


local function is_doc(view)
  return type(view) == "table" and DocView:is_extended_by(view)
end


local function has_file(view)
  return is_doc(view) and view.doc.abs_filename ~= nil
end


local function has_treeview()
  return (pcall(require, "plugins.treeview"))
end


-- Closing -------------------------------------------------------------------

-- Remove views directly, bypassing try_close: the caller already handled the
-- unsaved-changes prompt through core.confirm_close_docs.
local function remove_views(node, views)
  for _, view in ipairs(views) do
    if node.type == "leaf" and node:get_view_idx(view) then
      node:remove_view(core.root_view.root_node, view)
    end
  end
end


local function close_views(node, views)
  -- snapshot: remove_view mutates node.views, which may be the same table
  views = { table.unpack(views) }
  if #views == 0 then return end
  local docs, seen = {}, {}
  for _, view in ipairs(views) do
    if is_doc(view) and not seen[view.doc] then
      seen[view.doc] = true
      docs[#docs + 1] = view.doc
    end
  end
  if #docs > 0 then
    core.confirm_close_docs(docs, remove_views, node, views)
  else
    remove_views(node, views)
  end
end


-- Duplicating ---------------------------------------------------------------

-- Split the node and show the same document in the new pane.
local function duplicate(node, view, dir)
  node:set_active_view(view)
  local new_node = node:split(dir)
  new_node:add_view(DocView(view.doc))
end


-- Menu ----------------------------------------------------------------------

local function tab_items(node, view)
  local idx = node:get_view_idx(view)
  local n = #node.views
  local items = {}

  local function add(text, cmd)
    items[#items + 1] = { text = text, command = cmd }
  end
  local function divider()
    if #items > 0 and items[#items] ~= ContextMenu.DIVIDER then
      items[#items + 1] = ContextMenu.DIVIDER
    end
  end

  add("Close", "tab:close")
  if n > 1 then
    add("Close Others", "tab:close-others")
  end
  if idx and idx > 1 then
    add("Close to the Left", "tab:close-left")
  end
  if idx and idx < n then
    add("Close to the Right", "tab:close-right")
  end
  add("Close All", "tab:close-all")

  if is_doc(view) then
    divider()
    add("Duplicate to the Right", "tab:duplicate-right")
    add("Duplicate Below", "tab:duplicate-down")
  end

  if idx and (idx > 1 or idx < n) then
    divider()
    if idx > 1 then add("Move Tab Left", "tab:move-left") end
    if idx < n then add("Move Tab Right", "tab:move-right") end
  end

  if has_file(view) then
    divider()
    if view.doc:is_dirty() then
      add("Save", "tab:save")
    end
    add("Copy Path", "tab:copy-path")
    add("Copy Relative Path", "tab:copy-relative-path")
    if has_treeview() then
      add("Reveal in File Tree", "tab:reveal")
    end
  end

  return items
end


-- Commands ------------------------------------------------------------------

-- Every tab command receives (node, view) from the context menu arguments.
local function tab_predicate(extra)
  return function(node, view)
    if type(node) ~= "table" or type(view) ~= "table" then return false end
    if not node.views or not node:get_view_idx(view) then return false end
    if extra and not extra(node, view) then return false end
    return true, node, view
  end
end


command.add(tab_predicate(), {
  ["tab:close"] = function(node, view)
    node:close_view(core.root_view.root_node, view)
  end,

  ["tab:close-all"] = function(node)
    close_views(node, node.views)
  end
})


command.add(tab_predicate(function(node)
  return #node.views > 1
end), {
  ["tab:close-others"] = function(node, view)
    local views = {}
    for _, v in ipairs(node.views) do
      if v ~= view then views[#views + 1] = v end
    end
    close_views(node, views)
  end
})


command.add(tab_predicate(function(node, view)
  return node:get_view_idx(view) > 1
end), {
  ["tab:close-left"] = function(node, view)
    local idx = node:get_view_idx(view)
    local views = {}
    for i = 1, idx - 1 do views[#views + 1] = node.views[i] end
    close_views(node, views)
  end,

  ["tab:move-left"] = function(node, view)
    local idx = node:get_view_idx(view)
    table.remove(node.views, idx)
    table.insert(node.views, idx - 1, view)
  end
})


command.add(tab_predicate(function(node, view)
  return node:get_view_idx(view) < #node.views
end), {
  ["tab:close-right"] = function(node, view)
    local idx = node:get_view_idx(view)
    local views = {}
    for i = idx + 1, #node.views do views[#views + 1] = node.views[i] end
    close_views(node, views)
  end,

  ["tab:move-right"] = function(node, view)
    local idx = node:get_view_idx(view)
    table.remove(node.views, idx)
    table.insert(node.views, idx + 1, view)
  end
})


command.add(tab_predicate(function(_, view)
  return is_doc(view)
end), {
  ["tab:duplicate-right"] = function(node, view)
    duplicate(node, view, "right")
  end,

  ["tab:duplicate-down"] = function(node, view)
    duplicate(node, view, "down")
  end
})


command.add(tab_predicate(function(_, view)
  return is_doc(view) and view.doc:is_dirty()
end), {
  ["tab:save"] = function(node, view)
    node:set_active_view(view)
    command.perform("doc:save")
  end
})


command.add(tab_predicate(function(_, view)
  return has_file(view)
end), {
  ["tab:copy-path"] = function(_, view)
    system.set_clipboard(view.doc.abs_filename)
  end,

  ["tab:copy-relative-path"] = function(_, view)
    local project = core.root_project()
    local path = view.doc.abs_filename
    if project and project.path then
      path = common.relative_path(project.path, path)
    end
    system.set_clipboard(path)
  end
})


command.add(tab_predicate(function(_, view)
  return has_file(view) and has_treeview()
end), {
  ["tab:reveal"] = function(_, view)
    local ok_bar, activitybar = pcall(require, "plugins.activitybar")
    if ok_bar and type(activitybar) == "table" and activitybar.show_only then
      activitybar.show_only("explorer")
    end
    local ok_tree, treeview = pcall(require, "plugins.treeview")
    if ok_tree and type(treeview) == "table" then
      treeview.visible = true
      treeview:set_selection_to_path(view.doc.abs_filename, true, true)
    end
  end
})


-- Hook the context menu -----------------------------------------------------

local original = command.map["context-menu:show"]

if original then
  local function tab_menu_predicate(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
      x, y = core.root_view.mouse.x, core.root_view.mouse.y
    end
    if type(x) ~= "number" or type(y) ~= "number" then return false end

    local node = core.root_view.root_node:get_child_overlapping_point(x, y)
    if node then
      local idx = node:get_tab_overlapping_point(x, y)
      local view = idx and node.views[idx]
      if view then
        return true, x, y, { items = tab_items(node, view) }, node, view
      end
    end

    -- not a tab: keep the stock behaviour
    return original.predicate(x, y)
  end

  command.map["context-menu:show"] = {
    predicate = tab_menu_predicate,
    perform = original.perform
  }
end


return { tab_items = tab_items }
