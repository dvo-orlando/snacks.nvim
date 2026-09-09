-- Treemap view for Snacks.explorer: a toggleable alternative to the
-- indented list, showing the current directory's immediate children as
-- proportionally-sized boxes (single-level drill-down — see the project's
-- Design). Reuses the picker's existing action set by shadowing
-- `list.current`/`list.render` per picker instance — Lua's field lookup
-- checks the instance table before falling back to the shared class
-- methods via `__index` — so delete/rename/copy/yank/etc. all keep working
-- unmodified against a treemap-built pseudo-item.

local Tree = require("snacks.explorer.tree")
local Weight = require("snacks.explorer.weight")
local Squarify = require("snacks.explorer.treemap.squarify")
local Grid = require("snacks.explorer.treemap.grid")

local M = {}

local ns = vim.api.nvim_create_namespace("snacks_explorer_treemap")

Snacks.util.set_hl({
  Header = "Title",
  Focus = "Visual",
}, { prefix = "SnacksPickerTreemap", default = true })

local HEADER_HL = "SnacksPickerTreemapHeader"
local FOCUS_HL = "SnacksPickerTreemapFocus"

-- a terminal character cell is visually ~2x taller than wide, so a "square"
-- in raw column/row counts reads as a tall rectangle on screen (see the
-- Step 1 spike) — scale the height axis down before layout, then back up
local CELL_ASPECT = 0.5

