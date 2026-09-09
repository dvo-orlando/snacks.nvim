-- Cheap weight metric for the treemap view: a file counts as 1; a directory
-- counts as its direct entry count. Reuses Tree:expand (a single,
-- non-recursive uv.fs_scandir) rather than walking descendants recursively —
-- deeper directories only get a more informed weight once the user has
-- actually browsed into them and Tree has cached their children.

local Tree = require("snacks.explorer.tree")

local M = {}

---@param node snacks.picker.explorer.Node
---@param filter? fun(node: snacks.picker.explorer.Node): boolean?
---@return integer
function M.weight(node, filter)
  if not node.dir then
    return 1
  end
  if not node.expanded then
    Tree:expand(node)
  end
  local count = 0
  for _, child in pairs(node.children) do
    if not filter or filter(child) then
      count = count + 1
    end
  end
  -- an empty (or unreadable, or fully-filtered-out) directory still needs a
  -- nonzero weight to occupy space in the layout
  return math.max(count, 1)
end

--- Weights for every immediate child of `dir_node` that passes `filter` —
--- the per-box sizing input for a single-level treemap of that directory.
--- `filter` should match `Tree:filter(...)`'s shape (hidden/ignored/exclude
--- respected the same way the list view respects them).
---@param dir_node snacks.picker.explorer.Node
---@param filter? fun(node: snacks.picker.explorer.Node): boolean?
---@return {name:string, weight:integer}[]
function M.child_weights(dir_node, filter)
  if not dir_node.expanded then
    Tree:expand(dir_node)
  end
  local items = {}
  for name, child in pairs(dir_node.children) do
    if not filter or filter(child) then
      items[#items + 1] = { name = name, weight = M.weight(child, filter) }
    end
  end
  return items
end

return M
