-- Cheap weight metric for the treemap view: a file counts as 1; a directory
-- counts as its direct entry count. Reuses Tree:expand (a single,
-- non-recursive uv.fs_scandir) rather than walking descendants recursively —
-- deeper directories only get a more informed weight once the user has
-- actually browsed into them and Tree has cached their children.

local Tree = require("snacks.explorer.tree")

local M = {}

---@param node snacks.picker.explorer.Node
---@return integer
function M.weight(node)
  if not node.dir then
    return 1
  end
  if not node.expanded then
    Tree:expand(node)
  end
  local count = 0
  for _ in pairs(node.children) do
    count = count + 1
  end
  -- an empty (or unreadable) directory still needs a nonzero weight to
  -- occupy space in the layout
  return math.max(count, 1)
end

--- Weights for every immediate child of `dir_node` — the per-box sizing
--- input for a single-level treemap of that directory.
---@param dir_node snacks.picker.explorer.Node
---@return {name:string, weight:integer}[]
function M.child_weights(dir_node)
  if not dir_node.expanded then
    Tree:expand(dir_node)
  end
  local items = {}
  for name, child in pairs(dir_node.children) do
    items[#items + 1] = { name = name, weight = M.weight(child) }
  end
  return items
end

return M
