--[[--
Project file (.drawing) save/load regression test (v62d):
1. Save a project with 2 layers of content + visibility/opacity/current layer -> load into a new canvas -> elements/properties/pixels restored item by item
2. Undo stacks are cleared, private fields (_bbox) recomputed
3. Corrupt files are rejected without crashing

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/project_test.lua
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

local lfs = require("libs/libkoreader-lfs")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local PATH = "/tmp/dp_project_test.drawing"

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

local function px(bb, x, y)
    local p = bb:getPixel(x, y)
    return p and p.a or -1
end

-- Draw a stroke (with intermediate points so it doesn't degrade into an ink dot)
local function stroke(canvas, y)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 80, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPan(nil, { pos = { x = 200, y = y }, start_pos = { x = 80, y = y } })
    canvas:onPanRelease(nil, { pos = { x = 260, y = y } })
end

local passed = 0
local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print(err)
        print("RESULT: " .. passed .. " passed, FAILED at above")
        os.exit(1)
    end
end

section("save/load roundtrip restores layers, attrs, pixels", function()
    pcall(os.remove, PATH)
    local canvas = newCanvas()
    -- Middle layer: semi-transparent stroke
    canvas:_setTool("brush")
    canvas.alpha = 0.5
    stroke(canvas, 300)
    check(canvas.layers[2][1] ~= nil, "layer2 stroke committed")
    -- Bottom layer: black stroke; top layer left empty and hidden, layer opacity adjusted
    canvas:_switchLayer(1)
    canvas.alpha = 1.0
    stroke(canvas, 320)
    canvas.layer_alpha[1] = 0.5
    canvas.layer_visible[3] = false
    canvas:_switchLayer(1) -- save with current layer = bottom

    local before = px(canvas.canvas_bb, 150, 300)

    check(canvas:_doSaveProject(PATH), "save ok")
    check(lfs.attributes(PATH, "mode") == "file", "file written")

    -- Load into another canvas
    local c2 = newCanvas()
    stroke(c2, 500) -- interfering content, should be cleared
    c2:_loadProject(PATH)
    check(#c2.layers[2] == 1 and c2.layers[2][1].kind == "freehand", "layer2 restored")
    check(#c2.layers[1] == 1 and c2.layers[1][1].kind == "freehand", "layer1 restored")
    check(#c2.layers[3] == 0, "layer3 empty")
    check(math.abs((c2.layers[2][1].alpha or 1) - 0.5) < 0.001, "element alpha restored")
    check(c2.layer_visible[3] == false, "layer3 hidden restored")
    check(c2.layer_visible[2] == true, "layer2 visible restored")
    check(math.abs((c2.layer_alpha[1] or 1) - 0.5) < 0.001, "layer alpha restored")
    check(c2.active_layer == 1, "active layer restored")
    check(c2.elements == c2.layers[1], "elements rebound to active layer")
    check(#c2.undo == 0 and #c2.redo == 0, "undo/redo stacks reset")
    check(c2.layers[1][1]._bbox ~= nil, "bbox recomputed")
    -- Pixels: semi-transparent stroke on the middle layer, bottom layer at 50% layer opacity, same grey at the same coordinates before and after loading
    local after = px(c2.canvas_bb, 150, 300)
    check(math.abs(after - before) <= 1, "pixel roundtrip, before " .. before .. " after " .. after)
    -- Interfering content was cleared (no ink at y=500)
    check(px(c2.canvas_bb, 150, 500) >= 250, "stale content cleared")
    c2:onCloseWidget()
    canvas:onCloseWidget()
    os.remove(PATH)
end)

section("corrupt file rejected", function()
    local f = io.open(PATH, "w")
    f:write("this is not lua {{{")
    f:close()
    local canvas = newCanvas()
    local els_before = #canvas.elements
    local vis_before = { canvas.layer_visible[1], canvas.layer_visible[2], canvas.layer_visible[3] }
    canvas:_loadProject(PATH) -- must not crash or change state
    check(#canvas.elements == els_before, "elements untouched on corrupt file")
    check(canvas.layer_visible[2] == vis_before[2], "visibility untouched")
    canvas:onCloseWidget()
    os.remove(PATH)
end)

print("RESULT: all " .. passed .. " sections passed")
