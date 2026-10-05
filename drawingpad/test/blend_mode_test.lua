--[[--
Opacity blend mode unit tests:
1. shapes.blendModePixel formulas for the three modes (normal/multiply/dodge)
2. shapes.alphaProxy with mode: white background/over ink/out-of-bounds clipping
3. Canvas integration: where two 50% black multiply rectangles overlap it is darker than normal (stacked ink multiplies)
4. Blend mode persists with the element: after the canvas switches back to normal and a region is redrawn, old elements still reproduce as multiply;
   new elements blend as normal
5. dodge: mid-grey 50% over a dark background is lighter than normal; black ink dodge doesn't change the background
6. The opacity settings popup has a blend mode key; tapping cycles Normal -> Multiply -> Dodge -> Normal
7. const.SETTING_KEYS contains alpha_blend (persisted on exit)

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/blend_mode_test.lua
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
local const = require("drawingpad.const")
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

-- 1. blendModePixel formulas
section("blendModePixel formulas", function()
    local bb = Blitbuffer.new(4, 4, Blitbuffer.TYPE_BB8)
    -- normal: out = d + a·(ink-d) —— d=100, ink=0, a=128 → ≈50
    bb:setPixel(0, 0, Blitbuffer.Color8(100))
    shapes.blendModePixel(bb, 0, 0, 0, 128, "normal")
    check(math.abs(px(bb, 0, 0) - 50) <= 1, "normal d100 ink0 a50% ~= 50, got " .. px(bb, 0, 0))
    -- multiply: out = d·(1-a·(255-ink)/255) —— d=64, ink=128, a=128 → 64·(1-0.25)=48
    bb:setPixel(1, 0, Blitbuffer.Color8(64))
    shapes.blendModePixel(bb, 1, 0, 128, 128, "multiply")
    check(math.abs(px(bb, 1, 0) - 48) <= 1, "multiply d64 ink128 a50% ~= 48, got " .. px(bb, 1, 0))
    -- dodge: out = (1-a)·d + a·min(255, ink+d) —— d=64, ink=128, a=128 → (64+192)/2=128
    bb:setPixel(2, 0, Blitbuffer.Color8(64))
    shapes.blendModePixel(bb, 2, 0, 128, 128, "dodge")
    check(math.abs(px(bb, 2, 0) - 128) <= 1, "dodge d64 ink128 a50% ~= 128, got " .. px(bb, 2, 0))
    -- dodge with black ink doesn't change the background: d=200, ink=0 -> 200
    bb:setPixel(3, 0, Blitbuffer.Color8(200))
    shapes.blendModePixel(bb, 3, 0, 0, 128, "dodge")
    check(px(bb, 3, 0) == 200, "dodge black ink keeps dest, got " .. px(bb, 3, 0))
    -- Unknown modes are treated as normal (no crash)
    bb:setPixel(0, 1, Blitbuffer.Color8(100))
    shapes.blendModePixel(bb, 0, 1, 0, 128, "bogus")
    check(math.abs(px(bb, 0, 1) - 50) <= 1, "unknown mode falls back to normal, got " .. px(bb, 0, 1))
    bb:free()
end)

-- 1b. LUT identical to the blendModePixel formula for all 256 values (fast path equivalence)
section("blend LUT matches blendModePixel for all dest", function()
    for _, mode in ipairs{ "normal", "multiply", "dodge" } do
        for _, ink in ipairs{ 0, 1, 64, 128, 254, 255 } do
            for _, a255 in ipairs{ 1, 32, 128, 200, 255 } do
                local lut = shapes.buildBlendLUT(mode, ink, a255)
                local bb = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BB8)
                for d = 0, 255 do
                    bb:setPixel(0, 0, Blitbuffer.Color8(d))
                    shapes.blendModePixel(bb, 0, 0, ink, a255, mode)
                    local expect = px(bb, 0, 0)
                    if lut[d] ~= expect then
                        bb:free()
                        error(string.format("FAIL: LUT[%s ink=%d a=%d] d=%d lut=%s expect=%s",
                            mode, ink, a255, d, tostring(lut[d]), tostring(expect)))
                    end
                end
                bb:free()
            end
        end
    end
end)

-- 2. alphaProxy with mode
section("alphaProxy multiply/dodge over white & ink", function()
    local bb = Blitbuffer.new(30, 10, Blitbuffer.TYPE_BB8)
    bb:paintRect(0, 0, 30, 10, Blitbuffer.COLOR_WHITE)
    -- multiply 50% black on white = same as normal (white is the multiplicative identity)
    local pm = shapes.alphaProxy(bb, 0.5, "multiply")
    pm:paintRect(0, 0, 10, 10, Blitbuffer.gray(1.0))
    check(math.abs(px(bb, 5, 5) - 128) <= 2, "multiply black 50% on white ~= 128, got " .. px(bb, 5, 5))
    -- multiply mid-grey 50% on white = (1-a)·255 + a·ink ≈ 191 (multiply only differs over ink)
    pm:paintRect(10, 0, 10, 10, Blitbuffer.gray(0.5))
    check(math.abs(px(bb, 15, 5) - 191) <= 2, "multiply midgray 50% on white ~= 191, got " .. px(bb, 15, 5))
    -- dodge mid-grey 50% on white = white (128+255 clamps to 255, blended with white stays white)
    local pd = shapes.alphaProxy(bb, 0.5, "dodge")
    pd:paintRect(20, 0, 10, 10, Blitbuffer.gray(0.5))
    check(px(bb, 25, 5) >= 253, "dodge midgray on white stays white, got " .. px(bb, 25, 5))
    -- Over ink: multiply mid-grey 50% over d=64 -> 64·(1-0.5·127/255) ≈ 48 (normal would be 96)
    bb:paintRect(10, 0, 10, 10, Blitbuffer.Color8(64))
    pm:paintRect(10, 0, 10, 10, Blitbuffer.gray(0.5))
    check(math.abs(px(bb, 15, 5) - 48) <= 2, "multiply midgray over 64 ~= 48, got " .. px(bb, 15, 5))
    -- Out-of-bounds clipping is safe (after native paintRect clipping the setter only receives in-canvas coordinates)
    local bb2 = Blitbuffer.new(10, 10, Blitbuffer.TYPE_BB8)
    bb2:paintRect(0, 0, 10, 10, Blitbuffer.COLOR_WHITE)
    local p2 = shapes.alphaProxy(bb2, 0.5, "multiply")
    p2:paintRect(-5, -5, 10, 10, Blitbuffer.gray(1.0))
    check(math.abs(px(bb2, 0, 0) - 128) <= 2, "clipped multiply blends in-canvas, got " .. px(bb2, 0, 0))
    check(px(bb2, 8, 8) >= 253, "clipped multiply leaves outside untouched, got " .. px(bb2, 8, 8))
    bb2:free()
    bb:free()
end)

-- 3. Canvas integration: two 50% black multiply rectangles, overlap = 64 (still 128 under normal)
section("canvas multiply rects overlap darker", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.alpha_blend = "multiply"
    canvas.gray = 1.0
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    canvas:onPan(nil, { pos = { x = 150, y = 250 }, start_pos = { x = 150, y = 250 } })
    canvas:onPanRelease(nil, { pos = { x = 250, y = 350 } })
    check(#canvas.elements == 2, "two rects committed, got " .. #canvas.elements)
    check(canvas.elements[1].blend == "multiply", "blend recorded on element")
    local v_single = px(canvas.canvas_bb, 120, 220) -- only inside the first rectangle
    local v_overlap = px(canvas.canvas_bb, 175, 275) -- where both overlap
    check(math.abs(v_single - 128) <= 2, "single rect ~128, got " .. v_single)
    check(math.abs(v_overlap - 64) <= 2, "multiply overlap ~64, got " .. v_overlap)
    canvas:onCloseWidget()
end)

-- 4. Blend mode persists with the element (reproduced on redraw) + new elements use the current setting
section("blend persists per element across redraw", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    canvas.alpha = 0.5
    canvas.alpha_blend = "multiply"
    canvas.gray = 1.0
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    local el = canvas.elements[1]
    -- Switch back to normal, white-out and redraw the whole region: the multiply element must reproduce as before (still ~128 on white)
    canvas.alpha_blend = "normal"
    local reg = canvas:_elementRegion(el)
    canvas:_redrawRegion(reg)
    local v = px(canvas.canvas_bb, 150, 250)
    check(math.abs(v - 128) <= 2, "multiply element reproduced after redraw, got " .. v)
    -- A new normal-mode mid-grey 50% element on top: out = 0.5·128 + 0.5·128 = 128;
    -- if it wrongly kept multiply it would be 64
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 130, y = 230 }, start_pos = { x = 130, y = 230 } })
    canvas:onPanRelease(nil, { pos = { x = 180, y = 280 } })
    check(canvas.elements[2].blend == "normal", "new element uses current mode")
    local v2 = px(canvas.canvas_bb, 155, 255)
    check(math.abs(v2 - 128) <= 2, "normal midgray over 128 stays ~128, got " .. v2)
    canvas:onCloseWidget()
