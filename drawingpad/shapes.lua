--[[--
Drawing board pure rendering primitives (shapes).

Depends only on BlitBuffer's paintRect/getWidth/getHeight, not on the UI, so it can be tested headless on its own.
Line drawing = interpolate between adjacent points + stamp the brush tip shape per point (see shapes.tip), regardless of whether BlitBuffer has drawLine.

Element structure (used for drawElement dispatch):
- freehand / eraser: { kind, points = {{x,y},...}, width, tip? }
- line:            { kind, x0, y0, x1, y1, width, tip? }
- rect:            { kind, x0, y0, x1, y1, width, filled? }
- circle:          { kind, cx, cy, r, width, filled? }

filled = true means solid (fill + outline); hollow (default) is outline only.
Colour is passed in by the caller (for a BB8 canvas, the Color8 from Blitbuffer.gray(level)).
tip (brush tip shape, brush/line only): circle/square/triangle/triangle_inv/diamond/slash/backslash,
missing/other values = circle, for backward compatibility.
--]]

local shapes = {}

-- Draw a width-sized square dot (clipped to the canvas, safe for negative coordinates/out of bounds)
function shapes.dot(bb, x, y, width, color)
    local half = math.floor(width / 2)
    local px = math.floor(x) - half
    local py = math.floor(y) - half
    local bw, bh = bb:getWidth(), bb:getHeight()
    if px + width <= 0 or py + width <= 0 or px >= bw or py >= bh then
        return -- completely outside the canvas
    end
    local x0 = math.max(px, 0)
    local y0 = math.max(py, 0)
    local x1 = math.min(px + width, bw)
    local y1 = math.min(py + width, bh)
    bb:paintRect(x0, y0, x1 - x0, y1 - y0, color)
end

-- Round brush unit: a solid circle of radius width/2 (circle tip; sample points for thick lines, removes jaggies on diagonals/circles)
function shapes.roundDot(bb, x, y, width, color)
    shapes.fillCircle(bb, x, y, math.max(0.5, width / 2), color)
end

-- Unit vector (used by v62i solid polygon inset); a zero vector returns {0,0}
local function norm2(dx, dy)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
        return 0, 0
    end
    return dx / len, dy / len
end

-- Fill an upright triangle (apex up) or inverted triangle (apex down): row scan, half-width linear from 0 at the apex to w/2 at the centre
local function fillTriangle(bb, cx, cy, w, color, inverted)
    w = math.max(2, w)
    local half = w / 2
    local y_top = cy - half
    local y0 = math.max(0, math.floor(y_top))
    local y1 = math.min(bb:getHeight() - 1, math.ceil(cy + half))
    for y = y0, y1 do
        local t = (y - y_top) / w
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local halfw = inverted and (half * (1 - t)) or (half * t)
        local x0 = math.max(0, math.ceil(cx - halfw))
        local x1 = math.min(bb:getWidth() - 1, math.floor(cx + halfw))
        if x1 >= x0 then
            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
        end
    end
end

-- Fill a diamond (square rotated 45°): row scan, half-width linear from 0 at the apex to w/2 at the centre, then narrowing again
local function fillDiamond(bb, cx, cy, w, color)
    local half = w / 2
    local y0 = math.max(0, math.floor(cy - half))
    local y1 = math.min(bb:getHeight() - 1, math.ceil(cy + half))
    for y = y0, y1 do
        local halfw = half - math.abs(y - cy)
        if halfw >= 0 then
            local x0 = math.max(0, math.ceil(cx - halfw))
            local x1 = math.min(bb:getWidth() - 1, math.floor(cx + halfw))
            if x1 >= x0 then
                bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
            end
        end
    end
end

-- Slash tip: a 45° thick line segment (backslash is the mirror); slash and backslash use a round-capped thick line one size thinner
local function fillSlash(bb, cx, cy, w, color, backslash)
    local off = w / 2
    local t = math.max(2, math.floor(w / 3))
    if backslash then
        shapes.thickLine(bb, cx - off, cy - off, cx + off, cy + off, t, color)
    else
        shapes.thickLine(bb, cx - off, cy + off, cx + off, cy - off, t, color)
    end
end

-- Brush tip shape dispatch: draw a tip of width width at (x,y) (everything clipped to the canvas)
function shapes.tip(bb, x, y, width, color, tip)
    if tip == "square" then
        shapes.dot(bb, x, y, width, color)
    elseif tip == "triangle" then
        fillTriangle(bb, x, y, width, color, false)
    elseif tip == "triangle_inv" then
        fillTriangle(bb, x, y, width, color, true)
    elseif tip == "diamond" then
        fillDiamond(bb, x, y, width, color)
    elseif tip == "slash" then
        fillSlash(bb, x, y, width, color, false)
    elseif tip == "backslash" then
        fillSlash(bb, x, y, width, color, true)
    else
        shapes.roundDot(bb, x, y, width, color) -- circle is the default
    end
end

