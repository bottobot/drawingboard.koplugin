--[[--
Regression: a filled circle stays filled after stretching then rotating + no category menu left behind when the board closes
1. Filled circle -> non-uniform stretch into an ellipse -> rotate: the rendered centre and interior are still ink (filled lost = white centre)
2. onCloseWidget closes a category panel that is still open (shared by every close path: exit button/Back key etc.)

Run (from the KOReader emulator root):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/circle_fill_close_test.lua
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
local shapes = require("drawingpad.shapes")

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

-- ============ 1. Filled circle stretch -> rotate stays filled ============
do
    local function renderEl(el)
        local bb = Blitbuffer.new(400, 400, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        shapes.drawElement(bb, el, Blitbuffer.gray(1), 0, 0)
        return bb
    end

    local el = { kind = "circle", cx = 200, cy = 200, r = 80, rx = 80, ry = 80,
        width = 3, filled = true }

    -- Baseline: the filled circle has ink at its rendered centre
    local bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "solid circle renders ink at center")
    bb:free()

    -- Stretch (non-uniform 1.5x/1x -> ellipse)
    local c = newCanvas()
    local sb = { x0 = 120, y0 = 120, x1 = 280, y1 = 280 }
    local nb = { x0 = 120, y0 = 120, x1 = 360, y1 = 280 }
    c:_scaleElement(el, sb, nb)
    c:_cacheBBox(el)
    check(el.filled == true, "scale keeps filled")
    check(el.rx == 120 and el.ry == 80, "scale makes ellipse, got rx="
        .. tostring(el.rx) .. " ry=" .. tostring(el.ry))

    -- Rotate 30°: before the fix rendering degraded to an outline (white centre), after the fix the centre has ink
    c:_rotateElement(el, math.pi / 6, el.cx, el.cy)
    c:_cacheBBox(el)
    check(el.filled == true and (el.rot or 0) ~= 0, "rotate keeps filled and sets rot")
    bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "rotated solid ellipse has ink at center (was hollow)")
    -- A point inside the end of the ellipse's major axis (direction of the major-axis end (311,230) after a 30° rotation) must also have ink
    local lx = 200 + 110 * math.cos(math.pi / 6)
    local ly = 200 + 110 * math.sin(math.pi / 6)
    check(bb:getPixel(math.floor(lx), math.floor(ly)).a < 128,
        "rotated solid ellipse has ink near major axis tip")
    bb:free()

    -- Rotate another 90°, still filled
    c:_rotateElement(el, math.pi / 2, el.cx, el.cy)
    bb = renderEl(el)
    check(bb:getPixel(200, 200).a < 128, "rotated 90+30 deg still solid")
    bb:free()
end

-- ============ 2. No category menu left behind when the board closes ============
do
    local UIManager = require("ui/uimanager")
    local shown, closed = {}, {}
    local orig_show, orig_close = UIManager.show, UIManager.close
    UIManager.show = function(self_w, w) shown[#shown + 1] = w end
    UIManager.close = function(self_w, w, ...) closed[#closed + 1] = w end

    local c = newCanvas()
    c:_showCategoryMenu("func")
    local popup = c._category_popup
    check(popup ~= nil and c._open_cat == "func", "func panel opens")

    c:onCloseWidget() -- shared teardown path when the exit button/Back key closes the board
    check(closed[#closed] == popup and c._category_popup == nil and c._open_cat == nil,
        "onCloseWidget closes category popup (no residue)")

    UIManager.show, UIManager.close = orig_show, orig_close
end

-- ============ 7. A filled rectangle stays filled after rotation (v61k: poly rendering adds the fill) ============
do
    local el = { kind = "rect", x0 = 150, y0 = 250, x1 = 250, y1 = 350,
        width = 3, filled = true }
    local c = newCanvas()
    c:_rotateElement(el, math.pi / 4, 200, 300) -- after rotation rect -> poly
    c:_cacheBBox(el)
    check(el.kind == "poly" and el.filled == true, "rotated rect stays filled poly")
    local bb = Blitbuffer.new(400, 600, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    shapes.drawElement(bb, el, Blitbuffer.gray(1), 0, 0)
    check(bb:getPixel(200, 300).a < 128, "rotated solid rect has ink at center (was hollow)")
    -- The filled interior is selectable (_inkDistance hit)
    check(c:_inkDistance(el, 200, 300) == 0, "inkDistance 0 inside filled poly (selectable)")
    bb:free()
end

print(string.format("=== circle_fill_close_test: %d passed, %d failed ===", PASS, FAIL))
if FAIL > 0 then
    os.exit(1)
end