end)

-- 5. dodge lightens: mid-grey 50% over a dark background d≈64 -> ≈128 (normal is 96)
section("canvas dodge lightens over dark ink", function()
    local canvas = newCanvas()
    canvas:_setTool("rect")
    -- Bottom: opaque dark grey d≈64
    canvas.alpha = 1.0
    canvas.gray = 0.75
    canvas.rect_filled = true
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
    -- Top: linear dodge mid-grey 50%
    canvas.alpha = 0.5
    canvas.alpha_blend = "dodge"
    canvas.gray = 0.5
    canvas:onPan(nil, { pos = { x = 120, y = 220 }, start_pos = { x = 120, y = 220 } })
    canvas:onPanRelease(nil, { pos = { x = 220, y = 320 } })
    local v = px(canvas.canvas_bb, 160, 260)
    check(math.abs(v - 128) <= 3, "dodge midgray 50% over d64 ~= 128, got " .. v)
    canvas:onCloseWidget()
end)

-- 6. Blend mode row in the settings popup: exists + cycles
section("alpha dialog blend mode row cycles", function()
    local canvas = newCanvas()
    check(canvas.alpha_blend == "normal", "default blend is normal")
    local captured
    canvas._showCenteredButtons = function(_, title, btns, width)
        captured = btns
        return nil, nil
    end
    canvas:_pickAlpha()
    check(captured ~= nil, "dialog captured")
    check(#captured == 3, "alpha dialog has 3 rows, got " .. #captured)
    local mode_btn = captured[3][1]
    check(mode_btn.id == "alpha_blend_btn", "3rd row is blend button, got " .. tostring(mode_btn.id))
    local txt = mode_btn.text or ""
    check(txt:find("Blend"), "blend button label, got " .. txt)
    mode_btn.callback()
    check(canvas.alpha_blend == "multiply", "cycle 1 -> multiply, got " .. tostring(canvas.alpha_blend))
    mode_btn.callback()
    check(canvas.alpha_blend == "dodge", "cycle 2 -> dodge, got " .. tostring(canvas.alpha_blend))
    mode_btn.callback()
    check(canvas.alpha_blend == "normal", "cycle 3 -> normal, got " .. tostring(canvas.alpha_blend))
    canvas:onCloseWidget()
end)

-- 7. Persisted key
section("SETTING_KEYS has alpha_blend", function()
    local found = false
    for _, k in ipairs(const.SETTING_KEYS) do
        if k == "alpha_blend" then
            found = true
            break
        end
    end
    check(found, "alpha_blend not in SETTING_KEYS")
end)

-- 7b. Semi-transparent wide slash tips are not clipped (regression: when the tmp pad only counted 0.5w the slash tip corners were cut off)
section("thick slash tip not clipped in alpha compositing", function()
    -- slash tip radius = 0.707w + strip t/2 (max(2,w/3)) ≈ 0.87w; w=100 -> 87px,
    -- the old pad (52px) clipped the excess -> the semi-transparent ink bbox was 30+px smaller than the near-opaque one
    local function inkBBox(alpha)
        local bb = Blitbuffer.new(300, 300, Blitbuffer.TYPE_BB8)
        bb:paintRect(0, 0, 300, 300, Blitbuffer.COLOR_WHITE)
        local el = { kind = "freehand", points = { { x = 150, y = 150 } },
            width = 100, gray = 1.0, alpha = alpha, tip = "slash" }
        shapes.drawElement(shapes.alphaProxy(bb, alpha, "normal"), el, Blitbuffer.gray(el.gray))
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for yy = 0, 299 do
            for xx = 0, 299 do
                if px(bb, xx, yy) < 250 then
                    if xx < x0 then x0 = xx end
                    if xx > x1 then x1 = xx end
                    if yy < y0 then y0 = yy end
                    if yy > y1 then y1 = yy end
                end
            end
        end
        bb:free()
        return x0, y0, x1, y1
    end
    local ox0, oy0, ox1, oy1 = inkBBox(0.99) -- a255=252, still goes through the tmp single-pass composite, near opaque
    local ax0, ay0, ax1, ay1 = inkBBox(0.5)
    check(math.abs(ax0 - ox0) <= 2 and math.abs(ay0 - oy0) <= 2
        and math.abs(ax1 - ox1) <= 2 and math.abs(ay1 - oy1) <= 2,
        string.format("slash ink bbox: alpha0.99=(%d,%d,%d,%d) alpha0.5=(%d,%d,%d,%d)",
            ox0, oy0, ox1, oy1, ax0, ay0, ax1, ay1))
    -- The tip really extends beyond the 0.5w pad (otherwise this test couldn't catch the old bug)
    check(150 - ox0 > 60 and ox1 - 150 > 60 and 150 - oy0 > 60 and oy1 - 150 > 60,
        string.format("slash tip extends beyond 0.5w, got bbox (%d,%d,%d,%d)", ox0, oy0, ox1, oy1))
end)

-- 8. Opacity popup real paint (pitfall 14c: layout problems that construct OK but crash on paint can't be caught otherwise)
section("alpha dialog real paint with blend row", function()
    local canvas = newCanvas()
    local UIManager = require("ui/uimanager")
    local orig_show, orig_close = UIManager.show, UIManager.close
    UIManager.show = function() end
    UIManager.close = function() end
    local bt
    local orig_scb = canvas._showCenteredButtons
    canvas._showCenteredButtons = function(s, title, btns, wf)
        bt, canvas._dlg_popup = orig_scb(s, title, btns, wf)
        return bt, canvas._dlg_popup
    end
    local ok, err = pcall(function()
        canvas:_pickAlpha()
    end)
    UIManager.show, UIManager.close = orig_show, orig_close
    check(ok, "pickAlpha runs: " .. tostring(err))
    check(bt ~= nil, "real ButtonTable built")
    local n = 0
    for _ in pairs(bt.button_by_id or {}) do
        n = n + 1
    end
    check(n == 5, "alpha dialog has 5 id'd buttons (max/min/levels/fixed/blend), got " .. n)
    local Screen = require("device").screen
    local pok = pcall(function() bt:paintTo(Screen.bb, 0, 0) end)
    check(pok, "alpha dialog paints without crash")
    canvas:onCloseWidget()
end)

print(string.format("RESULT: %d passed", passed))