-- Scanline fill for a thick line segment: strip (two parallel edges offset width/2 on each side of the segment) + round caps at both ends,
-- merge x intervals per row then fill. Compared with building lines from "sampled round dots", edges are smooth - no dashed first row/scalloped jaggies
-- at the boundary from dot sampling (the root cause of "severe jaggies" on thick-line squares). Diagonals/circles/strokes benefit too.
-- When the endpoints degenerate (length≈0), draw a solid circle
function shapes.thickLineFill(bb, x0, y0, x1, y1, width, color)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then
        shapes.fillCircle(bb, x0, y0, math.max(0.5, width / 2), color)
        return
    end
    local r = math.max(0.5, width / 2)
    local ux, uy = dx / len, dy / len -- unit direction
    local nx, ny = -uy, ux -- unit normal
    local rnx, rny = nx * r, ny * r
    local y_min = math.max(0, math.floor(math.min(y0, y1) - r))
    local y_max = math.min(bb:getHeight() - 1, math.ceil(math.max(y0, y1) + r))
    local bw = bb:getWidth() - 1
    -- Middle strip = parallelogram [A+nr, B+nr, B-nr, A-nr], covering the full segment length (including the bevelled areas at both ends).
    -- Per row, compute the interval of the scanline's intersections with the four edges - filling only the middle section "spanned by both offset edges"
    -- leaves the strip body missing near both ends of the segment, exposing V-shaped notches at the corners of angled rectangles (root cause of "weird" results after rotation)
    -- Performance (v62p): edge endpoints and slopes are precomputed outside the row loop - previously each row created an addEdge closure
    -- (1 closure allocation + 4 calls + 4 divisions per row); rendering a whole thick stroke calls this function per segment,
    -- with dozens of rows per segment, so closure overhead dominated
    local e1x, e1y, e1lo, e1hi, e1s, e2x, e2y, e2lo, e2hi, e2s, e3x, e3y, e3lo, e3hi, e3s, e4x, e4y, e4lo, e4hi, e4s
    local has_edges = dy ~= 0
    if has_edges then
        local function edge(px, py, qx, qy)
            -- Returns px, py, y-range min, y-range max, slope; horizontal edges have no intersection, slope set to nil so the row loop skips them
            if py == qy then
                return px, py, py, py, nil
            end
            local ylo, yhi = py, qy
            if qy < py then ylo, yhi = qy, py end
            return px, py, ylo, yhi, (qx - px) / (qy - py)
        end
        -- Four edges: upper offset edge A+nr→B+nr, end edge B+nr→B-nr, lower offset edge B-nr→A-nr, end edge A-nr→A+nr
        e1x, e1y, e1lo, e1hi, e1s = edge(x0 + rnx, y0 + rny, x1 + rnx, y1 + rny)
        e2x, e2y, e2lo, e2hi, e2s = edge(x1 + rnx, y1 + rny, x1 - rnx, y1 - rny)
        e3x, e3y, e3lo, e3hi, e3s = edge(x1 - rnx, y1 - rny, x0 - rnx, y0 - rny)
        e4x, e4y, e4lo, e4hi, e4s = edge(x0 - rnx, y0 - rny, x0 + rnx, y0 + rny)
    end
    for y = y_min, y_max do
        local x_lo, x_hi = math.huge, -math.huge
        -- End-cap discs (start/end point)
        local h0 = r * r - (y - y0) * (y - y0)
        if h0 >= 0 then
            local h = math.sqrt(h0)
            if x0 - h < x_lo then x_lo = x0 - h end
            if x0 + h > x_hi then x_hi = x0 + h end
        end
        local h1 = r * r - (y - y1) * (y - y1)
        if h1 >= 0 then
            local h = math.sqrt(h1)
            if x1 - h < x_lo then x_lo = x1 - h end
            if x1 + h > x_hi then x_hi = x1 + h end
        end
        if has_edges then
            local x_lo2, x_hi2 = math.huge, -math.huge
            if e1s and y >= e1lo - 0.001 and y <= e1hi + 0.001 then
                local x = e1x + (y - e1y) * e1s
                if x < x_lo2 then x_lo2 = x end
                if x > x_hi2 then x_hi2 = x end
            end
            if e2s and y >= e2lo - 0.001 and y <= e2hi + 0.001 then
                local x = e2x + (y - e2y) * e2s
                if x < x_lo2 then x_lo2 = x end
                if x > x_hi2 then x_hi2 = x end
            end
            if e3s and y >= e3lo - 0.001 and y <= e3hi + 0.001 then
                local x = e3x + (y - e3y) * e3s
                if x < x_lo2 then x_lo2 = x end
                if x > x_hi2 then x_hi2 = x end
            end
            if e4s and y >= e4lo - 0.001 and y <= e4hi + 0.001 then
                local x = e4x + (y - e4y) * e4s
                if x < x_lo2 then x_lo2 = x end
                if x > x_hi2 then x_hi2 = x end
            end
            if x_hi2 >= x_lo2 then
                if x_lo2 < x_lo then x_lo = x_lo2 end
                if x_hi2 > x_hi then x_hi = x_hi2 end
            end
        else
            -- Horizontal segment: strip body = full width [x0,x1] (end-cap discs already merged in)
            if math.abs(y - y0) <= r then
                if x0 < x_lo then x_lo = x0 end
                if x1 > x_hi then x_hi = x1 end
            end
        end
        if x_hi >= x_lo then
            local xa = math.max(0, math.floor(x_lo))
            local xb = math.min(bw, math.ceil(x_hi))
            if xb >= xa then
                bb:paintRect(xa, y, xb - xa + 1, 1, color)
            end
        end
    end
end

-- Thick line segment: circle uses the scanline strip fill (smooth edges); non-circle tips are stamped along the segment at ~width/2 spacing
-- (keeping the shape recognisable yet continuous). tip defaults to circle, for backward compatibility
function shapes.thickLine(bb, x0, y0, x1, y1, width, color, tip)
    width = width or 4
    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.001 then
        shapes.tip(bb, x0, y0, width, color, tip)
        return
    end
    if tip ~= nil and tip ~= "circle" then
        local step = math.max(2, math.floor(width / 2))
        local n = math.max(1, math.ceil(dist / step))
        for i = 0, n do
            local t = i / n
            shapes.tip(bb, x0 + dx * t, y0 + dy * t, width, color, tip)
        end
        return
    end
    shapes.thickLineFill(bb, x0, y0, x1, y1, width, color)
end

