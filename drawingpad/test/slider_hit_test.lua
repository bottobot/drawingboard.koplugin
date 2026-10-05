--[[--
Slider touch-area regression test: the slider hit area of showValuePicker must not cover any button.
Background: the old hit_rect expanded each side by scaleBySize(30), overflowing downwards into the touch area of the preset number buttons,
and gesture events reach the slider layer first in child order (slider_wrap before preset_bt) -> the slider steals button touches
(the user found the number buttons of every property settings popup hard to tap). After the fix it only expands downwards to the gap boundary with the buttons.

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/slider_hit_test.lua
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

local UIManager = require("ui/uimanager")
local Screen = Device.screen
local components = require("drawingpad.components")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

-- Collect the key widgets in the widget tree (child paths only, skipping back-references such as show_parent to avoid cycles)
local function collect(root)
    local slider_wrap, buttons = nil, {}
    local function visit(w, depth)
        if not w or depth > 12 or type(w) ~= "table" then
            return
        end
        if w.hitRect and w.onTapProgress then
            slider_wrap = w
        end
        if w.buttons_layout then -- ButtonTable: the row arrays hold Button instances
            for _, row in ipairs(w.buttons_layout) do
                for _, b in ipairs(row) do
                    buttons[#buttons + 1] = b
                end
            end
        end
        local kids = {}
        if w[1] then
            kids[#kids + 1] = w[1]
        end
        for i = 2, (w.length or #w) do
            kids[#kids + 1] = w[i]
        end
        if w.movable then
            kids[#kids + 1] = w.movable
        end
        for _, k in ipairs(kids) do
            visit(k, depth + 1)
        end
    end
    visit(root, 0)
    return slider_wrap, buttons
end

local function intersect(a, b)
    return a and b and a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + b.h
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

-- Pop up the value picker (captured by the stubbed show) and really paint it (dimen is only updated at paint time)
local function buildPicker()
    local captured = {}
    local real_show = UIManager.show
    UIManager.show = function(ui, w)
        captured[#captured + 1] = w
        return w
    end
    components.showValuePicker{
        title = "T",
        value = 50,
        min = 0,
        max = 100,
        unit = "%",
    }
    UIManager.show = real_show
    local popup = captured[#captured]
    check(popup ~= nil, "popup captured")
    local ok, err = pcall(function() popup:paintTo(Screen.bb, 0, 0) end)
    check(ok, "popup paint: " .. tostring(err))
    return popup
end

section("picker 0-100: hit rect covers no button", function()
    local popup = buildPicker()
    local slider_wrap, buttons = collect(popup)
    check(slider_wrap ~= nil, "slider_wrap found")
    check(#buttons >= 10, "buttons found (step+preset+close), got " .. #buttons)
    local hit = slider_wrap.hitRect()
    check(hit ~= nil, "hit rect computed")
    for i, b in ipairs(buttons) do
        if b.dimen then
            check(not intersect(hit, b.dimen),
                "hit rect overlaps button #" .. i .. " (" .. tostring(b.text) .. ")")
        end
    end
    -- Fixed semantics: the downward expansion uses exactly the gap (same amount as 3*vertical_large), no longer covering buttons
    popup:onCloseWidget()
end)

section("picker 1-800 (width range): hit rect covers no button", function()
    local captured = {}
    local real_show = UIManager.show
    UIManager.show = function(ui, w)
        captured[#captured + 1] = w
        return w
    end
    components.showValuePicker{ title = "T2", value = 400, min = 1, max = 800 }
    UIManager.show = real_show
    local popup = captured[#captured]
    local slider_wrap, buttons = collect(popup)
    local hit = slider_wrap.hitRect()
    for i, b in ipairs(buttons) do
        if b.dimen then
            check(not intersect(hit, b.dimen),
                "hit rect overlaps button #" .. i)
        end
    end
    popup:onCloseWidget()
end)

print("RESULT: all " .. passed .. " sections passed")
