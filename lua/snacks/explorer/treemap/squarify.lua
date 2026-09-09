-- Squarified treemap layout, ported from the well-known "squarify" algorithm
-- (Bruls, Huizing, van Wijk 2000; same logic as the pypi `squarify` package
-- and d3-hierarchy's treemapSquarify), plus a minimum-area clamp so a long
-- tail of small siblings next to one dominant item doesn't round away to
-- nothing (see Step 1 spike findings).
--
-- items: array of {name=string, weight=number}, weight > 0, ANY order —
-- this module sorts descending internally (required by the algorithm).
-- Returns: array of {name, weight, x, y, w, h} tiling the given rect.

local M = {}

local function rect_sum(sizes)
  local s = 0
  for _, v in ipairs(sizes) do
    s = s + v
  end
  return s
end

-- `weights` (optional) carries the ORIGINAL, pre-normalization weight for
-- each size, so callers get back the semantic weight (e.g. a child count)
-- rather than the layout's internal area allocation. `worst_ratio` doesn't
-- care about it (it only reads w/h), so it's fine to omit there.
local function layout_row(sizes, names, weights, x, y, dx, dy, out)
  local covered = rect_sum(sizes)
  local width = covered / dy
  local cy = y
  for k, size in ipairs(sizes) do
    local h = width > 0 and (size / width) or 0
    out[#out + 1] = { name = names[k], weight = weights and weights[k] or size, x = x, y = cy, w = width, h = h }
    cy = cy + h
  end
end

local function layout_col(sizes, names, weights, x, y, dx, dy, out)
  local covered = rect_sum(sizes)
  local height = covered / dx
  local cx = x
  for k, size in ipairs(sizes) do
    local w = height > 0 and (size / height) or 0
    out[#out + 1] = { name = names[k], weight = weights and weights[k] or size, x = cx, y = y, w = w, h = height }
    cx = cx + w
  end
end

local function layout(sizes, names, weights, x, y, dx, dy, out)
  if dx >= dy then
    layout_row(sizes, names, weights, x, y, dx, dy, out)
  else
    layout_col(sizes, names, weights, x, y, dx, dy, out)
  end
end

local function leftover(sizes, x, y, dx, dy)
  local covered = rect_sum(sizes)
  if dx >= dy then
    local width = covered / dy
    return x + width, y, dx - width, dy
  else
    local height = covered / dx
    return x, y + height, dx, dy - height
  end
end

local function worst_ratio(sizes, names, x, y, dx, dy)
  local rects = {}
  layout(sizes, names, nil, x, y, dx, dy, rects)
  local worst = 0
  for _, r in ipairs(rects) do
    if r.w > 0 and r.h > 0 then
      local ratio = math.max(r.w / r.h, r.h / r.w)
      if ratio > worst then
        worst = ratio
      end
    else
      worst = math.huge
    end
  end
  return worst
end

--- Clamps every size to at least `min_area`, shrinking the sizes above that
--- floor proportionally so the total is preserved exactly (so the rest of
--- the algorithm's area bookkeeping stays consistent). If even an equal
--- split can't give everyone `min_area`, everyone gets an equal share
--- instead.
local function clamp_min_area(sizes, total_area, min_area)
  local n = #sizes
  if n == 0 then
    return sizes
  end
  if min_area * n > total_area then
    min_area = total_area / n
  end
  local free_total, deficit = 0, 0
  for _, s in ipairs(sizes) do
    if s < min_area then
      deficit = deficit + (min_area - s)
    else
      free_total = free_total + s
    end
  end
  if deficit == 0 then
    return sizes
  end
  local scale = free_total > 0 and (free_total - deficit) / free_total or 1
  local out = {}
  for i, s in ipairs(sizes) do
    out[i] = s < min_area and min_area or s * scale
  end
  return out
end

--- @param items {name:string, weight:number}[]
--- @param x number @param y number @param w number @param h number
--- @param opts? {min_area?: number}
--- @return table[] rects {name, weight, x, y, w, h}
function M.layout(items, x, y, w, h, opts)
  opts = opts or {}
  local out = {}
  if #items == 0 or w <= 0 or h <= 0 then
    return out
  end

  -- sort descending by weight (required by the algorithm for good ratios)
  local sorted = {}
  for _, it in ipairs(items) do
    sorted[#sorted + 1] = it
  end
  table.sort(sorted, function(a, b)
    return a.weight > b.weight
  end)

  local total_weight = 0
  for _, it in ipairs(sorted) do
    total_weight = total_weight + it.weight
  end
  if total_weight <= 0 then
    return out
  end
  local total_area = w * h
  local sizes, names, weights = {}, {}, {}
  for k, it in ipairs(sorted) do
    sizes[k] = it.weight * total_area / total_weight
    names[k] = it.name
    weights[k] = it.weight
  end
  if opts.min_area and opts.min_area > 0 then
    sizes = clamp_min_area(sizes, total_area, opts.min_area)
  end

  local cx, cy, cw, ch = x, y, w, h
  local idx = 1
  local n = #sizes

  while idx <= n do
    local i = idx
    local cur_sizes, cur_names, cur_weights = { sizes[idx] }, { names[idx] }, { weights[idx] }
    local best_ratio = worst_ratio(cur_sizes, cur_names, cx, cy, cw, ch)

    while i < n do
      local next_sizes, next_names, next_weights = {}, {}, {}
      for k = 1, #cur_sizes do
        next_sizes[k] = cur_sizes[k]
        next_names[k] = cur_names[k]
        next_weights[k] = cur_weights[k]
      end
      next_sizes[#next_sizes + 1] = sizes[i + 1]
      next_names[#next_names + 1] = names[i + 1]
      next_weights[#next_weights + 1] = weights[i + 1]
      local next_ratio = worst_ratio(next_sizes, next_names, cx, cy, cw, ch)
      if next_ratio <= best_ratio then
        cur_sizes, cur_names, cur_weights = next_sizes, next_names, next_weights
        best_ratio = next_ratio
        i = i + 1
      else
        break
      end
    end

    layout(cur_sizes, cur_names, cur_weights, cx, cy, cw, ch, out)
    cx, cy, cw, ch = leftover(cur_sizes, cx, cy, cw, ch)
    idx = i + 1
  end

  return out
end

return M