-- Catmull-Rom spline segment P1→P2 (interpolating through points, tangent-continuous): P0/P3 are the neighbours on each side and set the end tangents;
-- outside the ends the adjacent point is duplicated (P0=P1 or P3=P2). Sampled at ~2px arc length into short thickLines
-- (round tips keep segments seamless). Compared with midpoint quadratic curves (approximately a quadratic B-spline, which cuts corners at every sample point),
-- interpolating through points stays smooth on sparsely sampled closed curves (small circles) - 8~10 sample points are enough to draw a circle.
-- Collinear control points degenerate to a straight line; zero-length segments are safe (t=0 starts at P1).
function shapes.crSegment(bb, p0, p1, p2, p3, width, color, tip)
    local approx = math.abs(p1.x - p2.x) + math.abs(p1.y - p2.y)
    local steps = math.max(2, math.min(64, math.floor(approx / 2)))
    local px = math.floor(p1.x)
    local py = math.floor(p1.y)
    for i = 1, steps do
        local t = i / steps
        local t2 = t * t
        local t3 = t2 * t
        local qx = math.floor(0.5 * (2 * p1.x + (-p0.x + p2.x) * t
            + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
            + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3))
        local qy = math.floor(0.5 * (2 * p1.y + (-p0.y + p2.y) * t
            + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
            + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3))
        if qx ~= px or qy ~= py then
            shapes.thickLine(bb, px, py, qx, qy, width, color, tip)
            px, py = qx, qy
        end
    end
end

-- Polyline (freehand brush/eraser); ox/oy is the overall offset (used when the preview is drawn on the screen BB).
-- Catmull-Rom smoothing through points: first-point tip -> one segment cr(P[i-1],P[i],P[i+1],P[i+2]) per adjacent pair
-- (end neighbours clamped to the first/last point), so the curve passes exactly through every sample point.
-- Segment-for-segment identical to the incremental rendering in strokes.lua (_renderStrokeTail/_renderStrokeClose):
-- the live stroke and the redraw are exactly the same.
function shapes.polyline(bb, points, width, color, ox, oy, tip)
    ox = ox or 0
    oy = oy or 0
    local n = #points
    if n == 0 then return end
    if n == 1 then
        shapes.tip(bb, points[1].x + ox, points[1].y + oy, width, color, tip)
        return
    end
    -- Start-point tip (full width: full width from pen-down, so small arcs at the start are clearly visible)
    shapes.tip(bb, points[1].x + ox, points[1].y + oy, width, color, tip)
    for i = 1, n - 1 do
        local p0 = points[math.max(1, i - 1)]
        local p1 = points[i]
        local p2 = points[i + 1]
        local p3 = points[math.min(n, i + 2)]
        shapes.crSegment(bb,
            { x = p0.x + ox, y = p0.y + oy },
            { x = p1.x + ox, y = p1.y + oy },
            { x = p2.x + ox, y = p2.y + oy },
            { x = p3.x + ox, y = p3.y + oy },
            width, color, tip)
    end
end

-- Rectangle frame (outline only): 4 thick edges
function shapes.rect(bb, x0, y0, x1, y1, width, color, tip)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    shapes.thickLine(bb, xa, ya, xb, ya, width, color, tip)
    shapes.thickLine(bb, xb, ya, xb, yb, width, color, tip)
    shapes.thickLine(bb, xb, yb, xa, yb, width, color, tip)
    shapes.thickLine(bb, xa, yb, xa, ya, width, color, tip)
end

-- Ellipse outline: annulus scanline fill (fill rows between the outer ellipse rx+w/2 and the inner ellipse rx-w/2).
-- Smoother than "thick lines joining perimeter samples" - continuous outline at any rotation/line width, no polygonised sampling jaggies.
-- The x interval of a rotated ellipse on a scanline is solved from the local ellipse equation A·dx²+B·dx+C≤0.
function shapes.ellipse(bb, cx, cy, rx, ry, width, color, tip, rot)
    rx = math.max(0.5, rx or 1)
    ry = math.max(0.5, ry or rx)
    if rx < 1 and ry < 1 then
        shapes.tip(bb, cx, cy, width, color, tip)
        return
    end
    if tip ~= nil and tip ~= "circle" then
        -- Non-circle tip (brush drawing a circle): keep the old perimeter-sample polyline
        local cosr, sinr = math.cos(rot or 0), math.sin(rot or 0)
        local function point(a)
            local px, py = cx + rx * math.cos(a), cy + ry * math.sin(a)
            local dx, dy = px - cx, py - cy
            return cx + dx * cosr - dy * sinr, cy + dx * sinr + dy * cosr
        end
        local step = math.max(2, math.floor(width / 2))
        local n = math.max(24, math.ceil(2 * math.pi * math.max(rx, ry) / step))
        local prev_x, prev_y = point(0)
        for i = 1, n do
            local a = 2 * math.pi * i / n
            local px, py = point(a)
            shapes.thickLine(bb, prev_x, prev_y, px, py, width, color, tip)
            prev_x, prev_y = px, py
        end
        return
    end
    -- Annulus: outer ellipse = rx+w/2, inner ellipse = rx-w/2 (degenerates to solid when too thin)
    local w2 = math.max(0.5, width / 2)
    local ro_rx, ro_ry = rx + w2, ry + w2
    local ri_rx, ri_ry = math.max(0.2, rx - w2), math.max(0.2, ry - w2)
    local cosr, sinr = math.cos(rot or 0), math.sin(rot or 0)
    local c2, s2 = cosr * cosr, sinr * sinr
    -- Outer ellipse AABB half-height (rotated): sqrt(ro_rx²·s² + ro_ry²·c²)
    local half_h = math.sqrt(ro_rx * ro_rx * s2 + ro_ry * ro_ry * c2)
    local y_min = math.max(0, math.floor(cy - half_h))
    local y_max = math.min(bb:getHeight() - 1, math.ceil(cy + half_h))
    local bw = bb:getWidth() - 1
    for y = y_min, y_max do
        local dy = y - cy
        local function xInterval(a_rx, a_ry)
            local A = c2 / (a_rx * a_rx) + s2 / (a_ry * a_ry)
            local B = 2 * dy * cosr * sinr * (1 / (a_rx * a_rx) - 1 / (a_ry * a_ry))
            local C = dy * dy * (s2 / (a_rx * a_rx) + c2 / (a_ry * a_ry)) - 1
            local disc = B * B - 4 * A * C
            if disc < 0 then
                return nil
            end
            local sq = math.sqrt(disc)
            return (-B - sq) / (2 * A), (-B + sq) / (2 * A)
        end
        local o_lo, o_hi = xInterval(ro_rx, ro_ry)
        if o_lo then
            local i_lo, i_hi = xInterval(ri_rx, ri_ry)
            if not i_lo then
                -- xInterval returns dx relative to the centre; add cx to convert to absolute x
                local xa = math.max(0, math.floor(cx + o_lo))
                local xb = math.min(bw, math.ceil(cx + o_hi))
                if xb >= xa then
                    bb:paintRect(xa, y, xb - xa + 1, 1, color)
                end
            else
                if o_lo < i_lo then
                    local xa = math.max(0, math.floor(cx + o_lo))
                    local xb = math.min(bw, math.ceil(cx + i_lo))
                    if xb >= xa then
                        bb:paintRect(xa, y, xb - xa + 1, 1, color)
                    end
                end
                if o_hi > i_hi then
                    local xa = math.max(0, math.floor(cx + i_hi))
                    local xb = math.min(bw, math.ceil(cx + o_hi))
                    if xb >= xa then
                        bb:paintRect(xa, y, xb - xa + 1, 1, color)
                    end
                end
            end
        end
    end
