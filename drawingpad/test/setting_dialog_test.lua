--[[--
Regression: the grey/width three-level settings popups have no "Random" button and no bottom hint; random is still toggled by long-pressing the property panel item
Run (from the KOReader emulator root):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/setting_dialog_test.lua
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

local Screen = require("device").screen

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

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

-- stub UIManager.show/close (capture popups, don't enter the event loop)
local UIManager = require("ui/uimanager")
local orig_show, orig_close = UIManager.show, UIManager.close
UIManager.show = function(self_w, w) end
UIManager.close = function(self_w, w, ...) end

-- Capture the ButtonTable produced by _showCenteredButtons
local function captureBt(c)
    local captured
    local orig = c._showCenteredButtons
    c._showCenteredButtons = function(s, title, btns, wf)
        local bt, popup = orig(s, title, btns, wf)
        captured = bt
        return bt, popup
    end
    return function() return captured end
end

local function dialogHasNoRandom(bt, label)
    local random_btn = false
    local n = 0
    for id, b in pairs(bt.button_by_id or {}) do
        n = n + 1
        if id:find("random") then
            random_btn = true
        end
    end
    check(not random_btn, label .. ": no random button in dialog")
    -- button_by_id only contains buttons with an id: max/min/levels/fixed (the close button has no id and isn't in the table)
    check(n == 4, label .. ": exactly 4 id'd buttons (max/min/levels/fixed), got " .. n)
end

do
    local c = newCanvas()
    local getBt = captureBt(c)
    c:_pickGray()
    local bt = getBt()
    check(bt ~= nil, "gray dialog opens")
    dialogHasNoRandom(bt, "gray")
    local pok = pcall(function() bt:paintTo(Screen.bb, 0, 0) end)
    check(pok, "gray dialog paints without crash")

    getBt = captureBt(c)
    c:_pickWidth()
    bt = getBt()
    check(bt ~= nil, "width dialog opens")
    dialogHasNoRandom(bt, "width")
    pok = pcall(function() bt:paintTo(Screen.bb, 0, 0) end)
    check(pok, "width dialog paints without crash")

    -- Random mode is still toggled by long-pressing the property panel item (state machine not removed)
    c:_toggleGrayRandom()
    check(c.gray_random == true, "gray random still toggleable via panel long-press")
    c:_toggleWidthRandom()
    check(c.width_random == true, "width random still toggleable via panel long-press")
end

UIManager.show, UIManager.close = orig_show, orig_close
print(string.format("=== setting_dialog_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
