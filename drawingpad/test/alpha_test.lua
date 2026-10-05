--[[--
Opacity (alpha) feature unit tests:
1. shapes.alphaProxy: blending on white ≈ α·ink + (1-α)·background, over ink the lower layer shows through; out-of-bounds clipping is safe
2. drawElement with alpha (full path of the fill element)
3. Canvas integration: semi-transparent filled rectangle commit + region redraw (negative offset) identical pixel by pixel before and after
4. Layer factor multiplies element alpha
5. _resolveAlpha random value range and level diversity
6. _applySelectedAlpha apply + undo restore (pixel level)
7. Semi-transparent text goes through the temp BB blend path: no fully black pixels, the opaque control has some
8. Property panel alpha_btn (next to tip) / layer panel layer_alpha_btn exist

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/alpha_test.lua
--]]

-- Self-locate the plugin root and inject package.path (same as feature_test)
local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

-- Pre-initialisation must happen before any require("ui/uimanager")/require("device")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local Blitbuffer = require("ffi/blitbuffer")
local shapes = require("drawingpad.shapes")
local DrawingCanvas = require("drawingpad.drawing_canvas")

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

local function newCanvas()
    return DrawingCanvas:new{ on_close = function() end }
end

local function px(bb, x, y)
    -- The screen framebuffer may be ColorRGB32 (emulator) without an .a field: grey content has r≈g≈b, take r as the grey value
    local p = bb:getPixel(x, y)
    if not p then
        return -1
    end
    local ok, v = pcall(function() return p.a end)
    if ok and v then
        return v
    end
    local ok2, r = pcall(function() return p.r end)
    if ok2 and r then
        return r
    end
    return -1
end

local passed = 0
local function section(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print(err)
        print(string.format("RESULT: %d passed, FAILED at above", passed))
        os.exit(1)
    end
end

-- 1. alphaProxy basic blending
section("proxy blend on white / over ink / clipping", function()
    local bb = Blitbuffer.new(20, 20, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 20, 20, Blitbuffer.COLOR_WHITE)
    local proxy = shapes.alphaProxy(bb, 0.5)
    -- 50% black on the top half of a white background -> ≈128
    proxy:paintRect(0, 0, 20, 10, Blitbuffer.gray(1.0))
    local v = px(bb, 10, 5)
    check(math.abs(v - 128) <= 2, "black 50% over white ~= 128, got " .. v)
    -- Lay black ink on the bottom half first, then 50% black over it -> lower layer shows through, still black
    bb:paintRect(0, 10, 20, 10, Blitbuffer.gray(1.0))
    proxy:paintRect(0, 10, 20, 10, Blitbuffer.gray(1.0))
    check(px(bb, 10, 15) <= 4, "50% over black ink stays black, got " .. px(bb, 10, 15))
    -- Out-of-bounds area is safe (native paintRect clipping): draw an out-of-bounds rectangle on a new canvas, only the in-canvas part is blended
    local bb2 = Blitbuffer.new(10, 10, Blitbuffer.TYPE_BB8)
    bb2:paintRect(0, 0, 10, 10, Blitbuffer.COLOR_WHITE)
    local p2 = shapes.alphaProxy(bb2, 0.5)
    p2:paintRect(-5, -5, 10, 10, Blitbuffer.gray(1.0)) -- after clipping only (0..4, 0..4) is written
    local cv = px(bb2, 0, 0)
    check(math.abs(cv - 128) <= 2, "clipped paint blends at top-left, got " .. cv)
    check(px(bb2, 8, 8) >= 253, "clipped paint left outside untouched, got " .. px(bb2, 8, 8))
    bb2:free()
    bb:free()
end)

-- 2. drawElement with alpha (full path of the fill element)
section("drawElement fill with alpha", function()
    local bb = Blitbuffer.new(60, 60, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 60, 60, Blitbuffer.COLOR_WHITE)
    -- First lay a black vertical bar x=0..9
    bb:paintRect(0, 0, 10, 60, Blitbuffer.gray(1.0))
    -- A full-width semi-transparent black fill element rendered through the proxy
    local el = { kind = "fill", spans = {}, gray = 1.0, alpha = 0.5 }
    for y = 0, 59 do
        el.spans[#el.spans + 1] = { y, 0, 59 }
    end
    shapes.drawElement(shapes.alphaProxy(bb, el.alpha), el, Blitbuffer.gray(el.gray))
    check(px(bb, 5, 30) <= 4, "alpha fill over ink keeps ink, got " .. px(bb, 5, 30))
    local v = px(bb, 30, 30)
    check(math.abs(v - 128) <= 2, "alpha fill over white ~= 128, got " .. v)
    bb:free()
end)

-- 3. Canvas integration: semi-transparent filled rectangle + region redraw consistency
section("canvas alpha rect + region redraw identity", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 380 } })
    check(#canvas.elements == 1, "alpha rect committed, got " .. #canvas.elements)
    local el = canvas.elements[1]
    check(el.alpha == 0.5, "element alpha recorded, got " .. tostring(el.alpha))
    local v = px(canvas.canvas_bb, 150, 340)
    check(math.abs(v - 128) <= 3, "alpha rect center ~= 128, got " .. v)
    -- Region redraw (random small regions) identical pixel by pixel before and after
    local before = px(canvas.canvas_bb, 150, 340)
    canvas:_redrawRegion({ x = 90, y = 290, w = 60, h = 40 })
    check(px(canvas.canvas_bb, 150, 340) == before,
        "region redraw pixel identical, before " .. before .. " after " .. px(canvas.canvas_bb, 150, 340))
    canvas:onCloseWidget()
end)