end

function shapes.circle(bb, cx, cy, r, width, color, tip)
    shapes.ellipse(bb, cx, cy, r, r, width, color, tip, 0)
end

-- Solid rectangle: fill the normalised region (clipped to the canvas)
function shapes.fillRect(bb, x0, y0, x1, y1, color)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    xa, ya = math.max(math.floor(xa), 0), math.max(math.floor(ya), 0)
    xb, yb = math.min(math.ceil(xb), bb:getWidth() - 1), math.min(math.ceil(yb), bb:getHeight() - 1)
    if xb < xa or yb < ya then
        return
    end
    bb:paintRect(xa, ya, xb - xa + 1, yb - ya + 1, color)
end

-- Solid circle: row-scan fill (clipped to the canvas)
function shapes.fillCircle(bb, cx, cy, r, color)
    shapes.fillEllipse(bb, cx, cy, r, r, color)
end

-- Solid ellipse (unrotated): row-scan fill (clipped to the canvas)
function shapes.fillEllipse(bb, cx, cy, rx, ry, color)
    rx = math.max(1, rx)
    ry = math.max(1, ry)
    local min_y = math.max(0, math.floor(cy - ry))
    local max_y = math.min(bb:getHeight() - 1, math.ceil(cy + ry))
    for y = min_y, max_y do
        local t = (y - cy) / ry
        local half = rx * math.sqrt(math.max(0, 1 - t * t))
        local x0 = math.max(0, math.floor(cx - half))
        local x1 = math.min(bb:getWidth() - 1, math.ceil(cx + half))
        if x1 >= x0 then
            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
        end
    end
end

-- Solid ellipse (any rotation): densely sampled at ~1px/point of perimeter into a polygon and scanline-filled (even-odd pairing),
-- looking the same as fillEllipse; solid shapes stretched into rotated ellipses no longer degrade to outlines.
function shapes.fillRotatedEllipse(bb, cx, cy, rx, ry, rot, color)
    rx = math.max(1, rx)
    ry = math.max(1, ry)
    -- Sample count ≈ perimeter (rough approximation of 2π·√((rx²+ry²)/2), computed as (rx+ry)·π/2), clamped to 32~512
    local n = math.max(32, math.min(512, math.ceil((rx + ry) * 1.6)))
    local c, s = math.cos(rot), math.sin(rot)
    local pts = {}
    for i = 1, n do
        local t = (i - 1) / n * 2 * math.pi
        local ex, ey = rx * math.cos(t), ry * math.sin(t)
        pts[i] = { cx + ex * c - ey * s, cy + ex * s + ey * c }
    end
    local bw, bh = bb:getWidth(), bb:getHeight()
    local rows = shapes.polyRowSpans(pts)
    for y, list in pairs(rows) do
        if y >= 0 and y < bh then
            for _, iv in ipairs(list) do
                local x0 = math.max(0, iv[1])
                local x1 = math.min(bw - 1, iv[2])
                if x1 >= x0 then
                    bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
                end
            end
        end
    end
end

-- Per-row scanline rasterisation of a polygon (even-odd pairing): returns { [row] = { {xa, xb}, ... }, ... },
-- with each row's intervals sorted by ascending x (same rounding rules as _polygonFillSpans: ceil(x-0.5)/floor(x+0.5)).
-- Used when rotating a fill to re-rasterise each span's rotated parallelogram band back into a span list (geometry._rotateElement).
-- Input points are {x, y} arrays (avoids depending on the element point-list structure)
function shapes.polyRowSpans(pts)
    local rows = {}
    local n = #pts
    if n < 3 then
        return rows
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < y_min then y_min = p[2] end
        if p[2] > y_max then y_max = p[2] end
    end
    for y = math.floor(y_min), math.ceil(y_max) do
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            if (a[2] <= y and b[2] > y) or (b[2] <= y and a[2] > y) then
                table.insert(xs, a[1] + (y - a[2]) * (b[1] - a[1]) / (b[2] - a[2]))
            end
        end
        table.sort(xs)
        local list = {}
        local i = 1
        while i < #xs do
            local x0 = math.ceil(xs[i] - 0.5)
            local x1 = math.floor(xs[i + 1] + 0.5)
            if x1 >= x0 then
                table.insert(list, { x0, x1 })
            end
            i = i + 2
        end
        if #list > 0 then
            rows[y] = list
        end
    end
    return rows
end

