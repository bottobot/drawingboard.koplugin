-- Pen-down refresh policy regression: every "canvas refresh" must carry a region
-- Background: the plugin's setDirty(partial, nil) in KOReader = a full-screen refresh (also upgraded by count to a
-- flashing full refresh), which is a flash on e-ink. Historical bug: on a fast pen-down (_renderStrokeTail had only drawn the
-- start dot and couldn't render a segment yet, returning nil) _stroke_region was still nil, so the "refresh immediately on pen-down"
-- became a full-screen refresh -> "a flash on fast pen-down" on the real device; slow pen-down goes through onHold (with an if rx0 guard) and doesn't flash.
-- This test: simulate fast/slow pen-downs and assert every canvas refresh has mode=partial and a non-nil region.
-- Self-locate the plugin root (runs on both the emulator /home/m/koreader and the device /mnt/us/koreader)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local UIManager = require("ui/uimanager")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local canvas = DrawingCanvas:new{ on_close = function() end }
if not canvas.canvas_bb then canvas:_recreateCanvas() end

local calls = {}
local real_setDirty = UIManager.setDirty
UIManager.setDirty = function(uim, w, mode, region, dither)
    if w == canvas then
        calls[#calls + 1] = { mode = mode, region = region }
    end
    return real_setDirty(uim, w, mode, region, dither)
end

local function drain(from)
    local n, nils, empty = 0, 0, 0
    for i = from, #calls do
        n = n + 1
        local r = calls[i].region
        if calls[i].mode == "partial" and not r then
            nils = nils + 1
        elseif r and (r.w <= 0 or r.h <= 0) then
            empty = empty + 1
        end
    end
    return n, nils, empty
end

local function reset()
    canvas._stroke = nil
    canvas._stroke_pending = nil
    canvas._stroke_region = nil
    canvas._stroke_repaint_pending = false
    canvas._stroke_repaint_fn = nil
end

local fails = {}
local function case(label, fn)
    reset()
    local m0 = #calls
    fn()
    local n, nils, empty = drain(m0 + 1)
    print(string.format("  %-22s %d refreshes, %d without region, %d with empty region", label, n, nils, empty))
    if nils > 0 then
        fails[#fails + 1] = label .. ": " .. nils .. " full-screen (region-less) refreshes"
    end
    if empty > 0 then
        fails[#fails + 1] = label .. ": " .. empty .. " empty-region refreshes"
    end
end

-- Fast pen-down = the 2nd pan already passes the threshold (very common on the device after lowering PAN_THRESHOLD in the gesture detector)
local function fast_start()
    canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
    canvas:onPan(nil, { pos = { x = 340, y = 300 }, start_pos = { x = 300, y = 300 } })
end

-- Slow pen-down = hold still first and get hold (0.5s), then drag
local function slow_start()
    canvas:onHold(nil, { pos = { x = 300, y = 500 } })
    canvas:onPan(nil, { pos = { x = 340, y = 500 }, start_pos = { x = 300, y = 500 } })
end

for _, t in ipairs({ { "fill", "path", 1 }, { "brush", nil, 4 } }) do
    local tool, mode, w = t[1], t[2], t[3]
    canvas:_setTool(tool)
    if mode then canvas.fill_mode = mode end
    canvas.width = w
    case(tool .. " fast pen-down", fast_start)
    case(tool .. " slow pen-down", slow_start)
end

-- Fast pen-down then continuous drawing + pen-up: on the whole chain only the pen-up "even out ghosting" full-screen refresh is allowed (_penUpRefresh,
-- once per pen lift by design); pen-down/mid-stroke refreshes must all carry a region
canvas:_setTool("brush")
canvas.width = 4
reset()
local m0 = #calls
fast_start()
for i = 1, 20 do
    canvas:onPan(nil, { pos = { x = 340 + i * 6, y = 300 }, start_pos = { x = 300, y = 300 } })
end
canvas:onPanRelease(nil, { pos = { x = 460, y = 300 } })
local n, nils, empty = drain(m0 + 1)
print(string.format("  %-22s %d refreshes, %d without region, %d with empty region", "whole stroke (fast pen-down+20 points+pen-up)", n, nils, empty))
if nils ~= 1 then
    fails[#fails + 1] = "whole stroke: " .. nils .. " region-less refreshes (only the single pen-up one is expected)"
elseif calls[#calls].region then
    fails[#fails + 1] = "whole stroke: the only region-less refresh is not the pen-up one (pen-down/mid-stroke is refreshing the full screen)"
end
if empty > 0 then fails[#fails + 1] = "whole stroke: " .. empty .. " empty-region refreshes" end
if #canvas.layers[2] ~= 1 then
    fails[#fails + 1] = "whole stroke not committed as 1 element (actual " .. #canvas.layers[2] .. ")"
end

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("START_FLASH_TEST_FAILED")
    os.exit(1)
end
print("PASS: stroke start refresh always regional")
