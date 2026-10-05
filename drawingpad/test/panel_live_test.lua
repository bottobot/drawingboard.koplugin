--[[--
Regression: panel background follows switches live + with selected text, grey/width use element-level adjustment
1. With the tool panel open, switching tools updates the active item's light-grey background live
2. With the layer panel open, switching layers updates the current layer's light-grey background live
3. With a text object selected, tapping "Gray" opens the element-level grey slider and applies live (old version: _setTool cleared the selection first -> global settings popped up)
4. With an object selected, tapping "Width" keeps the selection (text shows "no line width", no global popup)

Run (from the KOReader emulator root):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/panel_live_test.lua
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

local BLB = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
UIManager.show = function(self_w, w) end
UIManager.close = function(self_w, w, ...) end

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

-- ============ 1. Tool panel background refreshes live ============
do
    local c = newCanvas()
    c:_setTool("brush")
    c._panel_bt = c:_categoryBt("tool") -- simulate the panel being open
    local bt = c._panel_bt
    check(bt.button_by_id["brush_btn"][1].background == BLB.COLOR_LIGHT_GRAY
        and bt.button_by_id["rect_btn"][1].background == BLB.COLOR_WHITE,
        "tool panel: brush active gray at open")
    c:_setTool("rect")
    check(bt.button_by_id["brush_btn"][1].background == BLB.COLOR_WHITE
        and bt.button_by_id["rect_btn"][1].background == BLB.COLOR_LIGHT_GRAY,
        "tool panel: highlight follows tool switch live")
end

-- ============ 2. Layer panel background refreshes live ============
do
    local c = newCanvas()
    c._panel_bt = c:_categoryBt("layer")
    local bt = c._panel_bt
    check(bt.button_by_id["layer2_btn"][1].background == BLB.COLOR_LIGHT_GRAY
        and bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_WHITE,
        "layer panel: default middle layer active gray at open")
    c:_switchLayer(3)
    check(bt.button_by_id["layer1_btn"][1].background == BLB.COLOR_WHITE
        and bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_LIGHT_GRAY,
        "layer panel: highlight follows layer switch live")
    -- Text markers (●/○) are synced too
    check(bt.button_by_id["layer3_btn"].text == "●Top(☐hide)",
        "layer panel: text mark syncs too")
end

-- ============ 3. Selected text -> grey uses element level ============
do
    local c = newCanvas()
    local el = { kind = "text", text = "Test", font = "cfont", size = 30,
        x = 200, y = 200, gray = 1 }
    table.insert(c.elements, el)
    c:_cacheBBox(el)
    c:_setTool("select")
    c:_setSelected(el)
    local captured = {}
    local orig_picker = c._showValuePicker
    c._showValuePicker = function(s, opts) captured[#captured + 1] = opts end
    -- Use the real entry point: on_tap of the property panel's gray_btn
    local bt = c:_categoryBt("prop")
    -- After reconstruction self in the callback is bound to canvas; calling the defined on_tap directly is equivalent
    for _, t in ipairs(require("drawingpad.menus")._toggle_buttons) do
        if t.id == "gray_btn" then
            t.on_tap(c)
        end
    end
    check(#captured == 1 and captured[1].title and captured[1].title:find("Selected") ~= nil,
        "with text selected, gray opens element picker (not global settings)")
    check(c._selected == el, "selection preserved")
    captured[1].onchange(30)
    check(math.abs(el.gray - 0.3) < 0.001, "element gray applied to text, got " .. tostring(el.gray))
    -- Render check: mid-grey ink appears in the text area
    c.canvas_bb:fill(BLB.COLOR_WHITE)
    c:_redrawRegion({ x = 0, y = 0, w = c.canvas_w, h = c.canvas_h })
    local mid = 0
    for y = 150, 260 do
        for x = 150, 320 do
            local a = c.canvas_bb:getPixel(x, y).a
            if a >= 100 and a <= 180 then
                mid = mid + 1
            end
        end
    end
    check(mid > 50, "text renders in gray ink, mid pixels=" .. mid)
    c._showValuePicker = orig_picker

    -- 4. Tapping width with an object selected: keeps the selection (text gets the "no line width" notice, no global width popup)
    local captured_w = {}
    c._showValuePicker = function(s, opts) captured_w[#captured_w + 1] = opts end
    for _, t in ipairs(require("drawingpad.menus")._toggle_buttons) do
        if t.id == "width_btn" then
            t.on_tap(c)
        end
    end
    check(#captured_w == 0 and c._selected == el,
        "width with text selected: no global picker, selection preserved")
    c._showValuePicker = orig_picker
end

-- ============ 5. Top-level bottom bar: no icon background feedback (v61k removed grey background/flash, active indicator = gap in the top rule) ============
do
    local c = newCanvas()
    c:_showCategoryMenu("func")
    local cell = c.toolbar[2][6] -- cat_func is the 6th cell
    check(cell.background == nil and tostring(cell[1][1].background or "") ~= "Color8(128)",
        "open category cell has no gray background feedback")
    -- The toolbar stays clean after the panel closes
    c._open_cat = nil
    c:_refreshToolbar()
    check(c.toolbar[2][6].background == nil, "closing panel keeps toolbar clean")
end

-- ============ 7. Property settings don't switch the current tool (v61o: gray/width under fill keep fill) ============
do
    local c = newCanvas()
    c:_setTool("fill")
    local bt = c:_categoryBt("prop")
    local gray_tap = bt.button_by_id["gray_btn"].callback
    local width_tap = bt.button_by_id["width_btn"].callback
    gray_tap() -- global grey settings popup (UIManager.show is stubbed)
    check(c.tool == "fill", "gray tap keeps fill tool")
    width_tap()
    check(c.tool == "fill", "width tap keeps fill tool")
    local gray_hold = bt.button_by_id["gray_btn"].hold_callback
    gray_hold()
    check(c.tool == "fill" and c.gray_random == true, "gray hold toggles random, keeps fill tool")
    -- A selected fill object has no element-level branch, but a selected text object still goes element-level (covered in section 4)
    local width_hold = bt.button_by_id["width_btn"].hold_callback
    width_hold()
    check(c.tool == "fill" and c.width_random == true, "width hold toggles random, keeps fill tool")
end

print(string.format("=== panel_live_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