-- Polygon active edge table (AET) scanline rasterisation: returns { [row] = { {xa, xb}, ... }, ... }.
-- Same result as polyRowSpans, but each edge is processed only once over its y range, and each row only walks the active edges
-- (edges crossing that row, usually 2-4) - when rotating a fill with a jagged outline (vertices = per-row boundary points, hundreds to thousands of edges)
-- the cost of row-by-row scanning drops from O(edges×rows) to O(edges+rows×active edges), so drag-rotating a large fill doesn't stutter.
-- Input points are {x, y} arrays (closed polygon); horizontal edges are skipped; collinear edges joined end to end are merged when building the edge table
-- (vertical jagged edges of a fill outline overlap into one after rotating 90°/180°; without merging they'd be double-counted at vertices);
-- edges cover the closed interval [y0,y1] - vertex rows also get coverage, so the rasterisation is stable after a 180° rotation
-- (a half-open interval would drop the top row, and the bbox would jitter after rotation flips it).
function shapes.polyRowsAET(pts)
    local rows = {}
    local n = #pts
    if n < 3 then
        return rows
    end
    local edges = {}
    local function add_edge(a, b)
        local dy = b[2] - a[2]
        if math.abs(dy) < 1e-9 then
            return -- horizontal/near-horizontal edges don't take part in intersections (a near-horizontal edge has dy≈0 -> huge slope;
            -- taking part in collinear merging would amplify floating-point error, producing astronomical x0 shifts/intersections)
        end
        local y0, y1 = a[2], b[2]
        local x0 = a[1]
        if y0 > y1 then
            y0, y1, x0 = y1, y0, b[1]
        end
        local slope = (b[1] - a[1]) / dy
        local last = edges[#edges]
        -- Joined end to end with the previous edge (adjacent in the vertex sequence) and same slope = collinear, merge into one.
        -- Connection is judged by vertex sequence (after normalising y0/y1 the direction of adjacent edges may flip, so y continuity can't be used);
        -- after merging the y range takes min/max, and x0 is shifted to the new y0 (x = x0 + slope*(y-y0))
        if last and last.ex == a[1] and last.ey == a[2]
            and math.abs(last.slope - slope) < 1e-9 then
            local ny0 = math.min(last.y0, y0)
            local ny1 = math.max(last.y1, y1)
            last.x0 = last.x0 + last.slope * (ny0 - last.y0)
            last.y0, last.y1 = ny0, ny1
            last.ex, last.ey = b[1], b[2]
        else
            table.insert(edges, { y0 = y0, y1 = y1, x0 = x0, slope = slope, ex = b[1], ey = b[2] })
        end
    end
    for i = 1, n do
        add_edge(pts[i], pts[(i % n) + 1])
    end
    if #edges < 2 then
        return rows
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[2] < y_min then y_min = p[2] end
        if p[2] > y_max then y_max = p[2] end
    end
    table.sort(edges, function(a, b) return a.y0 < b.y0 end)
    local eidx = 1
    local aet = {}
    for t = math.floor(y_min), math.ceil(y_max) do
        local tt = t + 0.5 -- row centre
        -- 1) Remove finished edges (closed interval: ends when y1 < tt)
        local w = 1
        for i = 1, #aet do
            local e = aet[i]
            if e.y1 >= tt then
                aet[w] = e
                w = w + 1
            end
        end
        for i = #aet, w, -1 do
            aet[i] = nil
        end
        -- 2) Add new edges (intersections on the current row)
        while eidx <= #edges and edges[eidx].y0 <= tt do
            local e = edges[eidx]
            e.xcur = e.x0 + (tt - e.y0) * e.slope
            table.insert(aet, e)
            eidx = eidx + 1
        end
        -- 3) Output the current row's intervals in pairs
        if #aet >= 2 then
            table.sort(aet, function(p, q) return p.xcur < q.xcur end)
            local list = {}
            local i = 1
            while i < #aet do
                local xa = math.ceil(aet[i].xcur - 0.5)
                local xb = math.floor(aet[i + 1].xcur + 0.5)
                if xb >= xa then
                    table.insert(list, { xa, xb })
                end
                i = i + 2
            end
            if #list > 0 then
                rows[t] = list
            end
        end
        -- 4) Advance active edge x to the next row (edges added this round were already output and must not be advanced again, or intersections run one row ahead)
        for i = 1, #aet do
            aet[i].xcur = aet[i].xcur + aet[i].slope
        end
    end
    return rows
end

