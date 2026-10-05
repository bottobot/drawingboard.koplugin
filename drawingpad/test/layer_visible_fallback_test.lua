-- Layer visibility "old core" compatibility + close-path fault tolerance
-- Background: on the device the core file with the ping-pong cache was rolled back to an old version (missing _applyVisibilityToggle /
-- _invalidateVisCache), while layers.lua / actions.lua still called them bare -> long-pressing a layer failed entirely
-- (swallowed by wrapHandler into a log line) and every close logged an error. Both call sites now use capability probes;
-- both cases are tested here: with cache (current core) and without cache (simulating the rolled-back core on the device).
-- Self-locate the plugin root (runs on both the emulator /home/m/koreader and the device /mnt/us/koreader)
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
local UIManager = require("ui/uimanager")
local DrawingCanvas = require("drawingpad.drawing_canvas")
local Blitbuffer = require("ffi/blitbuffer")

local canvas = DrawingCanvas:new{ on_close = function() end }
if not canvas.canvas_bb then canvas:_recreateCanvas() end

local fails = {}
local function ck(cond, msg) if not cond then fails[#fails + 1] = msg end end

local function ink_at(x, y)
    return canvas.canvas_bb:getPixel(x, y).a
end

-- Draw an ink dot (width 24, easy to sample)
canvas:_setTool("brush")
canvas.gray = 1.0
canvas.width = 24
pcall(function() canvas:_commitDot(200, 300) end)
ck(ink_at(200, 300) < 100, "precondition: ink dot not drawn (value " .. ink_at(200, 300) .. ")")

-- (1) Core with the ping-pong cache: two visibility toggles should round-trip
canvas.layer_visible[canvas.active_layer] = true
canvas:_toggleLayerVisible()
local hidden = ink_at(200, 300)
ck(canvas.layer_visible[canvas.active_layer] == false, "(1) flag not flipped")
ck(hidden > 200, "(1) canvas still has ink after hiding (value " .. hidden .. ")")
canvas:_toggleLayerVisible()
ck(canvas.layer_visible[canvas.active_layer] == true, "(1) restore flag not flipped")
ck(ink_at(200, 300) < 100, "(1) ink did not come back after restoring (value " .. ink_at(200, 300) .. ")")
print("  (1) core with cache: hidden " .. hidden .. " -> restored " .. ink_at(200, 300))

-- (2) Simulate the old rolled-back core on the device: both methods missing, visibility must still work without errors
canvas._applyVisibilityToggle = nil
canvas._invalidateVisCache = nil
local ok, err = pcall(function() canvas:_toggleLayerVisible() end)
ck(ok, "(2) _toggleLayerVisible errors on the old core: " .. tostring(err))
ck(canvas.layer_visible[canvas.active_layer] == false, "(2) flag not flipped")
ck(ink_at(200, 300) > 200, "(2) hiding had no effect on the old core (value " .. ink_at(200, 300) .. ")")
ok, err = pcall(function() canvas:_toggleLayerVisibleOf(1) end)
ck(ok, "(2) _toggleLayerVisibleOf errors on the old core: " .. tostring(err))
local w1 = canvas.layer_visible[1]
canvas:_toggleLayerVisibleOf(1)
ck(canvas.layer_visible[1] ~= w1, "(2) toggling another layer from the layer panel had no effect")
print("  (2) old core (no ping-pong cache): visibility still works")

-- (3) Close path: no error even without _invalidateVisCache
ok, err = pcall(canvas.onCloseWidget, canvas)
ck(ok, "(3) onCloseWidget errors on the old core: " .. tostring(err))
print("  (3) closing on the old core doesn't touch the missing method")

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("LAYER_VISIBLE_FALLBACK_FAILED")
    os.exit(1)
end
print("PASS: layer visibility works with and without ping-pong cache")