-- The sidebar's fixed ~40-column width is exactly the shape a treemap reads
-- worst in (see the Step 1 spike: narrow grids squeeze legibility, wide ones
-- don't) — so treemap mode pops into a big, roughly-square floating layout
-- instead, and reverts to the picker's configured layout (the sidebar) on
-- toggle-off. `picker:set_layout` reflows the *same* input/list windows into
-- a different box arrangement rather than recreating them.
local function popout_layout()
  return {
    preview = false,
    layout = {
      backdrop = true,
      width = 0.85,
      height = 0.85,
      min_width = 100,
      min_height = 30,
      box = "vertical",
      border = "rounded",
      title = "{title} {live} {flags}",
      title_pos = "center",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", border = "none" },
    },
  }
end

---@class snacks.explorer.treemap.State
---@field enabled boolean
---@field rects table[]? last-rendered cells: {name, weight, row0, col0, row1, col1}
---@field nodes table<string, snacks.picker.explorer.Node>? name -> child node, for the currently rendered dir
---@field focused integer index into rects/nodes for the focused box

---@type table<snacks.Picker, snacks.explorer.treemap.State>
M._state = setmetatable({}, { __mode = "k" })

---@param picker snacks.Picker
---@return snacks.explorer.treemap.State
function M.get_state(picker)
  if not M._state[picker] then
    M._state[picker] = { enabled = false, focused = 1 }
  end
  return M._state[picker]
end

---@param picker snacks.Picker
function M.is_enabled(picker)
  local state = M._state[picker]
  return state ~= nil and state.enabled
end

--- Builds a minimal picker-item-shaped table from a Tree node, matching the
--- shape `picker/source/explorer.lua` builds for list-view items, so
--- existing actions (rename/delete/copy/yank/jump...) work against it
--- unmodified.
---@param node snacks.picker.explorer.Node
local function node_to_item(node)
  return {
    file = node.path,
    dir = node.dir,
    text = node.path,
    type = node.type,
    status = node.status,
    severity = node.severity,
  }
end

---@param picker snacks.Picker
---@return snacks.picker.Item?
function M.current(picker)
  local state = M.get_state(picker)
  local cell = state.rects and state.rects[state.focused]
  local node = cell and state.nodes and state.nodes[cell.name]
  return node and node_to_item(node) or nil
end

---@param list snacks.picker.list
function M.current_from_list(list)
  return M.current(list.picker)
end

-- Same status -> highlight group mapping the list view's file-tree
-- formatter uses (`snacks.picker.format.file_git_status`), so treemap
-- coloring reads as the same color language, not a reinvented one.
---@param node snacks.picker.explorer.Node
---@return string?
local function status_highlight(node)
  local code = node.dir and (node.dir_status or node.status) or node.status
  if not code then
    return nil
  end
  local ok, status = pcall(require("snacks.picker.source.git").git_status, code)
  if not ok or not status or not status.status then
    return nil
  end
  if status.unmerged then
    return "SnacksPickerGitStatusUnmerged"
  elseif status.staged then
    return "SnacksPickerGitStatusStaged"
  end
  return "SnacksPickerGitStatus" .. status.status:sub(1, 1):upper() .. status.status:sub(2)
end

---@param buf number
---@param cell table
---@param hl_group string
local function highlight_cell(buf, cell, hl_group)
  for row = cell.row0, cell.row1 do
    vim.api.nvim_buf_add_highlight(buf, ns, hl_group, row + 1, cell.col0, cell.col1 + 1)
  end
end

---@param cell table?
local function header_text(cell)
  if not cell then
    return "(empty directory)"
  end
  return string.format("%s  ·  %d %s", cell.name, cell.weight, cell.weight == 1 and "entry" or "entries")
end

---@param list snacks.picker.list
function M.render(list)
  if not list.win:valid() then
    return
  end
  local picker = list.picker
  local state = M.get_state(picker)

  local cwd = picker:cwd()
  local dir_node = Tree:find(cwd)
  -- same hidden/ignored/exclude/include filter the list view applies, so
  -- toggling `H`/`I` (or a static `exclude`/`include` config) affects the
  -- treemap the same way, and .git/node_modules-style noise doesn't clutter it
  local filter = Tree:filter(picker.opts)
  local items = Weight.child_weights(dir_node, filter)
  -- deterministic input order, otherwise unrelated re-renders (resize, a
  -- sibling's diagnostics changing) can visibly reshuffle equal-weight boxes
  table.sort(items, function(a, b)
    return a.name < b.name
  end)

  local nodes = {}
  for name, child in pairs(dir_node.children) do
    if filter(child) then
      nodes[name] = child
    end
  end

  local width = vim.api.nvim_win_get_width(list.win.win)
  local height = vim.api.nvim_win_get_height(list.win.win)
  local grid_h = math.max(height - 1, 1) -- row 1 is reserved for the header

  local visual_h = grid_h * CELL_ASPECT
  local rects = Squarify.layout(items, 0, 0, width, visual_h, { min_area = width * visual_h * 0.01 })
  for _, r in ipairs(rects) do
    r.y = r.y / CELL_ASPECT
    r.h = r.h / CELL_ASPECT
  end

  local lines, cells = Grid.render(rects, width, grid_h)

  -- keep focus on the same name across a redraw (rename/delete/resize),
  -- otherwise clamp back into range
  local focused_name = state.rects and state.rects[state.focused] and state.rects[state.focused].name
  state.rects, state.nodes, state.focused = cells, nodes, 1
  if focused_name then
    for i, c in ipairs(cells) do
      if c.name == focused_name then
        state.focused = i
        break
      end
    end
  end

  vim.bo[list.win.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(list.win.buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(list.win.buf, 0, -1, false, { header_text(cells[state.focused]) })
  vim.api.nvim_buf_add_highlight(list.win.buf, ns, HEADER_HL, 0, 0, -1)
  vim.api.nvim_buf_set_lines(list.win.buf, 1, -1, false, lines)

  -- git-status coloring first (every cell), focus highlight last so it
  -- visually wins over a status color on the same cell
  for _, cell in ipairs(cells) do
    local node = nodes[cell.name]
    local hl = node and status_highlight(node)
    if hl then
      highlight_cell(list.win.buf, cell, hl)
    end
  end
  local focused_cell = cells[state.focused]
  if focused_cell then
    highlight_cell(list.win.buf, focused_cell, FOCUS_HL)
  end

  vim.bo[list.win.buf].modifiable = false
  list.win:redraw()
end

---@param cell table
local function center(cell)
  return (cell.col0 + cell.col1) / 2, (cell.row0 + cell.row1) / 2
end

---@param picker snacks.Picker
---@param dir "left"|"right"|"up"|"down"
function M.move(picker, dir)
  local state = M.get_state(picker)
  local cur = state.rects and state.rects[state.focused]
  if not cur then
    return
  end
  local cx, cy = center(cur)
  local best, best_score
  for i, cell in ipairs(state.rects) do
    if i ~= state.focused then
      local nx, ny = center(cell)
      local dx, dy = nx - cx, ny - cy
      local primary, perp, ok
      if dir == "left" then
        primary, perp, ok = -dx, dy, dx < -0.01
      elseif dir == "right" then
        primary, perp, ok = dx, dy, dx > 0.01
      elseif dir == "up" then
        primary, perp, ok = -dy, dx, dy < -0.01
      else
        primary, perp, ok = dy, dx, dy > 0.01
      end
      if ok then
        local score = primary + 2 * math.abs(perp)
        if not best_score or score < best_score then
          best_score, best = score, i
        end
      end
    end
  end
  if best then
    state.focused = best
    picker.list:render()
  end
end

---@param picker snacks.Picker
function M.confirm(picker)
  local item = M.current(picker)
  if not item then
    return
  end
  if item.dir then
    picker:set_cwd(item.file)
    picker:find()
  else
    require("snacks.picker.actions").jump(picker, item)
  end
end

---@param picker snacks.Picker
function M.enable(picker)
  local state = M.get_state(picker)
  if state.enabled then
    return
  end
  state.enabled = true
  picker.list.render = M.render
  picker.list.current = M.current_from_list
  picker:set_layout(popout_layout())

  -- The picker's own `VimResized` handler re-resolves the picker's
  -- statically-configured layout (the sidebar) on every resize — it has no
  -- notion of treemap mode, so left alone it would silently snap back out
  -- of the popout on the next resize. Re-assert after a short defer (not
  -- `vim.schedule`, which could still lose the race against that handler's
  -- own scheduled callback within the same tick) so this reliably wins.
  if not state.resize_guard then
    state.resize_guard = true
    picker.list.win:on("VimResized", function()
      vim.defer_fn(function()
        if M.is_enabled(picker) then
          picker:set_layout(popout_layout())
        end
      end, 30)
    end)
  end

  picker.list.dirty = true
  picker.list:render()
end

---@param picker snacks.Picker
function M.disable(picker)
  local state = M.get_state(picker)
  if not state.enabled then
    return
  end
  state.enabled = false
  picker.list.render = nil
  picker.list.current = nil
  picker:set_layout(nil)
  picker.list.dirty = true
  picker.list:render()
end

---@param picker snacks.Picker
function M.toggle(picker)
  if M.is_enabled(picker) then
    M.disable(picker)
  else
    M.enable(picker)
  end
end

-- Action names merged into `snacks.explorer.actions` (see the bottom of
-- explorer/actions.lua) and bound in the explorer picker's `win.list.keys`
-- (see picker/config/sources.lua). Each wrapper falls through to the
-- original list-mode action when treemap mode is off, so list-mode
-- behavior is unchanged.
M.actions = {}

function M.actions.explorer_treemap_toggle(picker)
  M.toggle(picker)
end

function M.actions.explorer_treemap_confirm(picker)
  if M.is_enabled(picker) then
    M.confirm(picker)
  else
    require("snacks.explorer.actions").actions.confirm(picker, picker:current())
  end
end

function M.actions.explorer_treemap_left(picker)
  if M.is_enabled(picker) then
    M.move(picker, "left")
  else
    require("snacks.explorer.actions").actions.explorer_close(picker, picker:current())
  end
end

function M.actions.explorer_treemap_right(picker)
  if M.is_enabled(picker) then
    M.move(picker, "right")
  else
    require("snacks.explorer.actions").actions.confirm(picker, picker:current())
  end
end

function M.actions.explorer_treemap_down(picker)
  if M.is_enabled(picker) then
    M.move(picker, "down")
  else
    require("snacks.picker.actions").list_down(picker)
  end
end

function M.actions.explorer_treemap_up(picker)
  if M.is_enabled(picker) then
    M.move(picker, "up")
  else
    require("snacks.picker.actions").list_up(picker)
  end
end

return M
