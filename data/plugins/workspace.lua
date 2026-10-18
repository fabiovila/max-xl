-- mod-version:4
local core = require "core"
local common = require "core.common"
local DocView = require "core.docview"
local LogView = require "core.logview"
local storage = require "core.storage"

local STORAGE_MODULE = "ws"

-- Set by reset-layout so the restart it triggers doesn't re-save
-- the layout we just dropped.
local suppress_next_save = false

local function workspace_keys_for(project_dir)
  local basename = common.basename(project_dir)
  return coroutine.wrap(function()
    for _, key in ipairs(storage.keys(STORAGE_MODULE) or {}) do
      if key:sub(1, #basename) == basename then
        local id = tonumber(key:sub(#basename + 1):match("^-(%d+)$"))
        if id then
          coroutine.yield(key, id)
        end
      end
    end
  end)
end


local function consume_workspace(project_dir)
  for key, id in workspace_keys_for(project_dir) do
    local workspace = storage.load(STORAGE_MODULE, key)
    if workspace and workspace.path == project_dir then
      storage.clear(STORAGE_MODULE, key)
      return workspace
    end
  end
end


local function has_no_locked_children(node)
  if node.locked then return false end
  if node.type == "leaf" then return true end
  return has_no_locked_children(node.a) and has_no_locked_children(node.b)
end


local function get_unlocked_root(node)
  if node.type == "leaf" then
    return not node.locked and node
  end
  if has_no_locked_children(node) then
    return node
  end
  return get_unlocked_root(node.a) or get_unlocked_root(node.b)
end


local function save_view(view)
  local mt = getmetatable(view)
  if mt == DocView then
    return {
      type = "doc",
      active = (core.active_view == view),
      filename = view.doc.filename,
      selection = { view.doc:get_selection() },
      scroll = { x = view.scroll.to.x, y = view.scroll.to.y },
      crlf = view.doc.crlf,
      text = view.doc.new_file and view.doc:get_text(1, 1, math.huge, math.huge)
    }
  end
  if mt == LogView then return end
  for name, mod in pairs(package.loaded) do
    if mod == mt then
      return {
        type = "view",
        active = (core.active_view == view),
        module = name,
        scroll = { x = view.scroll.to.x, y = view.scroll.to.y, to = { x = view.scroll.to.x, y = view.scroll.to.y } },
      }
    end
  end
end


local function load_view(t)
  if t.type == "doc" then
    local dv
    if not t.filename then
      -- document not associated to a file
      dv = DocView(core.open_doc())
    else
      -- we have a filename, try to read the file
      local ok, doc = pcall(core.open_doc, t.filename)
      if ok then
        dv = DocView(doc)
      end
    end
    if dv and dv.doc then
      if dv.doc.new_file and t.text then
        dv.doc:insert(1, 1, t.text)
        dv.doc.crlf = t.crlf
      end
      dv.doc:set_selection(table.unpack(t.selection))
      dv.last_line1, dv.last_col1, dv.last_line2, dv.last_col2 = dv.doc:get_selection()
      dv.scroll.x, dv.scroll.to.x = t.scroll.x, t.scroll.x
      dv.scroll.y, dv.scroll.to.y = t.scroll.y, t.scroll.y
    end
    return dv
  end
  return require(t.module)()
end


local function save_node(node)
  local res = {}
  res.type = node.type
  if node.type == "leaf" then
    res.views = {}
    for _, view in ipairs(node.views) do
      local t = save_view(view)
      if t then
        table.insert(res.views, t)
        if node.active_view == view then
          res.active_view = #res.views
        end
      end
    end
  else
    res.divider = node.divider
    res.a = save_node(node.a)
    res.b = save_node(node.b)
  end
  return res
end


local function load_node(node, t)
  if t.type == "leaf" then
    local res
    local active_view
    for i, v in ipairs(t.views) do
      local view = load_view(v)
      if view then
        if v.active then res = view end
        node:add_view(view)
        if t.active_view == i then
          active_view = view
        end
        if not view:is(DocView) then
          view.scroll = v.scroll
        end
      end
    end
    if active_view then
      node:set_active_view(active_view)
    end
    return res
  else
    node:split(t.type == "hsplit" and "right" or "down")
    node.divider = t.divider
    local res1 = load_node(node.a, t.a)
    local res2 = load_node(node.b, t.b)
    return res1 or res2
  end
end


local function save_directories()
  local project_dir = core.root_project().path
  local dir_list = {}
  for i = 2, #core.projects do
    dir_list[#dir_list + 1] = common.relative_path(project_dir, core.projects[i].path)
  end
  return dir_list
end


local function is_empty_leaf(node)
  if node.type ~= "leaf" or node.locked then return false end
  if #node.views == 0 then return true end
  return #node.views == 1 and node.views[1]:is(require "core.emptyview")
end


-- Collapses splits whose leaves hold nothing but empty views, bottom-up.
-- A restored session therefore never shows bare logo-splits: no open
-- documents means a single editor, no matter what was saved.
local function prune_empty_leaves(node)
  if node.type == "leaf" then return end
  prune_empty_leaves(node.a)
  prune_empty_leaves(node.b)
  local a_empty, b_empty = is_empty_leaf(node.a), is_empty_leaf(node.b)
  if a_empty and b_empty then
    node:consume(require("core.node")())
    node:set_active_view(node.active_view)
  elseif a_empty then
    node:consume(node.b)
    node:set_active_view(node.active_view)
  elseif b_empty then
    node:consume(node.a)
    node:set_active_view(node.active_view)
  end
end


local function save_workspace()
  if suppress_next_save then
    suppress_next_save = false
    return
  end
  local project_dir = common.basename(core.root_project().path)
  local id_list = {}
  for filename, id in workspace_keys_for(project_dir) do
    id_list[id] = true
  end
  local id = 1
  while id_list[id] do
    id = id + 1
  end
  local root = get_unlocked_root(core.root_view.root_node)
  storage.save(STORAGE_MODULE, project_dir .. "-" .. id, { path = core.root_project().path, documents = save_node(root), directories = save_directories() })
end


local function load_workspace()
  local workspace = consume_workspace(core.root_project().path)
  if workspace then
    local root = get_unlocked_root(core.root_view.root_node)
    local active_view = load_node(root, workspace.documents)
    prune_empty_leaves(get_unlocked_root(core.root_view.root_node))
    if active_view then
      core.set_active_view(active_view)
    else
      -- all-empty restore: point at the live survivor instead of a
      -- discarded empty view
      local primary = core.root_view:get_primary_node()
      if primary and primary.active_view then
        core.set_active_view(primary.active_view)
      end
    end
    for i, dir_name in ipairs(workspace.directories) do
      core.add_project(system.absolute_path(dir_name))
    end
  end
end


local run = core.run

function core.run(...)
  if #core.docs == 0 then
    core.try(load_workspace)

    local set_project = core.set_project
    function core.set_project(project)
      core.try(save_workspace)
      local project = set_project(project)
      core.try(load_workspace)
      return project
    end
    local exit = core.exit
    function core.exit(quit_fn, force)
      if force then core.try(save_workspace) end
      exit(quit_fn, force)
    end

  end

  core.run = run
  return core.run(...)
end


local command = require "core.command"

command.add(nil, {
  -- Drops the saved layout (splits, sizes, open docs) of the current
  -- project and restarts with a clean single editor.
  ["workspace:reset-layout"] = function()
    if core.root_project() then
      consume_workspace(core.root_project().path)
    end
    suppress_next_save = true
    command.perform("core:restart")
  end,
})

-- Exposed for tests; not part of the user API.
return { prune_empty_leaves = prune_empty_leaves }
