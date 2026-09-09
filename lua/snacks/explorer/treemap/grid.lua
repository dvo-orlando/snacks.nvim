-- Renders squarify.lua rects into a character grid: real buffer text for
-- box-drawing borders/fill (extmarks are used only for highlighting, never
-- to draw the boxes — see the Step 1 spike findings). Label placement is
-- UTF-8-safe (operates on characters, not bytes) — a naive byte-wise
-- `string.sub` corrupts multi-byte characters like the truncation ellipsis.

local M = {}

--- Splits a string into a list of characters (not bytes).
---@param s string
---@return string[]
local function chars(s)
  if s == "" then
    return {}
  end
  return vim.fn.split(s, "\\zs")
end

--- @param rects table[] from Squarify.layout: {name, weight, x, y, w, h} (float coords)
--- @param grid_w number integer character columns available
--- @param grid_h number integer character rows available
--- @return string[] lines
--- @return table[] cells {name, weight, row0, col0, row1, col1} (0-indexed, inclusive; buffer/extmark-ready)
function M.render(rects, grid_w, grid_h)
  local grid = {}
  for r = 1, grid_h do
    grid[r] = {}
    for c = 1, grid_w do
      grid[r][c] = " "
    end
  end

  local function set(r, c, ch)
    if r >= 1 and r <= grid_h and c >= 1 and c <= grid_w then
      grid[r][c] = ch
    end
  end

  local cells = {}

  for _, rect in ipairs(rects) do
    -- round shared boundaries (not width/height) so adjacent cells tile with no gaps/overlap
    local x0 = math.floor(rect.x + 0.5)
    local y0 = math.floor(rect.y + 0.5)
    local x1 = math.floor(rect.x + rect.w + 0.5)
    local y1 = math.floor(rect.y + rect.h + 0.5)
    -- to 1-indexed inclusive grid coords
    local col0, row0 = x0 + 1, y0 + 1
    local col1, row1 = x1, y1
    local w = col1 - col0 + 1
    local h = row1 - row0 + 1
    if w >= 1 and h >= 1 then
      if w >= 3 and h >= 2 then
        set(row0, col0, "┌")
        set(row0, col1, "┐")
        set(row1, col0, "└")
        set(row1, col1, "┘")
        for c = col0 + 1, col1 - 1 do
          set(row0, c, "─")
          set(row1, c, "─")
        end
        for r = row0 + 1, row1 - 1 do
          set(r, col0, "│")
          set(r, col1, "│")
        end
        local interior_w = w - 2
        local interior_h = h - 2
        if interior_h >= 1 and interior_w >= 1 then
          local label_chars = chars(rect.name)
          if #label_chars > interior_w then
            local keep = interior_w > 1 and (interior_w - 1) or 0
            local truncated = {}
            for i = 1, keep do
              truncated[i] = label_chars[i]
            end
            if interior_w > 1 then
              truncated[#truncated + 1] = "…"
            end
            label_chars = truncated
          end
          for i, ch in ipairs(label_chars) do
            set(row0 + 1, col0 + i - 1, ch)
          end
          if interior_h >= 2 then
            local wchars = chars(tostring(rect.weight))
            for i = 1, math.min(#wchars, interior_w) do
              set(row0 + 2, col0 + i - 1, wchars[i])
            end
          end
        end
      else
        local glyph = (rect.name and #rect.name > 0) and (chars(rect.name)[1] or "·") or "·"
        for r = row0, row1 do
          for c = col0, col1 do
            set(r, c, glyph)
          end
        end
      end
      cells[#cells + 1] = {
        name = rect.name,
        weight = rect.weight,
        row0 = row0 - 1,
        col0 = col0 - 1,
        row1 = row1 - 1,
        col1 = col1 - 1,
      }
    end
  end

  local lines = {}
  for r = 1, grid_h do
    lines[r] = table.concat(grid[r])
  end
  return lines, cells
end

return M
