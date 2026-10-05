-- Opacity feature real-paint smoke test (pitfall 14c): new popups really paintTo without crashing + PNGs written to disk for visual inspection.
-- Run: cd to the emulator directory && ./luajit .../test/../dp_alpha_paint.lua (temporary script, not committed)
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
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

local DrawingCanvas = require("drawingpad.drawing_canvas")
local canvas = DrawingCanvas:new{ on_close = function() end }

local outdir = "/home/m/dp_alpha_paint"
pcall(lfs.mkdir, outdir)

-- stub UIManager.show to capture popups (no event loop), then really paintTo (screen BB).
-- Note show is a colon call (UIManager:show(w)), so the first argument is UIManager itself
local captured = {}
UIManager.show = function(ui, w)
    captured[#captured + 1] = w
    return w
end

local function paintTop(name)
    local w = captured[#captured]
    if not w then
        print(name, "NO POPUP CAPTURED")
        return
    end
    local ok, err = pcall(function() w:paintTo(Screen.bb, 0, 0) end)
    print(name, ok and "paint OK" or ("PAINT CRASH: " .. tostring(err)))
    captured = {}
end

-- Draw something on the canvas first: a black ink line + a 50% transparent filled rectangle on top (visual check of blending)
canvas:_setTool("brush")
canvas.alpha = 1.0
canvas:onPan(nil, { pos = { x = 60, y = 200 }, start_pos = { x = 60, y = 200 } })
canvas:onPan(nil, { pos = { x = 460, y = 210 }, start_pos = { x = 60, y = 200 } })
canvas:onPanRelease(nil, { pos = { x = 470, y = 212 } })
canvas:_setTool("rect")
canvas.alpha = 0.5
canvas.rect_filled = true
canvas:onPan(nil, { pos = { x = 40, y = 160 }, start_pos = { x = 40, y = 160 } })
canvas:onPanRelease(nil, { pos = { x = 500, y = 420 } })
canvas:_updateStatus()
local ok, err = pcall(function() canvas:paintTo(Screen.bb, 0, 0) end)
print("canvas paintTo", ok and "OK" or ("CRASH: " .. tostring(err)))
canvas.canvas_bb:writePNG(outdir .. "/canvas_alpha.png")
print("canvas_alpha.png", (lfs.attributes(outdir .. "/canvas_alpha.png", "size") or 0) .. " bytes")

-- 1. Property panel (opacity next to tip)
canvas:_showCategoryMenu("prop")
paintTop("prop_panel")

-- 2. Opacity settings popup (max/min/levels/fixed)
canvas:_pickAlpha()
paintTop("alpha_setting_dialog")

-- 3. Layer panel (including the current layer opacity item)
canvas:_showCategoryMenu("layer")
paintTop("layer_panel")

-- 4. Current layer opacity slider popup
canvas:_pickLayerAlpha()
paintTop("layer_alpha_picker")

-- 5. Selected object opacity slider
canvas:_setTool("select")
canvas:onTap(nil, { pos = { x = 270, y = 290 } }) -- select the transparent rectangle
print("selected", canvas._selected and canvas._selected.kind or "NONE")
canvas:_pickAlpha()
paintTop("element_alpha_picker")

print("DONE")
