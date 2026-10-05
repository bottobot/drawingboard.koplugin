--[[--
Reproduces the live flow of a semi-transparent stroke crossing an existing opaque object, checking whether the canvas pixels after live compositing/pen-up
show a "rectangular mosaic" (pixels outside the stroke mask changed, or values inside the mask garbled).
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

local Blitbuffer = require("ffi/blitbuffer")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local function px(bb, x, y)
    local p = bb:getPixel(x, y)
    local ok, v = pcall(function() return p.a end)
    if ok and v then return v end
    local ok2, r = pcall(function() return p.r end)
    if ok2 and r then return r end
    return -1
end

local PASS, FAIL = 0, 0
local function assert_eq(name, a, b)
    if a == b then
        PASS = PASS + 1
        print('PASS ' .. name .. ' (' .. tostring(a) .. ')')
    else
        FAIL = FAIL + 1
        print('FAIL ' .. name .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b))
    end
end

local canvas = DrawingCanvas:new{ on_close = function() end }
canvas.canvas_w, canvas.canvas_h = 600, 400
canvas.canvas_bb = Blitbuffer.new(600, 400, Blitbuffer.TYPE_BB8)
canvas.canvas_bb:fill(Blitbuffer.COLOR_WHITE)
canvas.layers = { {}, {}, {} }
canvas.elements = canvas.layers[2]
canvas.active_layer = 2
canvas.layer_visible = { true, true, true }
canvas.layer_alpha = { 1, 1, 1 }
canvas:_renderAll()

-- Background object: opaque black rectangle (the stroke crosses it)
local rect_el = { kind = "rect", x0 = 150, y0 = 150, x1 = 450, y1 = 250, width = 2, gray = 1, filled = true, alpha = 1 }
table.insert(canvas.elements, rect_el)
canvas:_cacheBBox(rect_el)
canvas:_redrawRegion({ x = 0, y = 0, w = 600, h = 400 })

-- Stroke data (horizontally across the rectangle, spanning white background and black rectangle)
local pts = {}
for i = 0, 30 do pts[i + 1] = { x = 100 + i * 15, y = 200 } end

-- Live: append in three chunks + throttled replay (simulates _extendStroke -> _flushStrokeRepaint)
canvas.tool = "brush"
local stroke = { kind = "freehand", points = {}, width = 16, gray = 1, alpha = 0.5, tip = "circle" }
canvas._stroke = stroke
for _, p in ipairs(pts) do
    table.insert(stroke.points, p)
    canvas:_renderStrokeTail()
    canvas._stroke_region = canvas:_mergeRegions(canvas._stroke_region,
        canvas:_dirtyRegion(p.x, p.y, p.x, p.y, stroke.width + 2))
end
canvas:_flushStrokeRepaint()

-- Check the live picture: outside the mask (far white background/non-stroke parts inside the rectangle) must be unchanged
assert_eq('live: white far above stroke', px(canvas.canvas_bb, 200, 100), 255)
assert_eq('live: rect interior below stroke', px(canvas.canvas_bb, 400, 240), 0)
-- Stroke centre line: v62s live = opaque grey preview (black); the rectangle segment is opaque too
assert_eq('live: stroke over white (opaque preview)', px(canvas.canvas_bb, 120, 200), 0)
assert_eq('live: stroke over rect (opaque preview)', px(canvas.canvas_bb, 300, 200), 0)
-- Outside the mask edge, inside the bbox: beyond the stroke's vertical width (±>8px) the background must remain
assert_eq('live: white inside bbox above stroke', px(canvas.canvas_bb, 120, 200 + 12), 255)
assert_eq('live: rect inside bbox below stroke', px(canvas.canvas_bb, 300, 200 + 12), 0)

-- Pen-up
canvas:_finishStroke(pts[#pts].x, pts[#pts].y)
assert_eq('commit: stroke over white', px(canvas.canvas_bb, 120, 200), 127)
assert_eq('commit: stroke over rect', px(canvas.canvas_bb, 300, 200), 0)
assert_eq('commit: white outside stroke', px(canvas.canvas_bb, 120, 200 + 12), 255)
assert_eq('commit: rect outside stroke', px(canvas.canvas_bb, 300, 200 + 12), 0)

-- Full replay (reproduced after save/layer switch)
canvas:_renderAll()
assert_eq('replay: stroke over white', px(canvas.canvas_bb, 120, 200), 127)
assert_eq('replay: stroke over rect', px(canvas.canvas_bb, 300, 200), 0)
assert_eq('replay: white outside stroke', px(canvas.canvas_bb, 120, 200 + 12), 255)

print(string.format('RESULT: %d PASS, %d FAIL', PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
