--[[--
drawingpad.geometry - geometry calculation and transform methods (DrawingCanvas mixin module).
Pure coordinate/region/bounding-box calculations and element geometry transforms, with no dependencies beyond UI state.
Text bounding boxes use the actual rendered size (RenderText:sizeUtf8Text), so the handle frame fully covers the text
and moves/transforms no longer leave ghosting.
--]]

local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")

-- Self-locate: same-directory short names shapes/const resolve (since v53 pluginloader injects <plugin dir>/?.lua,
-- so the short pattern is enough; v57 dropped the parent-directory dual pattern, the wbuilder path is injected separately at the top of wbuilder.lua)
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local M = {}

-- Screen coordinates -> canvas coordinates (canvas coordinates = screen coordinates, so toggling minimise causes no shift);
-- in visible mode the occluded strip at the bottom (toolbar + status bar) is not drawable
function M:_toCanvas(px, py)
    if px < 0 or py < 0 or px >= self.canvas_w or py >= self.canvas_h then
        return nil
    end
    if not self._minimized and py >= self.canvas_h - self.header_h then
        return nil
    end
    return px, py
end

-- Stroke/preview bounding-box refresh region (screen coordinates = canvas coordinates, with margin; returns a Geom or nil)
function M:_dirtyRegion(x0, y0, x1, y1, margin)
    margin = margin or 2
    local rx0 = math.max(0, math.floor(math.min(x0, x1)) - margin)
    local ry0 = math.max(0, math.floor(math.min(y0, y1)) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(math.max(x0, x1)) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(math.max(y0, y1)) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- Element bounding box (canvas coordinates); returns {x0,y0,x1,y1} or nil
-- Text render size (including sx/sy stretch): returns {w, yt, yb, baseline} or nil (face missing).
-- Shared by bounding box/selection frame/ink distance/drawing, so the "stretched" size is consistent everywhere
function M:_textExtent(el)
    local face = Font:getFace(el.font, el.size)
    local s = face and RenderText:sizeUtf8Text(0, nil, face, el.text, false, false)
    if not (s and s.x and s.y_top and s.y_bottom) then
        return nil
    end
    return {
        w = s.x * (el.sx or 1),
        yt = s.y_top * (el.sy or 1),
        yb = s.y_bottom * (el.sy or 1),
        baseline = (el.y or 0) + math.floor(el.size * 0.8),
    }
end

function M:_elementBBox(el)
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    local function add(x0, y0, x1, y1)
        if x0 < minx then minx = x0 end
        if y0 < miny then miny = y0 end
        if x1 > maxx then maxx = x1 end
        if y1 > maxy then maxy = y1 end
    end
    if el.kind == "circle" then
        -- Axis-aligned bounding box enclosing a circle/ellipse (including rotated)
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local rot = el.rot or 0
        if rot == 0 then
            add(el.cx - rx, el.cy - ry, el.cx + rx, el.cy + ry)
        else
            local c, s = math.abs(math.cos(rot)), math.abs(math.sin(rot))
            local hw = rx * c + ry * s
            local hh = rx * s + ry * c
            add(el.cx - hw, el.cy - hh, el.cx + hw, el.cy + hh)
        end
    elseif el.kind == "line" or el.kind == "rect" then
        add(math.min(el.x0, el.x1), math.min(el.y0, el.y1),
            math.max(el.x0, el.x1), math.max(el.y0, el.y1))
    elseif el.kind == "freehand" or el.kind == "eraser" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            add(p.x - el.width, p.y - el.width, p.x + el.width, p.y + el.width)
        end
    elseif el.kind == "fill" then
        -- Flood-fill result: bounding box of the span list {y, x0, x1}
        for _, sp in ipairs(el.spans) do
            add(sp[2], sp[1], sp[3], sp[1])
        end
    elseif el.kind == "text" then
        if not el.text or not el.size then
            return nil
        end
        -- Prefer the actual rendered size for the bounding box (handle frame fully covers the text, no ghosting on move);
        -- fall back to a character-count estimate when the font is missing
        local nchars = select(2, el.text:gsub("[^\128-\191]", ""))
        local e = self:_textExtent(el)
        if e then
            local ax = el.x or 0
            local ay = e.baseline -- rotation centre = baseline (same anchor as _drawTextTo/_frameCorners)
            local rot = el.rot or 0
            if rot == 0 then
                add(ax - 1, e.baseline - e.yt - 1, ax + e.w + 1, e.baseline + e.yb + 1)
            else
                -- Rotated: rotate the 4 corners about the anchor (left end of the baseline) and take the enclosing box
                local c, sn = math.cos(rot), math.sin(rot)
                local function radd(px, py)
                    local dx, dy = px - ax, py - ay
                    add(ax + dx * c - dy * sn, ay + dx * sn + dy * c,
                        ax + dx * c - dy * sn, ay + dx * sn + dy * c)
                end
                radd(ax - 1, e.baseline - e.yt - 1)
                radd(ax + e.w + 1, e.baseline - e.yt - 1)
                radd(ax + e.w + 1, e.baseline + e.yb + 1)
                radd(ax - 1, e.baseline + e.yb + 1)
            end
            return { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
        end
        add(el.x or 0, el.y or 0, (el.x or 0) + nchars * el.size, (el.y or 0) + math.ceil(el.size * 1.5))
    end
    if minx == math.huge then
        return nil
    end
    return { x0 = minx, y0 = miny, x1 = maxx, y1 = maxy }
end

-- Cache the bounding box when an element is committed (committed elements are immutable, so the cache never goes stale).
-- Tap-delete prefiltering/box delete/save cropping/partial redraw all use the cache instead of scanning every point list each time
function M:_cacheBBox(el)
    el._bbox = self:_elementBBox(el)
    return el._bbox
end

-- Full element refresh region: a circle is centred on the anchor with radius = drag distance, so it exceeds the "anchor-release point" box;
-- it must be computed from the element's actual extent (centre ± radius / diagonal ± line width), otherwise the screen refresh is incomplete and the circle has missing chunks
function M:_elementRegion(el, extra)
    extra = extra or 2
    local margin = (el.width or 2) + extra
    local b = self:_elementBBox(el)
    if not b then
        return nil
    end
    local rx0 = math.max(0, math.floor(b.x0) - margin)
    local ry0 = math.max(0, math.floor(b.y0) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(b.x1) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(b.y1) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- Merge two refresh regions
function M:_mergeRegions(a, b)
    if not a then
        return b
    end
    if not b then
        return a
    end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Element content bounding box (for export cropping); returns {x,y,w,h} or nil (no content)
-- Uses the bbox cached at commit: no longer scans every stroke's point list
function M:_contentBBox()
    local minx, miny, maxx, maxy = math.huge, math.huge, -1, -1
    local function add(x0, y0, x1, y1)
        if x0 < minx then minx = x0 end
        if y0 < miny then miny = y0 end
        if x1 > maxx then maxx = x1 end
        if y1 > maxy then maxy = y1 end
    end
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                local b = el._bbox or self:_elementBBox(el)
                if b then
                    add(b.x0, b.y0, b.x1, b.y1)
                end
            end
        end
    end
    if maxx < 0 then
        return nil
    end
    local pad = 8
    local x0 = math.max(0, math.floor(minx) - pad)
    local y0 = math.max(0, math.floor(miny) - pad)
    local x1 = math.min(self.canvas_w - 1, math.ceil(maxx) + pad)
    local y1 = math.min(self.canvas_h - 1, math.ceil(maxy) + pad)
    if x1 < x0 or y1 < y0 then
        return nil
    end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- Translate element coordinates (per-kind coordinate fields; the bbox cache must be recomputed after translating)
function M:_moveElement(el, dx, dy)
    if el.kind == "freehand" or el.kind == "eraser" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x = p.x + dx
            p.y = p.y + dy
        end
    elseif el.kind == "line" or el.kind == "rect" then
        el.x0, el.y0 = el.x0 + dx, el.y0 + dy
        el.x1, el.y1 = el.x1 + dx, el.y1 + dy
    elseif el.kind == "circle" then
        el.cx, el.cy = el.cx + dx, el.cy + dy
    elseif el.kind == "text" then
        el.x = (el.x or 0) + dx
        el.y = (el.y or 0) + dy
    elseif el.kind == "fill" then
        -- Fill result: translate the span list (y/x0/x1 per row); also translate the source vertices,
        -- otherwise rotating after a move recomputes from the old vertices and the fill jumps back
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x = p.x + dx
                p.y = p.y + dy
            end
        end
        for _, sp in ipairs(el.spans) do
            sp[1] = sp[1] + dy
            sp[2] = sp[2] + dx
            sp[3] = sp[3] + dx
        end
    end
end

-- Clone an element (deep copy of freehand point lists/spans; _bbox not copied, recomputed on commit)
function M:_cloneElement(el)
    local c = {}
    for k, v in pairs(el) do
        if k == "points" or k == "src_points" then
            local pts = {}
            for i, p in ipairs(v) do
                pts[i] = { x = p.x, y = p.y, f = p.f } -- f = per-point pen width factor (Kobo fork, nil for finger strokes)
            end
            c[k] = pts
        elseif k == "spans" then
            -- Deep copy of the fill's span list (moved/copied duplicates are independent, no shared pixel rows)
            local sps = {}
            for i, sp in ipairs(v) do
                sps[i] = { sp[1], sp[2], sp[3] }
            end
            c.spans = sps
        elseif k ~= "_bbox" then
            c[k] = v
        end
    end
    return c
end

-- Restore an element from a geometry snapshot (for transform undo/redo; points deep-copied so later edits can't pollute the snapshot)
function M:_restoreGeom(el, snap)
    for k in pairs(el) do
        if k ~= "_bbox" then
            el[k] = nil
        end
    end
    for k, v in pairs(snap) do
        if k == "points" or k == "src_points" then
            local pts = {}
            for i, p in ipairs(v) do
                pts[i] = { x = p.x, y = p.y, f = p.f } -- keep the pen width factor (Kobo fork)
            end
            el[k] = pts
        elseif k ~= "_bbox" then
            el[k] = v
        end
    end
end

-- Compute the new bounding box from the handle and new position (opposite corner/single axis fixed; minimum size 4px)
function M:_transformBBox(handle, sb, x, y)
    local min_size = 4
    local x0, y0, x1, y1 = sb.x0, sb.y0, sb.x1, sb.y1
    if handle == "nw" then
        return { x0 = math.min(x, x1 - min_size), y0 = math.min(y, y1 - min_size), x1 = x1, y1 = y1 }
    elseif handle == "ne" then
        return { x0 = x0, y0 = math.min(y, y1 - min_size), x1 = math.max(x, x0 + min_size), y1 = y1 }
    elseif handle == "sw" then
        return { x0 = math.min(x, x1 - min_size), y0 = y0, x1 = x1, y1 = math.max(y, y0 + min_size) }
    elseif handle == "se" then
        return { x0 = x0, y0 = y0, x1 = math.max(x, x0 + min_size), y1 = math.max(y, y0 + min_size) }
    elseif handle == "n" then
        return { x0 = x0, y0 = math.min(y, y1 - min_size), x1 = x1, y1 = y1 }
    elseif handle == "s" then
        return { x0 = x0, y0 = y0, x1 = x1, y1 = math.max(y, y0 + min_size) }
    elseif handle == "w" then
        return { x0 = math.min(x, x1 - min_size), y0 = y0, x1 = x1, y1 = y1 }
    elseif handle == "e" then
        return { x0 = x0, y0 = y0, x1 = math.max(x, x0 + min_size), y1 = y1 }
    end
    return sb
end

-- Scale element geometry: bilinear coordinate mapping from the start bounding box -> new bounding box
-- (text scaling = position mapping + the uniform part goes into font size (stays sharp) + the remaining non-uniform part into sx/sy pixel scaling;
-- circle/ellipse = centre mapping + per-axis factors for rx/ry -> ellipse)
function M:_scaleElement(el, sb, nb)
    local sx = (nb.x1 - nb.x0) / math.max(1, sb.x1 - sb.x0)
    local sy = (nb.y1 - nb.y0) / math.max(1, sb.y1 - sb.y0)
    local function map(px, py)
        return nb.x0 + (px - sb.x0) * sx, nb.y0 + (py - sb.y0) * sy
    end
    if el.kind == "freehand" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x, p.y = map(p.x, p.y)
        end
    elseif el.kind == "line" then
        el.x0, el.y0 = map(el.x0, el.y0)
        el.x1, el.y1 = map(el.x1, el.y1)
    elseif el.kind == "rect" then
        el.x0, el.y0 = map(el.x0, el.y0)
        el.x1, el.y1 = map(el.x1, el.y1)
    elseif el.kind == "circle" then
        -- Circle/ellipse: map the centre, scale rx/ry by per-axis factors (non-uniform -> ellipse)
        el.cx, el.cy = map(el.cx, el.cy)
        el.rx = math.max(1, (el.rx or el.r) * sx)
        el.ry = math.max(1, (el.ry or el.rx or el.r) * sy)
    elseif el.kind == "text" then
        -- Uniform part goes into font size (sharp glyphs), the remaining non-uniform part into sx/sy (pixel-scaled into stretched glyphs at render time)
        local f = (sx + sy) / 2
        el.x, el.y = map(el.x, el.y)
        el.size = math.max(1, math.floor(el.size * f + 0.5))
        local denom = math.max(0.0001, f)
        el.sx = (el.sx or 1) * (sx / denom)
        el.sy = (el.sy or 1) * (sy / denom)
    elseif el.kind == "fill" then
        -- Path fill with source vertices: apply the same bilinear mapping directly to the vertices and recompute spans,
        -- using the same scanline code as the initial generation; every transform starts from continuous geometry, no cumulative quantisation.
        -- (tap flood fills/old saves without src_points have no geometry to work from, so they keep span mapping)
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x, p.y = map(p.x, p.y)
            end
            el.spans = self:_polygonFillSpans(el.src_points)
            return
        end
        -- Fill result: scale the span list to the new bbox.
        -- When enlarging (sy>1) a source row can't map to just one target row - gaps would be left between the target rows of adjacent source rows,
        -- forming dense horizontal stripes; instead map the source row's vertical half-row range [y-0.5, y+0.5] and fill the resulting band of target rows,
        -- so bands of adjacent source rows meet/overlap at their boundaries and the row set is continuous. Shrinking (sy<1) keeps row-by-row mapping,
        -- with several source rows merging into one target row, handled by the merge logic below.
        local new_spans = {}
        local rows = {}
        local ylo, yhi
        if sy >= 1 then
            ylo = function(y) return math.ceil(sb.y0 + (y - 0.5 - sb.y0) * sy) end
            yhi = function(y) return math.floor(sb.y0 + (y + 0.5 - sb.y0) * sy) end
        else
            ylo = function(y) return math.floor(sb.y0 + (y - sb.y0) * sy + 0.5) end
            yhi = ylo
        end
        for _, sp in ipairs(el.spans) do
            local y, x0, x1 = sp[1], sp[2], sp[3]
            local nx0 = math.floor(sb.x0 + (x0 - sb.x0) * sx + 0.5)
            local nx1 = math.floor(sb.x0 + (x1 - sb.x0) * sx + 0.5)
            local xa, xb = math.min(nx0, nx1), math.max(nx0, nx1)
            for t = ylo(y), yhi(y) do
                local row = rows[t]
                if not row then
                    row = {}
                    rows[t] = row
                end
                table.insert(row, { xa, xb })
            end
        end
        for y, list in pairs(rows) do
            table.sort(list, function(a, b) return a[1] < b[1] end)
            local merged = {}
            local cur = list[1]
            for i = 2, #list do
                local s = list[i]
                if s[1] <= cur[2] + 1 then
                    cur[2] = math.max(cur[2], s[2])
                else
                    table.insert(merged, cur)
                    cur = s
                end
            end
            table.insert(merged, cur)
            for _, s in ipairs(merged) do
                table.insert(new_spans, { y, s[1], s[2] })
            end
        end
        el.spans = new_spans
        -- Mark as a rasterised fill after transform: replay adds a 1px overlap to avoid white lines from rounding
        el._rasterized = true
    end
end

-- Corner-handle scaling along the object's own rotated bounding box (OBB): drag an OBB corner to (x,y) with the opposite corner fixed,
-- computing and applying scale factors separately along the two OBB axes.
-- For rotated objects (ellipse rot≠0/poly/text rot≠0) the scale handles sit on OBB corners, inside the AABB;
-- with the AABB _transformBBox/_scaleElement, dragging an OBB corner outward can't release beyond the AABB,
-- so the object could only shrink, never grow. Non-rotated shapes (handles on AABB corners) return false and take the old path.
function M:_scaleElementOriented(el, handle, x, y)
    local F, ux, uy, vx, vy
    if el.kind == "circle" then
        if (el.rot or 0) == 0 then
            return false
        end
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local c, s = math.cos(el.rot), math.sin(el.rot)
        ux, uy, vx, vy = c, s, -s, c
        F = {
            { el.cx + rx * c - ry * s, el.cy + rx * s + ry * c },
            { el.cx + rx * c + ry * s, el.cy + rx * s - ry * c },
            { el.cx - rx * c + ry * s, el.cy - rx * s - ry * c },
            { el.cx - rx * c - ry * s, el.cy - rx * s + ry * c },
        }
    elseif el.kind == "poly" then
        F = {}
        for i, p in ipairs(el.points) do
            F[i] = { p.x, p.y }
        end
        if #F < 4 then
            return false
        end
        local d1x, d1y = F[2][1] - F[1][1], F[2][2] - F[1][2]
        local d2x, d2y = F[4][1] - F[1][1], F[4][2] - F[1][2]
        local l1 = math.sqrt(d1x * d1x + d1y * d1y)
        local l2 = math.sqrt(d2x * d2x + d2y * d2y)
        if l1 < 0.001 or l2 < 0.001 then
            return false
        end
        ux, uy, vx, vy = d1x / l1, d1y / l1, d2x / l2, d2y / l2
    elseif el.kind == "text" then
        if (el.rot or 0) == 0 then
            return false
        end
        local e = self:_textExtent(el)
        if not e then
            return false
        end
        local c, s = math.cos(el.rot), math.sin(el.rot)
        ux, uy, vx, vy = c, s, -s, c
        local ax, ay = el.x or 0, el.y or 0
        local b = e.baseline
        F = {
            { ax - 1, b - e.yt - 1 },
            { ax + e.w + 1, b - e.yt - 1 },
            { ax + e.w + 1, b + e.yb + 1 },
            { ax - 1, b + e.yb + 1 },
        }
        for _, p in ipairs(F) do
            local dx, dy = p[1] - ax, p[2] - ay
            p[1], p[2] = ax + dx * c - dy * s, ay + dx * s + dy * c
        end
    else
        return false
    end
    -- Dragged corner index and fixed opposite corner (opposite fixed: nw↔se, ne↔sw)
    local i = handle == "nw" and 1 or handle == "ne" and 2
        or handle == "se" and 3 or handle == "sw" and 4 or 3
    local j = ((i + 1) % 4) + 1
    local pj = F[j]
    local pi = F[i]
    -- Projection of the diagonal vector on the two OBB axes and the projection of the drag to (x,y)
    local d_ux = (pi[1] - pj[1]) * ux + (pi[2] - pj[2]) * uy
    local d_vx = (pi[1] - pj[1]) * vx + (pi[2] - pj[2]) * vy
    if math.abs(d_ux) < 0.001 or math.abs(d_vx) < 0.001 then
        return false
    end
    local fu = math.max(0.05, ((x - pj[1]) * ux + (y - pj[2]) * uy) / d_ux)
    local fv = math.max(0.05, ((x - pj[1]) * vx + (y - pj[2]) * vy) / d_vx)
    if el.kind == "circle" then
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        el.rx = math.max(1, rx * fu)
        el.ry = math.max(1, ry * fv)
        -- Move the centre to the midpoint with the opposite corner fixed: C' = Pj + (d'u/2)u + (d'v/2)v
        el.cx = pj[1] + ((x - pj[1]) * ux + (y - pj[2]) * uy) / 2 * ux
            + ((x - pj[1]) * vx + (y - pj[2]) * vy) / 2 * vx
        el.cy = pj[2] + ((x - pj[1]) * ux + (y - pj[2]) * uy) / 2 * uy
            + ((x - pj[1]) * vx + (y - pj[2]) * vy) / 2 * vy
    elseif el.kind == "poly" then
        for _, p in ipairs(el.points) do
            local a = (p.x - pj[1]) * ux + (p.y - pj[2]) * uy
            local b = (p.x - pj[1]) * vx + (p.y - pj[2]) * vy
            p.x = pj[1] + a * fu * ux + b * fv * vx
            p.y = pj[2] + a * fu * uy + b * fv * vy
        end
    elseif el.kind == "text" then
        -- Uniform part goes into font size (sharp glyphs), the remaining non-uniform part into sx/sy (same approach as _scaleElement)
        local f = (fu + fv) / 2
        el.size = math.max(1, math.floor(el.size * f + 0.5))
        local denom = math.max(0.0001, f)
        el.sx = (el.sx or 1) * (fu / denom)
        el.sy = (el.sy or 1) * (fv / denom)
        -- Scale the anchor's (left end of the baseline) offset from the fixed corner along the two OBB axes by the factors
        local ax, ay = el.x or 0, el.y or 0
        local a_ux = (ax - pj[1]) * ux + (ay - pj[2]) * uy
        local a_vx = (ax - pj[1]) * vx + (ay - pj[2]) * vy
        el.x = pj[1] + a_ux * fu * ux + a_vx * fv * vx
        el.y = pj[2] + a_ux * fu * uy + a_vx * fv * vy
    end
    return true
end

-- Rotate element geometry: rotate by angle radians about (cx,cy).
-- Rotating a rectangle -> converts to poly (4 rotated corner points, closed outline; filled degrades to outline)
-- Rotating an ellipse -> records rot (sample points are rotated about the centre at render time)
function M:_rotateElement(el, angle, cx, cy)
    local cos, sin = math.cos(angle), math.sin(angle)
    local function rot(px, py)
        local dx, dy = px - cx, py - cy
        return cx + dx * cos - dy * sin, cy + dx * sin + dy * cos
    end
    if el.kind == "freehand" or el.kind == "poly" then
        for _, p in ipairs(el.points) do
            p.x, p.y = rot(p.x, p.y)
        end
    elseif el.kind == "line" then
        el.x0, el.y0 = rot(el.x0, el.y0)
        el.x1, el.y1 = rot(el.x1, el.y1)
    elseif el.kind == "circle" then
        el.rot = (el.rot or 0) + angle
    elseif el.kind == "text" then
        -- Text rotation: accumulate the angle + rotate the anchor (left end of the baseline) about the rotation centre in step
        -- (anchor + angle in step = consistent rigid rotation; rendering rotates about the anchor by el.rot)
        el.rot = (el.rot or 0) + angle
        el.x, el.y = rot(el.x or 0, el.y or 0)
    elseif el.kind == "rect" then
        local pts = {
            { x = el.x0, y = el.y0 },
            { x = el.x1, y = el.y0 },
            { x = el.x1, y = el.y1 },
            { x = el.x0, y = el.y1 },
        }
        for _, p in ipairs(pts) do
            p.x, p.y = rot(p.x, p.y)
        end
        el.kind = "poly"
        el.points = pts
        -- Keep filled: a rotated filled rectangle should stay filled
    elseif el.kind == "fill" then
        -- Path fill with source vertices: rotate the vertices exactly, then recompute spans with the same scanline as the initial generation
        -- (_polygonFillSpans, half-open intervals + pixel-centre rounding).
        -- Every transform starts from continuous geometry, unlike rebuilding a path from spans, which drifts outward each time
        -- (ratchet: ±0.5 outward growth + vertex row coverage -> thin lines poke through after several rotations).
        if el.src_points then
            for _, p in ipairs(el.src_points) do
                p.x, p.y = rot(p.x, p.y)
            end
            el.spans = self:_polygonFillSpans(el.src_points)
            return
        end
        -- No src_points (tap flood fill/old saves): geometry can only be rebuilt from quantised spans.
        -- Each span is a half-row-thick rectangle [x0-0.5,x1+0.5]×[y-0.5,y+0.5].
        -- Fast path (one segment per row and contiguous rows): rebuild the region outline (vertices = row boundary points), rotate, and scan with an active edge table,
        -- handling only a constant number of active edges per row, so recomputing large fills every frame of a drag-rotate preview doesn't stutter;
        -- slow path (multiple segments/broken rows): merge vertically adjacent equal-width spans into rectangular blocks and rotate/scan block by block (same result).
        -- Shared boundaries of adjacent blocks remain shared after rotation, so no gaps between rows; overlapping/adjacent segments in the same target row are merged.
        -- The result is baked into spans (no rot field).
        local sorted = {}
        for _, sp in ipairs(el.spans) do
            table.insert(sorted, sp)
        end
        table.sort(sorted, function(a, b) return a[1] < b[1] end)
        local rows = {}
        -- Transformed path fills skip the jagged-outline fast path: per-row outlines easily self-intersect after rotation,
        -- producing dense lines detached from the boundary; the slow path re-rasterising adjacent rectangular blocks is more robust.
        local single = (not el._rasterized) and #sorted >= 2
        if single then
            for i = 2, #sorted do
                local prev, cur = sorted[i - 1], sorted[i]
                if cur[1] == prev[1] or cur[1] ~= prev[1] + 1 then
                    single = false
                    break
                end
            end
        end
        if single then
            -- Region outline: top edge -> right jagged edge -> bottom edge -> left jagged edge (closed), AET scan after rotation
            local n = #sorted
            local ymin, ymax = sorted[1][1], sorted[n][1]
            local pts = {}
            local function push(px, py)
                table.insert(pts, { px, py })
            end
            push(sorted[1][2] - 0.5, ymin - 0.5)
            push(sorted[1][3] + 0.5, ymin - 0.5)
            for i = 1, n do
                push(sorted[i][3] + 0.5, sorted[i][1] + 0.5)
            end
            push(sorted[n][2] - 0.5, ymax + 0.5)
            for i = n, 1, -1 do
                push(sorted[i][2] - 0.5, sorted[i][1] - 0.5)
            end
            for _, p in ipairs(pts) do
                p[1], p[2] = rot(p[1], p[2])
            end
            rows = shapes.polyRowsAET(pts)
        else
            -- Multiple segments/broken rows: merge equal-width adjacent rows into rectangular blocks, rotate each block and scanline-rasterise
            local blocks = {}
            for _, sp in ipairs(sorted) do
                local y, x0, x1 = sp[1], sp[2], sp[3]
                local last = blocks[#blocks]
                if last and y == last.y1 + 1 and x0 == last.x0 and x1 == last.x1 then
                    last.y1 = y
                else
                    table.insert(blocks, { y0 = y, y1 = y, x0 = x0, x1 = x1 })
                end
            end
            for _, blk in ipairs(blocks) do
                local x0, x1, y0, y1 = blk.x0 - 0.5, blk.x1 + 0.5, blk.y0 - 0.5, blk.y1 + 0.5
                local p1x, p1y = rot(x0, y0)
                local p2x, p2y = rot(x1, y0)
                local p3x, p3y = rot(x1, y1)
                local p4x, p4y = rot(x0, y1)
                local rspans = shapes.polyRowSpans({ { p1x, p1y }, { p2x, p2y }, { p3x, p3y }, { p4x, p4y } })
                for t, list in pairs(rspans) do
                    local row = rows[t]
                    if not row then
                        row = {}
                        rows[t] = row
                    end
                    for _, iv in ipairs(list) do
                        table.insert(row, iv)
                    end
                end
            end
        end
        local new_spans = {}
        for t, list in pairs(rows) do
            table.sort(list, function(a, b) return a[1] < b[1] end)
            local merged = {}
            local cur = list[1]
            for i = 2, #list do
                local s = list[i]
                if s[1] <= cur[2] + 1 then
                    cur[2] = math.max(cur[2], s[2])
                else
                    table.insert(merged, cur)
                    cur = s
                end
            end
            table.insert(merged, cur)
            for _, s in ipairs(merged) do
                table.insert(new_spans, { t, s[1], s[2] })
            end
        end
        el.spans = new_spans
        -- Mark as a rasterised fill after transform: replay applies a 1px boundary overlap to remove rounding gaps
        el._rasterized = true
    end
end

return M
