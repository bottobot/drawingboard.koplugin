--[[--
Path fill rotate/scale no-poke-through regression test (recompute from src_points source vertices):
1. A path fill pen-up stores el.src_points
2. 8 consecutive 30° rotations: fill pixels always hug the transformed source-vertex polygon (pixels >1.5px outside must be 0)
3. Scaling (up/down): spans are dense and still fit the transformed polygon
4. Rotate after move: the fill follows the source vertices (doesn't jump back to the old position)
5. _cloneElement/_restoreGeom deep-copy src_points (undo snapshots don't alias)
6. Old data/tap flood fills (no src_points) still take the original span-rebuild path when rotated

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/fill_transform_test.lua
--]]
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local PASS, FAIL = 0, 0
local function check(cond, msg)
    if cond then
        PASS = PASS + 1
        print("PASS " .. msg)
    else
        FAIL = FAIL + 1
        print("FAIL " .. msg)
    end
end

-- ---- Geometry helpers ----
local function polyBBox(pts)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.x < x0 then x0 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.x > x1 then x1 = p.x end
        if p.y > y1 then y1 = p.y end
    end
    return x0, y0, x1, y1
end

-- Even-odd rule point in polygon
local function pointInPoly(x, y, pts)
    local inside = false
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[(i % n) + 1]
        if (a.y <= y and b.y > y) or (b.y <= y and a.y > y) then
            local xin = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
            if x < xin then inside = not inside end
        end
    end
    return inside
end

local function segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0
    if l2 > 0 then
        t = ((px - ax) * dx + (py - ay) * dy) / l2
        t = math.max(0, math.min(1, t))
    end
    local qx, qy = ax + t * dx, ay + t * dy
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

local function polyDist(x, y, pts)
    local d = math.huge
    local n = #pts
    for i = 1, n do
        local a, b = pts[i], pts[(i % n) + 1]
        d = math.min(d, segDist(x, y, a.x, a.y, b.x, b.y))
    end
    return d
end

-- Number of fill pixels farther than tol outside the polygon boundary (poke-through amount)
local function countOutside(el, pts, tol)
    local n = 0
    for _, sp in ipairs(el.spans) do
        for x = sp[2], sp[3] do
            if not pointInPoly(x, sp[1], pts) and polyDist(x, sp[1], pts) > tol then
                n = n + 1
            end
        end
    end
    return n
end

-- Row set is dense (no empty rows)
local function spansDense(el)
    local ys = {}
    local ymin, ymax = math.huge, -math.huge
    for _, sp in ipairs(el.spans) do
        ys[sp[1]] = true
        if sp[1] < ymin then ymin = sp[1] end
        if sp[1] > ymax then ymax = sp[1] end
    end
    local n = 0
    for _ in pairs(ys) do n = n + 1 end
    return n > 0 and n == ymax - ymin + 1
end

-- ============ 1. Path fill stores source vertices ============
do
    local c = newCanvas()
    c:_setTool("fill")
    c:_toggleFillMode() -- path mode
    c:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
    c:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    c:onPanRelease(nil, { pos = { x = 100, y = 300 } })
    local el = c.elements[1]
    check(el and el.kind == "fill", "path fill commits fill element")
    check(el.src_points and #el.src_points >= 3, "fill stores src_points, got "
        .. tostring(el.src_points and #el.src_points))
    check(#el.spans > 0, "fill has spans")
    check(countOutside(el, el.src_points, 1.5) == 0,
        "initial spans inside src polygon (outside>1.5px: "
        .. countOutside(el, el.src_points, 1.5) .. ")")

    -- ============ 2. 8 consecutive 30° rotations without poke-through ============
    local x0, y0, x1, y1 = polyBBox(el.src_points)
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    local r0max = 0
    for _, p in ipairs(el.src_points) do
        r0max = math.max(r0max, math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2))
    end
    for i = 1, 8 do
        c:_rotateElement(el, math.pi / 6, cx, cy)
        c:_cacheBBox(el)
    end
    check(#el.spans > 0, "after 8 rotations spans non-empty")
    check(spansDense(el), "after 8 rotations rows dense")
    local outside = countOutside(el, el.src_points, 1.5)
    check(outside == 0, "after 8x30deg rotations fill hugs polygon (outside>1.5px: "
        .. outside .. ")")
    local rr = 0
    for _, sp in ipairs(el.spans) do
        for _, xx in ipairs({ sp[2], sp[3] }) do
            rr = math.max(rr, math.sqrt((xx - cx) ^ 2 + (sp[1] - cy) ^ 2))
        end
    end
    check(rr <= r0max + 1.5, "fill radius stable (" ..
        string.format("%.1f", rr) .. " <= " .. string.format("%.1f", r0max) .. "+1.5)")

    -- ============ 3. Still fits after scaling ============
    local bx0, by0, bx1, by1 = polyBBox(el.src_points)
    local sb = { x0 = math.floor(bx0), y0 = math.floor(by0), x1 = math.ceil(bx1), y1 = math.ceil(by1) }
    local nb = { x0 = sb.x0, y0 = sb.y0, x1 = sb.x0 + (sb.x1 - sb.x0) * 1.5, y1 = sb.y0 + (sb.y1 - sb.y0) * 1.5 }
    c:_scaleElement(el, sb, nb)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "scale up 1.5x spans dense")
    check(countOutside(el, el.src_points, 1.5) == 0, "scale up 1.5x fill hugs polygon (outside: "
        .. countOutside(el, el.src_points, 1.5) .. ")")
    local nb2 = { x0 = nb.x0, y0 = nb.y0, x1 = nb.x0 + (nb.x1 - nb.x0) / 1.5, y1 = nb.y0 + (nb.y1 - nb.y0) / 1.5 }
    c:_scaleElement(el, nb, nb2)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "scale back down spans dense")
    check(countOutside(el, el.src_points, 1.5) == 0, "scale down fill hugs polygon (outside: "
        .. countOutside(el, el.src_points, 1.5) .. ")")

    -- ============ 4. Rotation after move follows ============
    c:_moveElement(el, 50, 25)
    c:_cacheBBox(el)
    c:_rotateElement(el, math.pi / 4, (el._bbox.x0 + el._bbox.x1) / 2, (el._bbox.y0 + el._bbox.y1) / 2)
    c:_cacheBBox(el)
    local mx0, my0, mx1, my1 = polyBBox(el.src_points)
    check(math.abs(el._bbox.x0 - math.floor(mx0)) <= 2 and math.abs(el._bbox.y1 - math.ceil(my1)) <= 2,
        "rotate after move follows src_points")

    -- ============ 5. Snapshot/clone deep copy ============
    local clone = c:_cloneElement(el)
    check(clone.src_points[1] ~= el.src_points[1], "clone deep-copies src_points")
    local snap = c:_cloneElement(el)
    c:_restoreGeom(el, snap)
    check(el.src_points[1] ~= snap.src_points[1]
        and el.src_points[1].x == snap.src_points[1].x
        and el.src_points[1].y == snap.src_points[1].y,
        "restore deep-copies src_points from snapshot (no aliasing)")
    local px, py = el.src_points[1].x, el.src_points[1].y
    c:_rotateElement(el, 0.3, 0, 0)
    check(snap.src_points[1].x == px and snap.src_points[1].y == py,
        "mutating el.src_points does not pollute snapshot")
end

-- ============ 6. tap flood fill (no src_points) old path still works ============
do
    local c = newCanvas()
    c:_setTool("fill") -- default tap mode
    c:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 200 } })
    c:onPanRelease(nil, { pos = { x = 150, y = 200 } })
    local el = c.elements[1]
    check(el and el.kind == "fill" and el.src_points == nil, "tap flood fill has no src_points")
    c:_rotateElement(el, math.pi / 6, 150, 200)
    c:_cacheBBox(el)
    check(#el.spans > 0 and spansDense(el), "legacy tap fill still rotates (spans dense)")
end

print(string.format("=== fill_transform_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
