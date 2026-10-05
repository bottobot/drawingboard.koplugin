-- Minimise/restore refresh policy regression: no full-screen refresh allowed ("full" on e-ink = a visible flash)
-- Background: the core _setMinimized ends with UIManager:setDirty(self, "full") - every tap of the hide/
-- restore key flashed the whole screen. The only pixels that actually change are a strip at the bottom (toolbar + status bar + floating "Menu" restore key);
-- _toggleMinimize in menus.lua absorbs the core's full-screen refresh and sends a "ui" refresh of the bottom region instead.
-- This test also covers "toggling minimise with a selected object" (the region refresh from deselecting must still pass through).
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
        if type(mode) == "function" then
            -- Deferred form (the plugin's usual style): evaluate the function now to see the real mode/region
            local m, r = mode()
            calls[#calls + 1] = { mode = m, region = r, deferred = true }
        else
            calls[#calls + 1] = { mode = mode, region = region }
        end
    end
    return real_setDirty(uim, w, mode, region, dither)
end

local fails = {}
local function check(label, from)
    local n, full, nils = 0, 0, 0
    for i = from, #calls do
        n = n + 1
        if calls[i].mode == "full" then
            full = full + 1
        elseif calls[i].mode == "partial" and not calls[i].region then
            nils = nils + 1
        end
    end
    print(string.format("  %-26s %d refreshes, %d full, %d region-less partial",
                        label, n, full, nils))
    if full > 0 then
        fails[#fails + 1] = label .. ": " .. full .. " full-screen full refreshes (would flash)"
    end
    if nils > 0 then
        fails[#fails + 1] = label .. ": " .. nils .. " region-less partial (full-screen) refreshes"
    end
    if n == 0 then
        fails[#fails + 1] = label .. ": no refresh at all (the bottom strip wasn't refreshed)"
    end
end

-- 1) No selection: minimise -> restore
canvas:_setMinimized(true)          -- enter minimised first (initial state)
local m0 = #calls
canvas:_toggleMinimize()            -- restore
check("no selection: restore", m0 + 1)
if canvas._minimized then
    fails[#fails + 1] = "_minimized still true after restore"
end
if canvas[1] ~= canvas.toolbar then
    fails[#fails + 1] = "self[1] is not the toolbar after restore"
end
m0 = #calls
canvas:_toggleMinimize()            -- minimise
check("no selection: minimise", m0 + 1)
if not canvas._minimized then
    fails[#fails + 1] = "_minimized not true after minimise"
end
if canvas[1] ~= canvas.restore_btn then
    fails[#fails + 1] = "self[1] is not the restore key after minimise"
end
if canvas.header_h ~= 0 then
    fails[#fails + 1] = "header_h should be 0 after minimise, actual " .. tostring(canvas.header_h)
end

-- 2) With a selected object: minimise (the region refresh from deselecting must still be sent)
canvas:_toggleMinimize()            -- restore first
canvas:_setTool("brush")
canvas.width = 6
canvas:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 200, y = 200 } })
for i = 1, 10 do
    canvas:onPan(nil, { pos = { x = 200 + i * 8, y = 200 }, start_pos = { x = 200, y = 200 } })
end
canvas:onPanRelease(nil, { pos = { x = 280, y = 200 } })
canvas:_setTool("select")
canvas:onTap(nil, { pos = { x = 240, y = 200 } })
if not canvas._selected then
    fails[#fails + 1] = "select tool didn't select the stroke (test precondition failed)"
end
m0 = #calls
canvas:_toggleMinimize()
check("with selection: minimise", m0 + 1)
if canvas._selected then
    fails[#fails + 1] = "selection not cleared after minimise (selection box would remain)"
end

-- 3) The bottom strip's refresh region must cover where the toolbar/status bar and the restore key are
local screen_h = Device.screen:getHeight()
local band = nil
for i = #calls, 1, -1 do
    local r = calls[i].region
    if r and r.y and r.y + r.h >= screen_h - 1 and r.h <= canvas.toolbar_h + canvas.status_h then
        band = r
        break
    end
end
if not band then
    fails[#fails + 1] = "no region refresh covering the bottom strip of the screen was seen"
elseif band.y > screen_h - canvas.toolbar_h - canvas.status_h then
    fails[#fails + 1] = "bottom region too small to cover toolbar + status bar: y=" .. band.y
end

if #fails > 0 then
    for _, f in ipairs(fails) do print("FAIL " .. f) end
    print("MINIMIZE_REFRESH_TEST_FAILED")
    os.exit(1)
end
print("PASS: minimize toggle refreshes only the bottom band")
