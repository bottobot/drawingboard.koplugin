--[[--
Layer occlusion regression test: after a lower layer (1) commits new ink (stroke/ink dot/shape/text),
existing ink on a higher layer (3) must still cover it (pixel = higher-layer grey); before the fix the lower layer's new ink
was drawn straight into canvas_bb, always on top, wrongly covering the higher layer.

Run:
    cd koreader-emulator-x86_64-linux-gnu-debug/koreader && ./luajit \
      /home/m/koreader/plugins/drawingboard.koplugin/drawingpad/test/layer_zorder_test.lua
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

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function px(canvas, x, y)
    return canvas.canvas_bb:getPixel(x, y).a
end

-- Assert that every pixel in the rectangle is close to the expected grey (with tolerance)
local function bandIs(canvas, x0, y0, x1, y1, want, tol, msg)
    for y = y0, y1 do
        for x = x0, x1 do
            local a = px(canvas, x, y)
            if math.abs(a - want) > tol then
                error(string.format("FAIL: %s at (%d,%d) a=%d want~%d", msg, x, y, a, want))
            end
        end
    end
end

-- ============ 1. Stroke: black horizontal line on the high layer (3), grey vertical line on the low layer (1) crossing it -> the crossing stays black ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10

    -- Black horizontal line on the high layer: x 100..200 @ y=200, width 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })
    check(#canvas.layers[3] == 1, "layer3 has 1 stroke")
    check(px(canvas, 150, 200) < 20, "top stroke ink black before conflict")

    -- Switch to the low layer and draw a grey vertical line: x=150, y 150..250, width 10, grey 0.5
    canvas:_switchLayer(1)
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })
    check(#canvas.layers[1] == 1, "layer1 has 1 stroke")

    -- The crossing must still be the high layer's black (before the fix the low-layer grey line was drawn on top -> a≈128)
    bandIs(canvas, 145, 197, 155, 203, 0, 40, "stroke crossing occluded by top layer")
    -- The parts of the low-layer vertical line outside the conflict area show normally (grey ≈128)
    check(math.abs(px(canvas, 150, 160) - 128) < 60, "lower stroke visible outside overlap")
    canvas:onCloseWidget()
    print("PASS: stroke commit respects layer order")
end

-- ============ 2. Ink dot: a low-layer dot on a high-layer black line -> stays black ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(1)
    canvas.gray = 0.5
    canvas:_commitDot(150, 200)
    check(#canvas.layers[1] == 1, "dot committed on layer1")
    bandIs(canvas, 147, 198, 153, 202, 0, 40, "dot under top stroke")
    canvas:onCloseWidget()
    print("PASS: dot commit respects layer order")
end

-- ============ 3. Shape: a low-layer grey rectangle edge crossing a high-layer black vertical line -> the crossing stays black ============
do
    local canvas = newCanvas()
    -- High-layer black vertical line x=150, y 150..250
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })

    -- Low-layer grey outline rectangle (120,180)-(180,220), width 6: top edge y=180 crosses the vertical line
    canvas:_switchLayer(1)
    canvas:_setTool("rect")
    canvas.width = 10
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 120, y = 180 }, start_pos = { x = 120, y = 180 } })
    canvas:onPanRelease(nil, { pos = { x = 180, y = 220 } })
    check(#canvas.layers[1] == 1, "rect committed on layer1")
    check(px(canvas, 150, 180) < 20, "rect edge crossing stays occluded by top stroke")
    -- Rectangle edges show normally where there is no conflict
    check(math.abs(px(canvas, 120, 200) - 128) < 70, "rect edge visible outside overlap")
    canvas:onCloseWidget()
    print("PASS: shape commit respects layer order")
end

-- ============ 4. Text: low-layer text overlapping a high-layer black band -> no text grey inside the overlapping band ============
do
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.width = 10
    canvas:_switchLayer(3)
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(1)
    canvas:_setTool("text")
    canvas.gray = 0.5
    canvas:_commitText(110, 185, "WWWW")
    check(#canvas.layers[1] == 1, "text committed on layer1")
    -- Inside the high-layer black band (x105..195, y197..203) there must be no grey text ink
    bandIs(canvas, 105, 197, 195, 203, 0, 40, "text under top stroke band")
    canvas:onCloseWidget()
    print("PASS: text commit respects layer order")
end

-- ============ 5. Drawing on the top layer is unaffected: a new layer-3 stroke covers layer 1 normally ============
do
    local canvas = newCanvas()
    canvas:_switchLayer(1)
    canvas:_setTool("brush")
    canvas.width = 10
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 200 } })

    canvas:_switchLayer(3)
    canvas.gray = 1.0
    canvas:onPan(nil, { pos = { x = 150, y = 150 }, start_pos = { x = 150, y = 150 } })
    canvas:onPan(nil, { pos = { x = 150, y = 200 }, start_pos = { x = 150, y = 150 } })
    canvas:onPanRelease(nil, { pos = { x = 150, y = 250 } })
    check(px(canvas, 150, 200) < 20, "top-layer stroke paints over lower ink")
    canvas:onCloseWidget()
    print("PASS: top-layer painting unaffected")
end

print("ALL LAYER Z-ORDER TESTS PASSED")