-- Semi-transparent rendering proxy: intercepts paintRect and truly blends the ink colour by alpha (0-1) onto the target BB's existing pixels
-- (dest = α·ink + (1-α)·dest): on white it simply lightens, over ink it lets the layer below show through (plain grey can't do this).
-- All shapes primitives use only paintRect/getWidth/getHeight (see file header), so wrapping in the proxy works for every element.
-- Coordinates/clipping/negative offsets are left to real:paintRect natively; blending uses the per-pixel setPixelBlend setter.
-- ponytail: per-pixel Lua setter, a large full-canvas fill takes ~0.1s (only once on commit/redraw); switch to a getPixelP pointer loop if not fast enough
-- Blend modes (greyscale canvas, ink = ink grey 0 black~255 white, d = destination pixel, a255 = opacity 0-255):
--   normal   straight alpha: out = d + a·(ink-d) (native setPixelBlend, doesn't read dest)
--   multiply multiply: out = (1-a)·d + a·ink·d/255 - ink multiplies with the layer below, getting darker as it stacks
--   dodge    linear dodge: out = (1-a)·d + a·min(255, ink+d) - additive lightening, dark ink barely changes
-- multiply/dodge must read dest, so they can only be per-pixel Lua (blendModePixel); callers must ensure bb is
-- a BB8 canvas/region temp BB (_alphaBB already type-guards; the screen preview BB falls back to opaque/normal)
function shapes.blendModePixel(bb, x, y, ink, a255, mode)
    local Blitbuffer = require("ffi/blitbuffer")
    local d = bb:getPixel(x, y).a
    local out
    if mode == "multiply" then
        out = d * (65025 - a255 * (255 - ink)) / 65025
    elseif mode == "dodge" then
        local add = ink + d
        if add > 255 then add = 255 end
        out = (d * (255 - a255) + add * a255) / 255
    else
        out = (d * (255 - a255) + ink * a255) / 255
    end
    out = math.floor(out + 0.5)
    if out < 0 then out = 0 elseif out > 255 then out = 255 end
    bb:setPixel(x, y, Blitbuffer.Color8(out))
end

-- Blend mode fast path (v63b): for fixed (ink, a255, mode), out depends only on the dest byte (0-255)
-- -> precompute a 256-entry lookup table (uint8 array), so the blend loop makes zero FFI function calls per pixel.
-- The expressions match blendModePixel term by term (same multiply/divide order, same floating-point points), with an assertion over all 256 values
function shapes.buildBlendLUT(mode, ink, a255)
    local ffi = require("ffi")
    local lut = ffi.new("uint8_t[256]")
    local na = 255 - a255
    if mode == "multiply" then
        for d = 0, 255 do
            local out = math.floor(d * (65025 - a255 * (255 - ink)) / 65025 + 0.5)
            if out < 0 then out = 0 elseif out > 255 then out = 255 end
            lut[d] = out
        end
    elseif mode == "dodge" then
        for d = 0, 255 do
            local add = ink + d
            if add > 255 then add = 255 end
            local out = math.floor((d * na + add * a255) / 255 + 0.5)
            if out < 0 then out = 0 elseif out > 255 then out = 255 end
            lut[d] = out
        end
    else
        for d = 0, 255 do
            local out = math.floor((d * na + ink * a255) / 255 + 0.5)
            if out < 0 then out = 0 elseif out > 255 then out = 255 end
            lut[d] = out
        end
    end
    return lut
end

-- LUT row blend: BB8 (BlitBuffer8) pixels = Color8 (1 byte) laid out contiguously; cast to uint8_t*
-- and then row[x] is read/written directly as a number, zero FFI function calls.
-- Caller guarantees real is BB8, rotation=0, inverse=0 (see the drawFilledAlpha/alphaProxy guards)
function shapes.blendRowLUT(real, x0, x1, y, lut)
    local ffi = require("ffi")
    local row = ffi.cast("uint8_t*", real.data) + real.stride * y
    for x = x0, x1 do
        row[x] = lut[row[x]]
    end
end

-- Semi-transparent rendering proxy: intercepts paintRect and truly blends the ink colour by alpha (0-1) onto the target BB's existing pixels
-- (dest = α·ink + (1-α)·dest): on white it simply lightens, over ink it lets the layer below show through (plain grey can't do this).
-- All shapes primitives use only paintRect/getWidth/getHeight (see file header), so wrapping in the proxy works for every element.
-- Coordinates/clipping/negative offsets are left to real:paintRect natively; blending uses the per-pixel setPixelBlend setter.
-- mode (optional, default normal) = opacity blend mode, see blendModePixel; all three modes use
-- the BB8 pointer row blend + LUT (guarded on rotation/inverse, falling back to the native per-pixel setter in unusual cases)
-- ponytail: the fast path makes zero FFI calls per pixel; the slow path (native setter) is only for rotated/inverse canvases
function shapes.alphaProxy(real, alpha, mode)
    local Blitbuffer = require("ffi/blitbuffer")
    local a255 = math.max(0, math.min(255, math.floor(alpha * 255 + 0.5)))
    local blend_setter = real.setPixelBlend
    -- Single-slot LUT cache: ink is constant within one element, so stroke fill's per-row paintRect doesn't rebuild it
    local lut, lut_ink
    return {
        __dp_alpha = a255, -- semi-transparency marker (used by drawFilledAlpha, paired with __dp_real)
        __dp_real = real, -- used for single-pass compositing of semi-transparent solid shapes
        __dp_blend = mode or "normal", -- blend mode (shared by drawFilledAlpha/text write-back)
        getWidth = function() return real:getWidth() end,
        getHeight = function() return real:getHeight() end,
        paintRect = function(_, x, y, w, h, value)
            local v = value:getColor8()
            if real:getRotation() == 0 and real:getInverse() == 0 then
                local ink = v.a
                if lut_ink ~= ink then
                    lut = shapes.buildBlendLUT(mode, ink, a255)
                    lut_ink = ink
                end
                -- Manual clipping (mimics getBoundedRect: the self-built BB8 canvas has no rotation, canvas coordinates map identically)
                local rw, rh = real:getWidth(), real:getHeight()
                local X0, Y0 = x, y
                local X1, Y1 = x + w - 1, y + h - 1
                if X0 < 0 then X0 = 0 end
                if Y0 < 0 then Y0 = 0 end
                if X1 > rw - 1 then X1 = rw - 1 end
                if Y1 > rh - 1 then Y1 = rh - 1 end
                for yy = Y0, Y1 do
                    shapes.blendRowLUT(real, X0, X1, yy, lut)
                end
            else
                real:paintRect(x, y, w, h, Blitbuffer.Color8A(v.a, a255), blend_setter)
            end
        end,
    }
end

-- Draw by element type (shared by canvas replay and screen preview); colour is passed in by the caller, ox/oy is the overall offset

-- Single-pass compositing for semi-transparent elements (solid rect/poly/circle + freehand/eraser/line strokes) (v62j/v62q):
-- drawing fill + outline directly overlaps in many places (outline over the fill boundary, corner outline strips overlapping + small round-cap discs);
-- strokes blend in ~2px segments whose round caps overlap heavily, applying alpha repeatedly where they overlap -> strokes come out
-- noticeably more opaque than a path fill of the same alpha (single per-pixel blend). Both get the same fix: draw everything into a temp BB
-- (opaque overwrite inside, so overlaps don't matter), then alpha-blend it per pixel onto the real canvas in one pass -> a single opacity.
-- ponytail: each replay is an O(element area) Lua pixel loop; if many large semi-transparent elements make region replays laggy on the real device,
-- cache the composited result per element
function shapes.drawFilledAlpha(bb, el, color, ox, oy)
    local Blitbuffer = require("ffi/blitbuffer")
    local real, a255 = bb.__dp_real, bb.__dp_alpha
    ox, oy = ox or 0, oy or 0
    local kind = el.kind
    local x0, y0, x1, y1
    -- bbox must include ox/oy: region replay draws with a negative offset on a "region-sized temp BB"; leaving it out
    -- clamps to the wrong range -> semi-transparent shapes disappear/are partially shown after a move
    if kind == "rect" then
        x0, x1 = math.min(el.x0, el.x1) + ox, math.max(el.x0, el.x1) + ox
        y0, y1 = math.min(el.y0, el.y1) + oy, math.max(el.y0, el.y1) + oy
    elseif kind == "line" then
        x0, x1 = math.min(el.x0, el.x1) + ox, math.max(el.x0, el.x1) + ox
        y0, y1 = math.min(el.y0, el.y1) + oy, math.max(el.y0, el.y1) + oy
    elseif kind == "circle" then
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        -- Axis-aligned half-width/half-height of a rotated ellipse: √(rx²sin²+ry²cos²) / √(rx²cos²+ry²sin²)
        -- (after squashing rx≠ry, and at 90° rotation the vertical projection can reach rx; using only ry would clip top and bottom)
        local rot = el.rot or 0
        local cs, sn = math.cos(rot), math.sin(rot)
        local hw = math.sqrt(rx * rx * cs * cs + ry * ry * sn * sn)
        local hh = math.sqrt(rx * rx * sn * sn + ry * ry * cs * cs)
        x0, x1 = el.cx - hw + ox, el.cx + hw + ox
        y0, y1 = el.cy - hh + oy, el.cy + hh + oy
    else
        x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(el.points) do
            if p.x + ox < x0 then x0 = p.x + ox end
            if p.x + ox > x1 then x1 = p.x + ox end
            if p.y + oy < y0 then y0 = p.y + oy end
            if p.y + oy > y1 then y1 = p.y + oy end
        end
    end
    -- Maximum radius of the brush tip shape beyond the sample point (one side, as a factor of width): circle/diamond=0.5;
    -- square/triangle base corners=0.71; slash/backslash = diagonal 0.707w + strip t/2 (max(2,w/3)) ≈0.87.
    -- The old pad (0.5w+2) was enough for circle/diamond, but wide slash tips got clipped by tmp -> stroke corners cut off
    -- (any opacity other than 100% goes through tmp compositing, regardless of the opacity value)
    local TIP_PAD = { slash = 0.88, backslash = 0.88, square = 0.72, triangle = 0.72, triangle_inv = 0.72 }
    local pad = (el.width or 1) * (TIP_PAD[el.tip] or 0.5) + 2
    x0, y0 = math.floor(x0 - pad), math.floor(y0 - pad)
    x1, y1 = math.ceil(x1 + pad), math.ceil(y1 + pad)
    local cw, ch = real:getWidth(), real:getHeight()
    x0, y0 = math.max(0, x0), math.max(0, y0)
    x1, y1 = math.min(cw - 1, x1), math.min(ch - 1, y1)
    if x1 < x0 or y1 < y0 then
        return
    end
    local tmp = Blitbuffer.new(x1 - x0 + 1, y1 - y0 + 1, Blitbuffer.TYPE_BB8)
    tmp:fill(Blitbuffer.COLOR_WHITE)
    -- tmp is a real BB (no __dp_alpha) -> recursion takes the opaque path, overlaps are overwritten opaquely
    shapes.drawElement(tmp, el, color, ox - x0, oy - y0)
    local ink = color:getColor8().a
    -- Blend mode: recorded with the proxy (per-element, region redraws reproduce it consistently); all three modes use LUTs
    -- (the normal formula also depends only on the dest byte, so the fast path is ~6x faster than the native setPixelBlend setter callback)
    local mode = bb.__dp_blend or "normal"
    if real:getRotation() == 0 and real:getInverse() == 0 then
        -- Fast path (v63b/c): both the tmp mask and dest have BB8 byte layout, direct pointer read/write + 256-entry LUT,
        -- zero FFI calls per pixel - after stacking many layers, the per-pixel Lua callbacks in the O(layers×area) pen-up region replay
        -- were the main cause of stutter (baseline 8 layers 400×400 intersecting replay 185ms -> see blend_bench for the fast path)
        local lut = shapes.buildBlendLUT(mode, ink, a255)
        -- BlitBuffer8.data is Color8* (a 1-byte struct); after casting to uint8_t* it is read/written as numbers
        local ffi = require("ffi")
        local tbase = ffi.cast("uint8_t*", tmp.data)
        local rbase = ffi.cast("uint8_t*", real.data)
        for ty = 0, y1 - y0 do
            local trow = tbase + tmp.stride * ty
            local rrow = rbase + real.stride * (ty + y0)
            for tx = 0, x1 - x0 do
                if trow[tx] ~= 255 then
                    local rx = tx + x0
                    rrow[rx] = lut[rrow[rx]]
                end
            end
        end
        tmp:free()
        return
    end
    -- Fallback for rotated/inverse cases: per-pixel setter (all three modes)
    local C8A, spb = Blitbuffer.Color8A, real.setPixelBlend
    for ty = 0, y1 - y0 do
        local sy = ty + y0
        for tx = 0, x1 - x0 do
            if tmp:getPixel(tx, ty).a ~= 255 then
                if mode == "multiply" or mode == "dodge" then
                    shapes.blendModePixel(real, tx + x0, sy, ink, a255, mode)
                else
                    spb(real, tx + x0, sy, C8A(ink, a255))
                end
            end
        end
    end
    tmp:free()
end

function shapes.drawElement(bb, el, color, ox, oy)
    local kind = el.kind
    -- v62j: semi-transparent solid shapes use single-pass compositing (see drawFilledAlpha; during tmp recursion bb is a real BB and doesn't enter this branch)
    if el.filled and (kind == "rect" or kind == "poly" or kind == "circle")
        and type(bb) == "table" and bb.__dp_real and bb.__dp_alpha and bb.__dp_alpha < 255 then
        return shapes.drawFilledAlpha(bb, el, color, ox, oy)
    end
    -- v62q: semi-transparent strokes (freehand/eraser/line) are also composited in a single pass - per-segment blending repeatedly applies alpha
    -- where round caps overlap between segments, making strokes noticeably more opaque than a path fill of the same alpha
    if (kind == "freehand" or kind == "eraser" or kind == "line")
        and type(bb) == "table" and bb.__dp_real and bb.__dp_alpha and bb.__dp_alpha < 255 then
        return shapes.drawFilledAlpha(bb, el, color, ox, oy)
    end
    if kind == "fill" then
        -- Flood-fill result: rewrite span by span per row (region redraw/undo replay restores it exactly).
        -- Iterate the spans directly: spans on different rows don't affect each other (segments on the same row don't overlap), so no need to group by row
        -- and sort - the old version built a small table per row + sorted, so a full background fill (thousands of rows) did thousands of
        -- allocations per replay; with many elements and a replay on every stroke commit, on the real device that meant "refresh slows down as strokes pile up"
        ox = ox or 0
        oy = oy or 0
        local bw, bh = bb:getWidth(), bb:getHeight()
        local spans = el.spans
        for i = 1, #spans do
            local sp = spans[i]
            local yy = sp[1] + oy
            if yy >= 0 and yy < bh then
                local xa = math.floor(sp[2]) + ox
                local xb = math.floor(sp[3]) + ox
                if xa < 0 then xa = 0 end
                if xb > bw - 1 then xb = bw - 1 end
                if xb >= xa then
                    bb:paintRect(xa, yy, xb - xa + 1, 1, color)
                end
            end
        end
    elseif kind == "freehand" or kind == "eraser" then
        shapes.polyline(bb, el.points, el.width, color, ox, oy, el.tip)
    elseif kind == "poly" then
        -- Polygon (rotated rectangle): solid ones are scanline-filled first (v61k: no longer degrade to hollow), then the closed outline is drawn
        local pts = el.points
        local n = #pts
        -- v62i: semi-transparent solid = fill inset by half the line width, otherwise the outline stacked on the fill double-blends (alpha applied twice
        -- ≈ 1-(1-a)²) and shows a dark outline; after the inset the fill and outline strip meet without overlapping. Opaque is unchanged
        local inset = 0
        if el.filled and type(bb) == "table" and bb.__dp_alpha and bb.__dp_alpha < 255 and n >= 4 then
            inset = math.floor(el.width / 2 + 0.5)
        end
        if el.filled and n >= 3 then
            local poly = {}
            if inset > 0 then
                -- Inset each vertex by inset along both adjacent edge directions (per-vertex formula for offsetting a rectangle inward)
                for i, p in ipairs(pts) do
                    local prev, nxt = pts[i == 1 and n or i - 1], pts[i == n and 1 or i + 1]
                    local u1x, u1y = norm2(prev.x - p.x, prev.y - p.y)
                    local u2x, u2y = norm2(nxt.x - p.x, nxt.y - p.y)
                    poly[i] = { p.x + (u1x + u2x) * inset + (ox or 0), p.y + (u1y + u2y) * inset + (oy or 0) }
                end
            else
                for i, p in ipairs(pts) do
                    poly[i] = { p.x + (ox or 0), p.y + (oy or 0) }
                end
            end
            local bw, bh = bb:getWidth(), bb:getHeight()
            local rows = shapes.polyRowSpans(poly)
            for y, list in pairs(rows) do
                if y >= 0 and y < bh then
                    for _, iv in ipairs(list) do
                        local x0 = math.max(0, iv[1])
                        local x1 = math.min(bw - 1, iv[2])
                        if x1 >= x0 then
                            bb:paintRect(x0, y, x1 - x0 + 1, 1, color)
                        end
                    end
                end
            end
        end
        for i = 2, n do
            local a, b = pts[i - 1], pts[i]
            shapes.thickLine(bb, a.x + (ox or 0), a.y + (oy or 0),
                b.x + (ox or 0), b.y + (oy or 0), el.width, color, el.tip)
        end
        if n >= 3 then
            local a, b = pts[n], pts[1]
            shapes.thickLine(bb, a.x + (ox or 0), a.y + (oy or 0),
                b.x + (ox or 0), b.y + (oy or 0), el.width, color, el.tip)
        end
    elseif kind == "line" then
        shapes.thickLine(bb, el.x0 + (ox or 0), el.y0 + (oy or 0),
            el.x1 + (ox or 0), el.y1 + (oy or 0), el.width, color, el.tip)
    elseif kind == "rect" then
        if el.filled then
            -- v62i: semi-transparent fill inset by half the line width (see the poly branch comment), opaque still fills completely
            local x0 = el.x0 + (ox or 0)
            local y0 = el.y0 + (oy or 0)
            local x1 = el.x1 + (ox or 0)
            local y1 = el.y1 + (oy or 0)
            local inset = (type(bb) == "table" and bb.__dp_alpha and bb.__dp_alpha < 255) and math.floor(el.width / 2 + 0.5) or 0
            if inset > 0 and (x1 - x0 - 2 * inset) >= 1 and (y1 - y0 - 2 * inset) >= 1 then
                shapes.fillRect(bb, x0 + inset, y0 + inset, x1 - inset, y1 - inset, color)
            elseif inset == 0 then
                shapes.fillRect(bb, x0, y0, x1, y1, color)
            end
        end
        shapes.rect(bb, el.x0 + (ox or 0), el.y0 + (oy or 0),
            el.x1 + (ox or 0), el.y1 + (oy or 0), el.width, color, el.tip)
    elseif kind == "circle" then
        -- Circle/ellipse: rx/ry support non-uniform scaling into an ellipse, rot supports rotation (solid rotated ellipses are scanline-filled)
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local rot = el.rot or 0
        if el.filled then
            -- v62i: semi-transparent fill radius inset by half the line width, meeting the outline annulus without overlapping
            local inset = (type(bb) == "table" and bb.__dp_alpha and bb.__dp_alpha < 255) and math.floor(el.width / 2 + 0.5) or 0
            local irx, iry = rx - inset, ry - inset
            if irx > 0 and iry > 0 then
                if rot == 0 then
                    shapes.fillEllipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), irx, iry, color)
                else
                    shapes.fillRotatedEllipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), irx, iry, rot, color)
                end
            end
        end
        shapes.ellipse(bb, el.cx + (ox or 0), el.cy + (oy or 0), rx, ry, el.width, color, el.tip, rot)
    end
end

return shapes