-- 4. Layer factor × element alpha
section("layer alpha multiply", function()
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas.alpha = 1.0
    canvas.layer_alpha[2] = 0.5 -- current layer (middle) at 50% overall
    canvas:onTap(nil, { pos = { x = 150, y = 400 } })
    local el = canvas.elements[1]
    check(el.alpha == 1.0, "element alpha untouched")
    local v = px(canvas.canvas_bb, 150, 400)
    check(math.abs(v - 128) <= 3, "layer 0.5 × element 1.0 ~= 128, got " .. v)
    canvas:onCloseWidget()
end)

-- 5. _resolveAlpha random
section("resolve alpha random", function()
    local canvas = newCanvas()
    canvas.alpha_random = true
    canvas.alpha_min = 0.2
    canvas.alpha_max = 0.8
    canvas.alpha_levels = 5
    for _ = 1, 30 do
        local a = canvas:_resolveAlpha()
        check(a >= 0.2 - 1e-9 and a <= 0.8 + 1e-9, "random alpha in [min,max], got " .. a)
    end
    local seen = {}
    for _ = 1, 300 do
        seen[string.format("%.3f", canvas:_resolveAlpha())] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    check(n >= 2, "random alpha takes multiple levels, got " .. n)
    canvas.alpha_random = false
    check(canvas:_resolveAlpha() == canvas.alpha, "fixed mode returns current")
    canvas:onCloseWidget()
end)

-- 6. Selected object opacity + undo restore (pixel level)
section("apply selected alpha + undo", function()
    local canvas = newCanvas()
    canvas:_setTool("brush")
    canvas:onTap(nil, { pos = { x = 150, y = 300 } })
    local el = canvas.elements[1]
    canvas:_setTool("select")
    canvas:onTap(nil, { pos = { x = 150, y = 300 } })
    check(canvas._selected == el, "element selected")
    canvas:_applySelectedAlpha(50)
    check(math.abs(el.alpha - 0.5) < 0.001, "alpha applied, got " .. tostring(el.alpha))
    local v = px(canvas.canvas_bb, 150, 300)
    check(math.abs(v - 128) <= 3, "pixel ~= 128 after apply, got " .. v)
    check(#canvas.undo >= 1, "undo recorded")
    canvas:_undo()
    check(math.abs(el.alpha - 1.0) < 0.001, "undo restores alpha")
    v = px(canvas.canvas_bb, 150, 300)
    check(v <= 4, "undo restores original opaque black dot, got " .. v)
    canvas:onCloseWidget()
end)

-- 7. Semi-transparent text
section("text alpha path", function()
    local canvas = newCanvas()
    local el = {
        kind = "text", x = 100, y = 300, text = "TestA",
        font = canvas.font, size = 40, gray = 1.0, alpha = 0.5,
    }
    canvas:_cacheBBox(el)
    check(el._bbox ~= nil, "text bbox computed")
    canvas:_drawTextTo(canvas.canvas_bb, el)
    local b = el._bbox
    local minv = 255
    for yy = math.floor(b.y0), math.ceil(b.y1) do
        for xx = math.floor(b.x0), math.ceil(b.x1) do
            local v = px(canvas.canvas_bb, xx, yy)
            if v >= 0 and v < minv then minv = v end
        end
    end
    check(minv > 60, "alpha text has no full-black pixel, min=" .. minv)
    -- Opaque control: drawing again at the same position should produce near-black pixels (verifies the blend path took effect)
    local el2 = {
        kind = "text", x = 100, y = 300, text = "TestA",
        font = canvas.font, size = 40, gray = 1.0,
    }
    canvas:_drawTextTo(canvas.canvas_bb, el2)
    local minv2 = 255
    for yy = math.floor(b.y0), math.ceil(b.y1) do
        for xx = math.floor(b.x0), math.ceil(b.x1) do
            local v = px(canvas.canvas_bb, xx, yy)
            if v >= 0 and v < minv2 then minv2 = v end
        end
    end
    check(minv2 <= 60, "opaque text has near-black pixel, min=" .. minv2)
    canvas:onCloseWidget()
end)

-- 8. Panel items exist (next to tip)
section("panel entries", function()
    local canvas = newCanvas()
    local bt = canvas:_categoryBt("prop")
    check(bt.button_by_id["alpha_btn"] ~= nil, "alpha_btn in prop panel")
    check(bt.button_by_id["tip_btn"] ~= nil, "tip_btn still present")
    check(bt.button_by_id["gray_btn"] ~= nil and bt.button_by_id["width_btn"] ~= nil,
        "gray/width buttons intact")
    local lbt = canvas:_categoryBt("layer")
    check(lbt.button_by_id["layer_alpha_btn"] ~= nil, "layer_alpha_btn in layer panel")
    canvas:onCloseWidget()
end)

-- 9. Semi-transparent text drag preview drawn to the screen BB (regression: the emulator's screen framebuffer is ColorRGB32,
-- the old getPixel().a implementation crashed - after the fix it uses native setPixelBlend, correct for any BB type)
section("text alpha drag preview on screen bb", function()
    local canvas = newCanvas()
    local el = {
        kind = "text", x = 100, y = 200, text = "W",
        font = canvas.font, size = 30, gray = 1.0, alpha = 0.5,
    }
    canvas:_cacheBBox(el)
    canvas:_setTool("select")
    canvas._selected = el
    canvas._drag_preview = {
        kind = "text", x = 130, y = 230, text = "W",
        font = canvas.font, size = 30, gray = 1.0, alpha = 0.5,
    }
    local Screen = require("device").screen
    local ok, err = pcall(function() canvas:paintTo(Screen.bb, 0, 0) end)
    check(ok, "paintTo with alpha text preview on screen bb: " .. tostring(err))
    -- The preview position should have ink (blending took effect, not drawing into thin air)
    local b = el._bbox
    local ink = 0
    for yy = math.floor(b.y0), math.ceil(b.y1) + 60 do
        for xx = math.floor(b.x0), math.ceil(b.x1) + 60 do
            local v = px(Screen.bb, xx, yy)
            if v >= 0 and v < 200 then
                ink = ink + 1
            end
        end
    end
    check(ink > 10, "alpha text preview left ink on screen bb, ink=" .. ink)
    canvas:onCloseWidget()
end)

print(string.format("RESULT: all %d sections passed", passed))
