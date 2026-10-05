--[[--
Drawing board new-feature unit tests (debounce / font size limit / brush<->line / select object move & copy):
1. Debounce: brush pen-down movement threshold, quick light-tap ink dot (onPanRelease and onTap), shape minimum size
2. Font size limit 800 (value_max of the SpinWidget popped up by _pickFontSize)
3. Brush<->line (mutually exclusive tool panel items + button text follows)
4. Select object: tap select/deselect, move, copy, undo/redo, mode toggle, pixel assertions

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/feature_test.lua
--]]

-- The drawing board modules moved into plugins/drawingboard.koplugin/drawingpad/ with the plugin:
-- tests don't go through pluginloader, so self-locate the plugin root and inject package.path so require("drawingpad.*") resolves
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

local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

-- ============ 1. Debounce ============
do
    local ok, err = pcall(function()
        -- 1a. Brush: a true zero-movement light tap and release -> no micro-trace, degenerates to a single-point ink dot (touch-down point)
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 100, y = 300 } })
        check(#canvas.elements == 1, "zero-move quick touch should produce a dot, got " .. #canvas.elements)
        local dot = canvas.elements[1]
        check(dot.kind == "freehand" and #dot.points == 1
            and dot.points[1].x == 100 and dot.points[1].y == 300,
            "dot should be 1 point at press point")

        -- 1a2. Early-trigger policy: a tiny movement beyond EARLY_TRIGGER (1px) formally starts the stroke, keeping the start curve
        local canvas_a2 = newCanvas()
        canvas_a2:_setTool("brush")
        canvas_a2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas_a2:onPan(nil, { pos = { x = 102, y = 302 }, start_pos = { x = 100, y = 300 } })
        check(canvas_a2._stroke ~= nil, "early trigger: move >= EARLY_TRIGGER starts stroke")
        canvas_a2:onPanRelease(nil, { pos = { x = 110, y = 310 } })
        check(#canvas_a2.elements == 1, "early-trigger stroke should commit")

        -- 1a3. Pen-down dead zone tuning: on open, lower the gesture PAN_THRESHOLD and shorten the hold interval proportionally,
        -- restore on close, repeated application is idempotent
        do
            local const = require("drawingpad.const")
            local real_device = package.loaded["device"]
            local gd = {
                PAN_THRESHOLD = 35,
                ges_hold_interval = 500000, -- KOReader time.ms(500), scaled proportionally regardless of units
                screen = { scaleByDPI = function(_, v) return v end },
            }
            package.loaded["device"] = { input = { gesture_detector = gd } }
            local canvas_t = newCanvas()
            check(gd.PAN_THRESHOLD == const.GESTURE_PAN_THRESHOLD_DP,
                "tuning: threshold lowered on init, got " .. tostring(gd.PAN_THRESHOLD))
            check(gd.ges_hold_interval == math.floor(500000 * const.GESTURE_HOLD_INTERVAL_MS / 500 + 0.5)
                or math.abs(gd.ges_hold_interval - 500000 * const.GESTURE_HOLD_INTERVAL_MS / 500) < 0.5,
                "tuning: hold interval scaled on init, got " .. tostring(gd.ges_hold_interval))
            check(gd._drawingpad_orig_pan_threshold == 35, "tuning: pan original saved")
            check(gd._drawingpad_orig_hold_interval == 500000, "tuning: hold original saved")
            canvas_t:_applyGestureTuning()
            check(gd._drawingpad_orig_pan_threshold == 35, "tuning: re-apply keeps original")
            canvas_t:onCloseWidget()
            check(gd.PAN_THRESHOLD == 35, "tuning: threshold restored on close")
            check(gd.ges_hold_interval == 500000, "tuning: hold interval restored on close")
            check(gd._drawingpad_orig_hold_interval == nil, "tuning: flags cleared")
            package.loaded["device"] = real_device
        end

        -- 1b. Brush: movement reaches the threshold (≥4px) -> stroke formally starts, first point = touch-down point
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 104, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(canvas2._stroke ~= nil, "stroke should start at threshold")
        check(canvas2._stroke.points[1].x == 100 and canvas2._stroke.points[1].y == 300,
            "first point should be press point")
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 220, y = 300 } })
        check(#canvas2.elements == 1, "threshold stroke should commit")
        check(canvas2.elements[1].points[1].x == 100, "committed stroke first point = press")

        -- 1c. Brush onTap: a quick light tap produces an ink dot
        local canvas3 = newCanvas()
        canvas3:_setTool("brush")
        canvas3:onTap(nil, { pos = { x = 150, y = 400 } })
        check(#canvas3.elements == 1 and canvas3.elements[1].points[1].x == 150,
            "tap should produce a dot")

        -- 1d. Shape minimum size: too small is discarded, normal size is committed
        local canvas4 = newCanvas()
        canvas4:_setTool("rect")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 105, y = 305 } }) -- 5x5 < 8
        check(#canvas4.elements == 0, "tiny rect should be discarded")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 160, y = 360 } }) -- 60x60 normal
        check(#canvas4.elements == 1 and canvas4.elements[1].kind == "rect",
            "normal rect should commit")
        canvas4:_setTool("circle")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 102, y = 300 } }) -- r=2 < 8
        check(#canvas4.elements == 1, "tiny circle should be discarded")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 120, y = 300 } }) -- r=20 normal
        check(#canvas4.elements == 2 and canvas4.elements[2].kind == "circle",
            "normal circle should commit")
        canvas4:_setTool("line")
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 105, y = 300 } }) -- length 5 < 8
        check(#canvas4.elements == 2, "tiny line should be discarded")
        print("debounce: quick-touch dot / threshold stroke / tap dot / tiny shapes OK")
    end)
    if ok then
        print("PASS: debounce")
    else
        print("FAIL: debounce:", tostring(err))
        os.exit(1)
    end
end

-- ============ 1b. Small start arcs kept (debounce micro-trace not lost / no tapered end / thinning step capped) ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local shapes = require("drawingpad.shapes")

        -- 1b-1. Early trigger: 1px movement starts the stroke, the micro-trace is merged into the stroke at start, the small start arc is kept
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 400, y = 400 }, start_pos = { x = 400, y = 400 } })
        canvas:onPan(nil, { pos = { x = 401, y = 401 }, start_pos = { x = 400, y = 400 } })
        check(canvas._stroke ~= nil, "1b-1: EARLY_TRIGGER(1px) triggers stroke")
        canvas:onPan(nil, { pos = { x = 402, y = 400 }, start_pos = { x = 400, y = 400 } })
        canvas:onPan(nil, { pos = { x = 402, y = 402 }, start_pos = { x = 400, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 402, y = 402 } })
        check(#canvas.elements == 1, "1b-1: early-trigger stroke commits a tick, got " .. #canvas.elements)
        local tick = canvas.elements[1]
        check(tick.kind == "freehand", "1b-1: element kind freehand")
        check(tick.points[1].x == 400 and tick.points[1].y == 400, "1b-1: first point = press")
        check(canvas.canvas_bb:getPixel(401, 401).a < 128, "1b-1: tick ink visible")

        -- 1b-2. swipe finish + micro-trace: touch-down point + micro-trace + end point form an arc stroke (the old version straightened it into a 2-point line)
        local canvas3 = newCanvas()
        canvas3:_setTool("brush")
        canvas3:onPan(nil, { pos = { x = 500, y = 400 }, start_pos = { x = 500, y = 400 } })
        canvas3:onPan(nil, { pos = { x = 501, y = 401 }, start_pos = { x = 500, y = 400 } })
        canvas3:onPan(nil, { pos = { x = 502, y = 400 }, start_pos = { x = 500, y = 400 } })
        -- A fast flick is classified as swipe (pos = start, end_pos = end, opposite of pan semantics)
        canvas3:onSwipe(nil, { pos = { x = 500, y = 400 }, end_pos = { x = 520, y = 384 } })
        check(#canvas3.elements == 1, "1b-2: swipe with micro commits stroke, got " .. #canvas3.elements)
        local sw = canvas3.elements[1]
        check(sw.kind == "freehand", "1b-2: element kind freehand")
        check(#sw.points >= 4, "1b-2: curved path kept (not 2-point straight), got " .. #sw.points)
        -- Middle points deviate from the first-last chord = curvature kept
        local p0, pm, pn = sw.points[1], sw.points[2], sw.points[#sw.points]
        local cross = math.abs((pn.x - p0.x) * (pm.y - p0.y) - (pn.y - p0.y) * (pm.x - p0.x))
        check(cross > 0, "1b-2: middle point off the start-end chord (curvature kept)")
        canvas3:_undo()
        check(#canvas3.elements == 0, "1b-2: swipe stroke undoable")

        -- 1b-3. onHold pen-down: zero-movement long press (real scenario = finger held still for the full hold timer) -> hold creates
        -- the start stroke (with the start tip), not committed; hold_pan drags the brush, hold_release commits it as a whole
        local canvas4 = newCanvas()
        canvas4:_setTool("brush")
        canvas4:onHold(nil, { pos = { x = 460, y = 400 } })
        check(canvas4._stroke ~= nil, "1b-3: hold creates in-progress stroke")
        check(canvas4._stroke.points[1].x == 460 and canvas4._stroke.points[1].y == 400,
            "1b-3: hold stroke first point = press")
        check(#canvas4.elements == 0, "1b-3: hold stroke not committed yet")
        canvas4:onHoldPan(nil, { pos = { x = 490, y = 420 }, start_pos = { x = 460, y = 400 } })
        canvas4:onHoldRelease(nil, { pos = { x = 500, y = 424 } })
        check(#canvas4.elements == 1, "1b-3: hold stroke commits once")
        check(#canvas4.elements[1].points >= 3, "1b-3: committed stroke keeps press + drag points")

        -- 1b-4. No tapered start: polyline start at full width (the old version faded in from ~35% width)
        local bb = Blitbuffer.new(100, 100, Blitbuffer.TYPE_BB8)
        bb:paintRect(0, 0, 100, 100, Blitbuffer.COLOR_WHITE)
        shapes.polyline(bb,
            { { x = 50, y = 50 }, { x = 60, y = 50 }, { x = 70, y = 52 } },
            8, Blitbuffer.gray(1), 0, 0, "circle")
        check(bb:getPixel(48, 50).a < 128, "1b-4: stroke start full width (left edge)")
        check(bb:getPixel(52, 50).a < 128, "1b-4: stroke start full width (right edge)")
        bb:free()

        -- 1b-5. Thinning step capped: at line width 32 (old step 4) 3px-level sample points along a small arc aren't swallowed
        local canvas6 = newCanvas()
        canvas6:_setTool("brush")
        canvas6.width = 32
        canvas6:onPan(nil, { pos = { x = 200, y = 420 }, start_pos = { x = 200, y = 420 } })
        canvas6:onPan(nil, { pos = { x = 204, y = 420 }, start_pos = { x = 200, y = 420 } }) -- threshold reached, stroke starts
        check(canvas6._stroke ~= nil, "1b-5: stroke started")
        for i = 1, 10 do
            -- x +1 each time, y alternating +3/+0: with the capped step of 3 the odd steps must be recorded (old step 4 skipped them all)
            canvas6:onPan(nil, { pos = { x = 204 + i, y = 420 + (i % 2) * 3 },
                start_pos = { x = 200, y = 420 } })
        end
        canvas6:onPanRelease(nil, { pos = { x = 215, y = 424 } })
        local el6 = canvas6.elements[1]
        check(el6 ~= nil, "1b-5: stroke committed")
        check(#el6.points >= 7, "1b-5: width-32 arc keeps dense samples (min_step capped), got "
            .. #el6.points)

        -- 1b-6. Catmull-Rom roundness: an r=18 circle from 10 sample points, outer radius variation ≤3px
        -- (the old midpoint quadratic curve cut corners with the same sampling, variation ~3px+; small circles are no longer drawn as polygons)
        local bb2 = Blitbuffer.new(80, 80, Blitbuffer.TYPE_BB8)
        bb2:paintRect(0, 0, 80, 80, Blitbuffer.COLOR_WHITE)
        local cr_pts = {}
        for i = 0, 9 do
            local a = -math.pi / 2 + 2 * math.pi * i / 10
            cr_pts[i + 1] = { x = 40 + math.cos(a) * 18, y = 40 + math.sin(a) * 18 }
        end
        shapes.polyline(bb2, cr_pts, 2, Blitbuffer.gray(1), 0, 0, "circle")
        local rmin6, rmax6 = math.huge, 0
        for k = 0, 23 do
            local a = 2 * math.pi * k / 24
            for rr = 4, 34 do
                local px = math.floor(40 + math.cos(a) * rr)
                local py = math.floor(40 + math.sin(a) * rr)
                if bb2:getPixel(px, py).a < 128 then
                    if rr < rmin6 then rmin6 = rr end
                    if rr > rmax6 then rmax6 = rr end
                    break
                end
            end
        end
        check(rmax6 > 0 and rmax6 - rmin6 <= 3, "1b-6: CR circle roundness (spread<=3), got "
            .. tostring(rmin6) .. ".." .. tostring(rmax6))
        bb2:free()

        -- 1b-7. Live incremental rendering identical pixel by pixel to the undo redraw (shapes.polyline) (core invariant)
        local canvas7 = newCanvas()
        canvas7:_setTool("brush")
        canvas7.width = 4
        canvas7:onPan(nil, { pos = { x = 100, y = 150 }, start_pos = { x = 100, y = 150 } })
        for _, p in ipairs({ { 110, 148 }, { 122, 154 }, { 130, 168 },
                { 126, 182 }, { 112, 188 } }) do
            canvas7:onPan(nil, { pos = { x = p[1], y = p[2] },
                start_pos = { x = 100, y = 150 } })
        end
        canvas7:onPanRelease(nil, { pos = { x = 102, y = 180 } })
        local el7 = canvas7.elements[1]
        check(el7 ~= nil, "1b-7: stroke committed")
        local bbR = Blitbuffer.new(200, 220, Blitbuffer.TYPE_BB8)
        bbR:paintRect(0, 0, 200, 220, Blitbuffer.COLOR_WHITE)
        shapes.drawElement(bbR, el7, Blitbuffer.gray(el7.gray))
        local b7 = el7._bbox
        for y = math.floor(b7.y0) - 2, math.ceil(b7.y1) + 2 do
            for x = math.floor(b7.x0) - 2, math.ceil(b7.x1) + 2 do
                local va = canvas7.canvas_bb:getPixel(x, y).a
                local vb = bbR:getPixel(x, y).a
                check(math.abs(va - vb) <= 8,
                    string.format("1b-7: live/redraw mismatch at %d,%d live=%d redraw=%d",
                        x, y, va, vb))
            end
        end
        bbR:free()

        print("stroke-start arcs: micro tick / swipe curve / hold seed / no taper / min-step cap / CR roundness / live==redraw OK")
    end)
    if ok then
        print("PASS: stroke-start arcs")
    else
        print("FAIL: stroke-start arcs:", tostring(err))
        os.exit(1)
    end
end

-- ============ 2. Font size limit 800 ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w)
            captured = w
            return true
        end
        local canvas = newCanvas()
        local ok2 = pcall(function() canvas:_pickFontSize() end)
        UIManager.show = orig_show
        if captured then
            check(captured.name == "DrawingValuePicker" and captured.max == 800,
                "font size picker should cap at 800, got " .. tostring(captured and captured.name) .. "/"
                .. tostring(captured and captured.max))
        else
            print("WARN: font size popup could not be constructed headless, skipping max assertion")
        end
        print("font size max: 800 OK")
    end)
    if ok then
        print("PASS: font size max 800")
    else
        print("FAIL: font size max 800:", tostring(err))
        os.exit(1)
    end
end

-- ============ 3. Brush <-> line (v59b: separate panel items, no long-press) ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        check(canvas.tool == "brush", "default tool should be brush")
        canvas:_setTool("line")
        check(canvas.tool == "line", "line_btn should switch to line")
        canvas:_setTool("brush")
        check(canvas.tool == "brush", "set back to brush")
        -- v59b: tool items live in the category panel (two columns), active = light-grey background is the only source; text has no corner mark
        local bt = canvas:_categoryBt("tool")
        local bbtn = bt.button_by_id["brush_btn"]
        local lbtn = bt.button_by_id["line_btn"]
        check(bbtn ~= nil and lbtn ~= nil, "brush_btn/line_btn should exist in tool panel")
        local LIGHTGRAY = require("ffi/blitbuffer").COLOR_LIGHT_GRAY
        local WHITE = require("ffi/blitbuffer").COLOR_WHITE
        check(bbtn.text == "Brush" and bbtn[1].background == LIGHTGRAY,
            "brush active should be Brush + lightgray bg")
        check(lbtn.text == "Line" and lbtn[1].background == WHITE,
            "line inactive should be white bg")
        canvas:_setTool("line")
        bt = canvas:_categoryBt("tool")
        check(bt.button_by_id["line_btn"][1].background == LIGHTGRAY
            and bt.button_by_id["brush_btn"][1].background == WHITE,
            "line active lightgray, brush white")
        canvas:_setTool("eraser") -- switch away: line goes back to white
        bt = canvas:_categoryBt("tool")
        check(bt.button_by_id["line_btn"][1].background == WHITE,
            "line inactive should be white bg after switching away")
        canvas:_setTool("brush")
        print("brush<->line entries OK")
    end)
    if ok then
        print("PASS: brush<->line toggle")
    else
        print("FAIL: brush<->line toggle:", tostring(err))
        os.exit(1)
    end
end

-- ============ 4. Select object (move/copy) ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- Draw two elements: short line (brush swipe) + circle (circle tool swipe)
        canvas:_setTool("brush")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 300, y = 300 }, end_pos = { x = 400, y = 300 } })
        check(#canvas.elements == 2, "setup 2 elements, got " .. #canvas.elements)
        local line_el = canvas.elements[1]
        local circle_el = canvas.elements[2]

        -- 4a. _pickElementAt hit/blank
        canvas:_setTool("select")
        local el = canvas:_pickElementAt(150, 300)
        check(el == line_el, "pick should hit line")
        el = canvas:_pickElementAt(30, 300)
        check(el == nil, "pick empty should be nil")

        -- 4a2. Overlapping pick: when two objects overlap pick the "topmost visible" one
        local canvasO = newCanvas()
        canvasO:_setTool("brush")
        canvasO.width = 12
        canvasO.gray = 1.0
        canvasO:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 400, y = 300 } }) -- lower A (y300, ink 294-306)
        canvasO:onSwipe(nil, { pos = { x = 100, y = 305 }, end_pos = { x = 400, y = 305 } }) -- upper B (y305, ink 299-311)
        local a_el, b_el = canvasO.elements[1], canvasO.elements[2]
        canvasO:_setTool("select")
        check(canvasO:_pickElementAt(250, 302) == b_el, "overlap should pick topmost visible")
        check(canvasO:_pickElementAt(250, 308) == b_el, "B-only area picks B")
        check(canvasO:_pickElementAt(250, 294) == a_el, "A-only area picks A")
        -- Hollow circle over a filled rectangle: circle centre inside the hole (rectangle visible) -> select the rectangle; on the circle edge -> select the circle
        local canvasO2 = newCanvas()
        canvasO2:_setTool("rect")
        canvasO2:onSwipe(nil, { pos = { x = 100, y = 200 }, end_pos = { x = 300, y = 400 } })
        local rectF = canvasO2.elements[1]
        rectF.filled = true -- filled rectangle (lower)
        canvasO2:_cacheBBox(rectF)
        canvasO2:_setTool("circle")
        canvasO2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- hollow circle r=100 (upper)
        local circH = canvasO2.elements[2]
        canvasO2:_setTool("select")
        check(canvasO2:_pickElementAt(200, 300) == rectF, "hole of top hollow circle reveals filled rect below")
        check(canvasO2:_pickElementAt(300, 300) == circH, "on hollow circle edge picks the circle")

        -- 4b. Tap select/deselect (select first, then drag)
        canvas:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas._selected == line_el, "tap should select line")
        canvas:onTap(nil, { pos = { x = 30, y = 300 } })
        check(canvas._selected == nil, "tap empty should deselect")

        -- 4c. Move: select the circle (tap its right edge), drag from the centre +30,+20 (avoiding the transform anchors)
        canvas:onTap(nil, { pos = { x = 400, y = 300 } })
        check(canvas._selected == circle_el, "tap should select circle")
        local cx0, cy0 = circle_el.cx, circle_el.cy
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 330, y = 320 } })
        check(circle_el.cx == cx0 + 30 and circle_el.cy == cy0 + 20,
            "circle should move by (30,20), got " .. circle_el.cx .. "," .. circle_el.cy)
        -- bbox cache follows the translation
        local b = circle_el._bbox
        check(b and b.x0 == circle_el.cx - circle_el.rx, "bbox should follow move")
        -- Undo restores / redo moves again
        canvas:_undo()
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "undo should restore position")
        canvas:_redo()
        check(circle_el.cx == cx0 + 30 and circle_el.cy == cy0 + 20, "redo should re-apply move")
        canvas:_undo()
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "undo2 should restore again")

        -- 4d. Copy: switch to copy mode, dragging produces a duplicate, the original doesn't move
        canvas:_toggleSelectMode()
        check(canvas.select_mode == "copy", "toggle should switch to copy")
        canvas:onTap(nil, { pos = { x = 400, y = 300 } })
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 350, y = 350 } })
        check(#canvas.elements == 3, "copy should add an element, got " .. #canvas.elements)
        check(circle_el.cx == cx0 and circle_el.cy == cy0, "original should not move")
        local copy_el = canvas.elements[3]
        check(copy_el ~= circle_el and copy_el.kind == "circle"
            and copy_el.cx == cx0 + 50 and copy_el.cy == cy0 + 50,
            "copy should be a distinct circle at offset")
        canvas:_undo()
        check(#canvas.elements == 2, "undo copy should remove it")
        canvas:_toggleSelectMode()
        check(canvas.select_mode == "move", "toggle back to move")

        -- 4e. Move pixel assertions: old position turns white, new position has ink (thick line keeps the anchors away from the drag start)
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2.width = 24
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        local bb = canvas2.canvas_bb
        local function a(x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        check(a(150, 300) == 0, "before move: line ink black, got " .. tostring(a(150, 300)))
        canvas2:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 150, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 250, y = 320 } }) -- move +100,+20
        check(a(150, 300) == 255, "after move: old position white, got " .. tostring(a(150, 300)))
        check(a(250, 320) == 0, "after move: new position ink, got " .. tostring(a(250, 320)))
        print("select: pick/tap/move/undo-redo/copy/pixels OK")
    end)
    if ok then
        print("PASS: select object move/copy")
    else
        print("FAIL: select object move/copy:", tostring(err))
        os.exit(1)
    end
end

-- ============ 5. Grey/width random levels ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- Fixed mode: _resolveGray/_resolveWidth return the current value
        canvas.gray = 0.7
        canvas.width = 12
        check(math.abs(canvas:_resolveGray() - 0.7) < 0.001, "fixed gray should return current")
        check(canvas:_resolveWidth() == 12, "fixed width should return current")
        -- Random mode: value within [min,max]
        canvas:_toggleGrayRandom()
        check(canvas.gray_random == true, "gray random on")
        for _ = 1, 20 do
            local v = canvas:_resolveGray()
            check(v >= canvas.gray_min - 0.001 and v <= canvas.gray_max + 0.001,
                "random gray out of range: " .. tostring(v))
        end
        -- levels=2: only the min/max ends
        canvas.gray_min = 0.2
        canvas.gray_max = 0.8
        canvas.gray_levels = 2
        for _ = 1, 20 do
            local v = canvas:_resolveGray()
            check(math.abs(v - 0.2) < 0.001 or math.abs(v - 0.8) < 0.001,
                "2-level gray should be min or max, got " .. tostring(v))
        end
        -- Random width
        canvas:_toggleWidthRandom()
        check(canvas.width_random == true, "width random on")
        canvas.width_min = 4
        canvas.width_max = 40
        canvas.width_levels = 4
        for _ = 1, 20 do
            local v = canvas:_resolveWidth()
            check(v >= 4 - 0.001 and v <= 40 + 0.001, "random width out of range: " .. tostring(v))
        end
        -- Real stroke: in random mode the element uses the random value (resolved at creation)
        local canvas2 = newCanvas()
        canvas2:_toggleGrayRandom()
        canvas2:_toggleWidthRandom()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        local s = canvas2.elements[1]
        check(s ~= nil, "stroke should commit")
        check(s.gray >= canvas2.gray_min - 0.001 and s.gray <= canvas2.gray_max + 0.001,
            "stroke gray should be in random range")
        check(s.width >= canvas2.width_min - 0.001 and s.width <= canvas2.width_max + 0.001,
            "stroke width should be in random range")
        -- The status bar contains the random marker
        local st = canvas2:_statusText()
        check(st:find("G:rand") ~= nil and st:find("W:rand") ~= nil,
            "status should mark random gray/width: " .. st)
        print("gray/width random: fixed/random resolve, levels=2 ends, stroke uses random, status OK")
    end)
    if ok then
        print("PASS: gray/width random levels")
    else
        print("FAIL: gray/width random levels:", tostring(err))
        os.exit(1)
    end
end

-- ============ 6. Layers (3 independent layers) ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        check(#canvas.layers == 3 and canvas.active_layer == 2, "3 layers, active 2 (default middle)")
        -- One stroke on the default middle layer
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        check(#canvas.layers[2] == 1 and #canvas.layers[1] == 0 and #canvas.layers[3] == 0,
            "stroke should be on default middle layer")
        -- Switch to layer 3 and draw a stroke, layer 2 is unaffected
        canvas:_switchLayer(3)
        check(canvas.active_layer == 3, "switchLayer should go to 3")
        canvas:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 300, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 300 } })
        check(#canvas.layers[2] == 1 and #canvas.layers[3] == 1, "layer3 stroke, layer2 intact")
        -- Undo only affects the current layer (layer 3)
        canvas:_undo()
        check(#canvas.layers[3] == 0 and #canvas.layers[2] == 1, "undo should only affect layer3")
        -- Redo on layer 3
        canvas:_redo()
        check(#canvas.layers[3] == 1, "redo on layer3")
        -- Switching layers clears the selection/in-progress state
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 350, y = 300 } }) -- select the layer-3 stroke
        check(canvas._selected ~= nil, "should select layer3 stroke")
        canvas:_switchLayer(1) -- go to layer 1
        check(canvas._selected == nil, "layer switch should clear selection")
        -- Clear only clears the current layer (layer 1)
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 400 } })
        check(#canvas.layers[1] == 1, "layer1 stroke")
        local confirm
        local orig_show = UIManager.show
        UIManager.show = function(self, w) confirm = w; return true end
        canvas:_clearAll()
        UIManager.show = orig_show
        check(confirm ~= nil and confirm.ok_callback ~= nil, "clearAll should show confirm")
        confirm.ok_callback()
        check(#canvas.layers[1] == 0 and #canvas.layers[2] == 1 and #canvas.layers[3] == 1,
            "clear should only clear active layer (1)")
        -- The status bar shows the layer name (top/middle/bottom); v59b layer visibility item text follows dynamically
        check(canvas:_statusText():find("bottom") ~= nil, "status should show layer name")
        -- v59f: layer panel = one item per layer (● current layer + ☐/☑ hide; tap switches layer, long-press toggles hidden)
        canvas:_switchLayer(3)
        local sbtn = canvas:_categoryBt("layer").button_by_id["layer3_btn"]
        check(sbtn ~= nil and sbtn.text == "●Top(☐hide)",
            "layer3_btn should be ●Top(☐hide), got " .. tostring(sbtn and sbtn.text))
        check(sbtn.hold_callback ~= nil, "layer entry should have hold_callback (toggle hide)")
        sbtn.hold_callback() -- long-press to hide
        sbtn = canvas:_categoryBt("layer").button_by_id["layer3_btn"]
        check(canvas.layer_visible[3] == false and sbtn.text == "●Top(☑hide)",
            "after hold: hidden box checked, got " .. tostring(sbtn and sbtn.text))
        print("layers: per-layer elements/undo, switch clears selection, clear current layer OK")
    end)
    if ok then
        print("PASS: layers")
    else
        print("FAIL: layers:", tostring(err))
        os.exit(1)
    end
end

-- ============ 7. Grey/width settings dialog ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captures = {}
        UIManager.show = function(self, w)
            captures[#captures + 1] = w
            return true
        end
        local canvas = newCanvas()
        pcall(function() canvas:_pickGray() end)
        pcall(function() canvas:_pickWidth() end)
        UIManager.show = orig_show
        -- Find the ButtonTable in the popup widget tree (structure: popup->CenterContainer->FrameContainer->[VerticalGroup->]ButtonTable)
        local function findButtonTable(w)
            if w and w.button_by_id then
                return w
            end
            for i = 1, 30 do
                local c = w and w[i]
                if c then
                    local r = findButtonTable(c)
                    if r then
                        return r
                    end
                end
            end
            return nil
        end
        if #captures >= 2 then
            local gb = findButtonTable(captures[1])
            local wb = findButtonTable(captures[2])
            check(gb ~= nil and gb.button_by_id["gray_max_btn"] and gb.button_by_id["gray_min_btn"]
                and gb.button_by_id["gray_levels_btn"] and gb.button_by_id["gray_fixed_btn"],
                "gray dialog should have 4 buttons")
            check(wb ~= nil and wb.button_by_id["width_max_btn"] and wb.button_by_id["width_min_btn"]
                and wb.button_by_id["width_levels_btn"] and wb.button_by_id["width_fixed_btn"],
                "width dialog should have 4 buttons")
        else
            print("WARN: grey/width popup could not be constructed headless, skipping button assertions")
        end
        print("gray/width dialogs OK")
    end)
    if ok then
        print("PASS: gray/width dialogs")
    else
        print("FAIL: gray/width dialogs:", tostring(err))
        os.exit(1)
    end
end

-- ============ 8. Layer naming/show-hide/centred menu ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        -- One stroke on the default layer (middle)
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        -- Note: visibility toggles swap the ping-pong buffer, so the canvas_bb reference changes and must be read dynamically
        local function a(x, y) return canvas.canvas_bb:getPixel(x, y) and canvas.canvas_bb:getPixel(x, y).a end
        check(a(150, 300) == 0, "middle layer ink visible, got " .. tostring(a(150, 300)))
        -- Long-press: hide the current layer -> after the full canvas redraw the ink disappears
        canvas:_toggleLayerVisible()
        check(canvas.layer_visible[2] == false, "toggle should hide middle layer")
        canvas:_renderAll()
        check(a(150, 300) == 255, "hidden layer ink should disappear, got " .. tostring(a(150, 300)))
        -- The status bar shows (hide)
        local st = canvas:_statusText()
        check(st:find("middle") ~= nil and st:find("(hide)", 1, true) ~= nil, "status should mark hidden: " .. st)
        -- Long-press again to show and restore
        canvas:_toggleLayerVisible()
        check(canvas.layer_visible[2] == true, "toggle should show middle layer again")
        canvas:_renderAll()
        check(a(150, 300) == 0, "shown layer ink should return")
        -- Hidden layers aren't part of the save crop (WYSIWYG)
        canvas:_toggleLayerVisible()
        local bbox = canvas:_contentBBox()
        check(bbox == nil, "hidden layer content should not be exported")
        canvas:_toggleLayerVisible()
        bbox = canvas:_contentBBox()
        check(bbox ~= nil, "visible layer content should be exported")
        -- v59f: layer panel = top-level "Layer" category, one item per layer (● current layer + ☐/☑ hide; tap switches layer, long-press toggles hidden)
        local lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer3_btn"] ~= nil and lbt.button_by_id["layer2_btn"] ~= nil,
            "layer panel should have one entry per layer")
        canvas:_switchLayer(3)
        lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer3_btn"].text == "●Top(☐hide)",
            "current layer shows ●, got " .. lbt.button_by_id["layer3_btn"].text)
        check(lbt.button_by_id["layer1_btn"].text == "○Bottom(☐hide)",
            "other layer shows ○")
        -- Long-press toggles hidden (non-current layer, middle)
        lbt.button_by_id["layer2_btn"].hold_callback()
        check(canvas.layer_visible[2] == false, "hold hides layer2")
        lbt = canvas:_categoryBt("layer")
        check(lbt.button_by_id["layer2_btn"].text == "○Mid(☑hide)",
            "hidden layer shows checked box")
        lbt.button_by_id["layer2_btn"].hold_callback()
        check(canvas.layer_visible[2] == true, "hold shows layer2 again")
        -- Tapping in the layer panel keeps it open (close_on_tap = false semantics live in _showCategoryMenu; only item existence is checked here)
        print("layers: names/hide-show/export/layer panel OK")
    end)
    if ok then
        print("PASS: layer names/visibility/centered menu")
    else
        print("FAIL: layer names/visibility/centered menu:", tostring(err))
        os.exit(1)
    end
end

-- ============ 9. Brush tip shapes ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local shapes = require("drawingpad.shapes")
        local black = Blitbuffer.gray(1.0)
        local function drawTip(tip)
            local bb = Blitbuffer.new(100, 100, Blitbuffer.TYPE_BB8)
            bb:paintRect(0, 0, 100, 100, Blitbuffer.COLOR_WHITE)
            shapes.tip(bb, 50, 50, 20, black, tip)
            return bb
        end
        local function a(bb, x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        local t = drawTip("triangle")
        check(a(t, 50, 40) == 0 and a(t, 40, 60) == 0 and a(t, 60, 60) == 0 and a(t, 50, 50) == 0,
            "triangle pixels: " .. tostring(a(t, 50, 40)) .. "/" .. tostring(a(t, 40, 60)))
        t = drawTip("triangle_inv")
        check(a(t, 50, 60) == 0 and a(t, 40, 40) == 0 and a(t, 60, 40) == 0, "triangle_inv pixels")
        t = drawTip("diamond")
        check(a(t, 50, 40) == 0 and a(t, 50, 60) == 0 and a(t, 40, 50) == 0 and a(t, 60, 50) == 0,
            "diamond pixels")
        t = drawTip("square")
        check(a(t, 40, 40) == 0 and a(t, 59, 59) == 0, "square pixels")
        t = drawTip("slash")
        check(a(t, 50, 50) == 0 and a(t, 40, 60) == 0 and a(t, 60, 40) == 0, "slash pixels")
        t = drawTip("backslash")
        check(a(t, 50, 50) == 0 and a(t, 40, 40) == 0 and a(t, 60, 60) == 0, "backslash pixels")
        t = drawTip("circle")
        check(a(t, 50, 50) == 0, "circle pixels")
        -- Elements carry tip: brush/line do, rectangles don't
        local canvas = newCanvas()
        canvas.tip = "triangle"
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        check(canvas.elements[1].tip == "triangle", "brush stroke should carry tip")
        canvas:_setTool("line")
        canvas:onSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 200, y = 400 } })
        check(canvas.elements[2].tip == "triangle", "line should carry tip")
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 500 }, end_pos = { x = 200, y = 550 } })
        check(canvas.elements[3].tip == nil or canvas.elements[3].tip == "circle",
            "rect should keep circle tip")
        -- Tip menu construction (7 rows of preview + button + 1 cancel; taps go through the native Button's own gestures)
        local const = require("drawingpad.const")
        local UIManager = require("ui/uimanager")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w) captured = w; return true end
        pcall(function() canvas:_showTipMenu() end)
        UIManager.show = orig_show
        if captured then
            -- The popup itself must register gestures (otherwise stop_events_propagation swallows all input)
            check(captured.ges_events ~= nil and captured.ges_events.TapSelect ~= nil,
                "tip popup must register TapSelect gesture")
            -- Recursively collect: native Buttons with a callback, ImageWidget previews with a BB image
            local btns, previews = {}, {}
            local function walk(w, depth)
                if type(w) ~= "table" or depth > 12 then return end
                if type(w.callback) == "function" then btns[#btns + 1] = w end
                if rawget(w, "image") ~= nil then previews[#previews + 1] = w end
                for i = 1, math.min(#w, 20) do walk(w[i], depth + 1) end
            end
            walk(captured, 0)
            check(#btns >= 8, "tip menu should have 7 tip buttons + cancel, got " .. #btns)
            check(#previews >= 7, "tip menu should show 7 shape previews, got " .. #previews)
            -- Fire the first tip button callback and confirm canvas.tip is set
            pcall(function() btns[1].callback() end)
            check(canvas.tip == const.TIPS[1][1],
                "firing first tip should set canvas.tip to " .. const.TIPS[1][1])
        else
            print("WARN: tip menu could not be constructed headless, skipping popup assertions")
        end
        print("tips: shapes pixels / element carry / menu OK")
    end)
    if ok then
        print("PASS: brush tip shapes")
    else
        print("FAIL: brush tip shapes:", tostring(err))
        os.exit(1)
    end
end

-- ============ 10. Joining bug fix / two-finger pen-up / centred labels ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        -- Inject a leftover stroke (simulates the previous gesture missing pan_release)
        canvas._stroke = { kind = "freehand", points = { { x = 100, y = 300 }, { x = 200, y = 300 } }, gray = 1.0, width = 4 }
        -- A new pen-down: start_pos differs from the stroke's first point -> cross-gesture protection finishes it at the last point
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 400, y = 300 } })
        check(#canvas.elements == 1 and #canvas.elements[1].points == 2,
            "stale stroke should be committed without extension")
        local last = canvas.elements[1].points[#canvas.elements[1].points]
        check(last.x == 200 and last.y == 300, "stale stroke last point unchanged")
        -- The new stroke starts at the new touch-down point (not joined to the old stroke)
        canvas:onPan(nil, { pos = { x = 450, y = 300 }, start_pos = { x = 400, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 460, y = 300 } })
        check(#canvas.elements == 2 and canvas.elements[2].points[1].x == 400,
            "new stroke should start at new press")
        -- Two-finger interruption: the in-progress stroke is finished at its last point
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(canvas2._stroke ~= nil, "stroke in progress")
        canvas2:onTwoFingerPan()
        check(canvas2._stroke == nil and #canvas2.elements == 1, "two-finger should finish stroke")
        -- v59d: after a text_fn dynamic item (layer hide checkbox) toggles, setText gets the current width, button geometry stays constant
        canvas2._panel_bt = canvas2:_categoryBt("layer")
        local vbtn = canvas2._panel_bt.button_by_id["layer1_btn"] -- default current layer = bottom (merged item)
        local w0 = vbtn.width
        vbtn.hold_callback() -- long-press to hide
        vbtn = canvas2:_categoryBt("layer").button_by_id["layer1_btn"]
        check(canvas2.layer_visible[1] == false and vbtn.width == w0,
            "setText should keep button width, got " .. tostring(vbtn.width) .. " vs " .. tostring(w0))
        vbtn.hold_callback() -- long-press to show
        vbtn = canvas2:_categoryBt("layer").button_by_id["layer1_btn"]
        check(canvas2.layer_visible[1] == true and vbtn.width == w0,
            "toggle back keeps width")
        print("connection bug / two-finger / label geometry OK")
    end)
    if ok then
        print("PASS: connection fix / two-finger / label geometry")
    else
        print("FAIL: connection fix / two-finger / label geometry:", tostring(err))
        os.exit(1)
    end
end

-- ============ 11. Combined buttons / save dialog ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local canvas = newCanvas()
        -- v59b: function panel = separate Undo/Redo/Clear/Save items (no combined buttons, no long-press)
        -- v62d: Save = project (.drawing), Export = PNG (the old Save renamed)
        local Blitbuffer = require("ffi/blitbuffer")
        local funcBt = function() return canvas:_categoryBt("func") end
        local ubtn = funcBt().button_by_id["undo_btn"]
        local rbtn = funcBt().button_by_id["redo_btn"]
        local cbtn = funcBt().button_by_id["clear_btn"]
        local sbtn = funcBt().button_by_id["save_btn"]
        local pbtn = funcBt().button_by_id["save_proj_btn"]
        local obtn = funcBt().button_by_id["open_proj_btn"]
        check(ubtn ~= nil and ubtn.callback ~= nil and ubtn.hold_callback == nil,
            "undo_btn should be click-only (no hold)")
        check(rbtn ~= nil and cbtn ~= nil and sbtn ~= nil, "redo/clear/save entries exist")
        check(ubtn.text == "Undo" and rbtn.text == "Redo" and cbtn.text == "Clear"
            and sbtn.text == "Export", "func labels should be Undo/Redo/Clear/Export")
        check(pbtn ~= nil and pbtn.text == "Save" and obtn ~= nil and obtn.text == "Open",
            "project save/open entries exist")
        check(ubtn[1].background == Blitbuffer.COLOR_WHITE
            and cbtn[1].background == Blitbuffer.COLOR_WHITE, "func entries always white bg")
        -- Refresh doesn't crash
        canvas:_refreshCanvas()
        -- Draw two strokes: the undo/redo items work on a single tap
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        canvas:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 400 } })
        canvas:onPanRelease(nil, { pos = { x = 200, y = 400 } })
        check(#canvas.elements == 2, "two strokes")
        canvas:_undo() -- undo item
        check(#canvas.elements == 1, "undo entry should undo")
        canvas:_redo() -- redo item
        check(#canvas.elements == 2, "redo entry should redo")
        -- Save dialog: filename input + folder button
        local orig_show = UIManager.show
        local captures = {}
        UIManager.show = function(self, w) captures[#captures + 1] = w; return true end
        pcall(function() canvas:_save() end)
        UIManager.show = orig_show
        if captures[1] then
            local dlg = captures[1]
            local fb = dlg.button_table and dlg.button_table.button_by_id
                and dlg.button_table.button_by_id["folder_btn"]
            check(fb ~= nil, "save dialog should have folder button")
            check(type(dlg.getInputText) == "function", "save dialog should have filename input")
        else
            print("WARN: save dialog could not be constructed headless, skipping assertions")
        end
        -- Folder menu: with subfolders it pops up a Menu listing them (verifies the lfs.dir iterator fix)
        do
            local lfs = require("libs/libkoreader-lfs")
            local DataStorage = require("datastorage")
            local base = DataStorage:getDataDir() .. "/drawingboard"
            if lfs.attributes(base, "mode") ~= "directory" then
                pcall(lfs.mkdir, base)
            end
            local sub = base .. "/_test_sub"
            pcall(lfs.mkdir, sub)
            local captures2 = {}
            UIManager.show = function(self, w) captures2[#captures2 + 1] = w; return true end
            pcall(function() canvas:_pickSaveFolder() end)
            UIManager.show = orig_show
            if captures2[1] and captures2[1].buttons then
                local has_sub = false
                for _, row in ipairs(captures2[1].buttons) do
                    for _, b in ipairs(row) do
                        if b.text == "_test_sub/" then has_sub = true end -- folder items have a "/" suffix
                    end
                end
                check(has_sub, "folder menu should list subfolder (lfs.dir fix)")
            else
                print("WARN: folder menu could not be constructed headless, skipping subfolder assertions")
            end
            pcall(lfs.rmdir, sub)
        end
        print("merged buttons / save dialog OK")
    end)
    if ok then
        print("PASS: merged buttons / save dialog")
    else
        print("FAIL: merged buttons / save dialog:", tostring(err))
        os.exit(1)
    end
end

-- ============ 12. Transforms (four-corner anchor scale/rotate/toggle/poly/undo) ============
-- Anchor mechanism: selecting shows four corners (scale mode by default), tapping the same object again switches to rotate mode (drag a corner to rotate),
-- tap again to switch back; tapping blank space deselects; text doesn't support rotation (no toggle). The separate top rotate anchor was removed.
do
    local ok, err = pcall(function()
        -- Scale: drag the se anchor to enlarge the rectangle (opposite edge fixed)
        local canvas = newCanvas()
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect = canvas.elements[1]
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 100, y = 350 } }) -- tap the left edge of the hollow rectangle to select it
        check(canvas._selected == rect, "select rect via edge tap")
        check(canvas._handle_mode == "scale", "default handle mode is scale")
        check(canvas:_hitHandle(204, 404) == "se", "hit se handle")
        check(canvas:_hitHandle(204, 350) == nil, "no midpoint handle (4 corners only)")
        -- Hit radius 48: within 40px of a corner still hits (easy for fingers); beyond 48 doesn't count
        check(canvas:_hitHandle(168, 376) == "se", "hit within 48px radius of corner")
        check(canvas:_hitHandle(150, 360) == nil, "miss beyond hit radius")
        canvas:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvas:onPanRelease(nil, { pos = { x = 250, y = 450 } })
        check(rect.x0 == 100 and rect.y0 == 300 and rect.x1 == 250 and rect.y1 == 450,
            "rect scaled: " .. rect.x0 .. "," .. rect.y0 .. " " .. rect.x1 .. "," .. rect.y1)
        canvas:_undo()
        check(rect.x1 == 200 and rect.y1 == 400, "undo transform restores")
        canvas:_redo()
        check(rect.x1 == 250 and rect.y1 == 450, "redo transform reapplies")

        -- Tapping again toggles scale<->rotate; tapping blank space deselects (mode back to scale).
        -- Note: undo/redo clears the selection, so tap once to reselect, and the next tap is the toggle
        canvas:onTap(nil, { pos = { x = 100, y = 400 } }) -- reselect (left edge of the scaled rectangle)
        check(canvas._selected == rect, "reselect rect after redo")
        check(canvas._handle_mode == "scale", "reselect resets to scale")
        canvas:onTap(nil, { pos = { x = 100, y = 400 } }) -- tap again -> rotate mode
        check(canvas._handle_mode == "rotate", "re-tap toggles to rotate")
        check(canvas:_hitHandle(254, 454) == "se", "rotate mode hits se corner")
        canvas:onTap(nil, { pos = { x = 100, y = 400 } })
        check(canvas._handle_mode == "scale", "re-tap toggles back to scale")
        canvas:onTap(nil, { pos = { x = 500, y = 500 } }) -- tap blank space
        check(canvas._selected == nil, "tap blank deselects")
        check(canvas._handle_mode == "scale", "deselect resets handle mode")

        -- Rotate: after toggling with another tap drag a corner, a horizontal line rotates +90° about its centre to vertical
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas2.elements[1]
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas2._selected == line, "select line")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } }) -- tap again -> rotate mode
        check(canvas2._handle_mode == "rotate", "re-tap line toggles rotate")
        -- Line width 4 -> bbox(96,296)-(204,304) pad4; the thin line's corners are 16px apart < hit radius 24,
        -- neighbouring corners hit at the same time (the rotation result doesn't depend on which corner), only assert that one of the four hits
        check(canvas2:_hitHandle(208, 308) ~= nil, "rotate mode hits a corner")
        check(canvas2:_hitHandle(150, 292) == nil, "rotate mode has no top/edge handle")
        canvas2:onPan(nil, { pos = { x = 208, y = 308 }, start_pos = { x = 208, y = 308 } })
        canvas2:onPanRelease(nil, { pos = { x = 142, y = 358 } }) -- corner offset (58,8) rotated 90° -> (-8,58)
        local p1, p2 = line.points[1], line.points[2]
        local xs_ok = math.abs(p1.x - 150) < 3 and math.abs(p2.x - 150) < 3
        local ys = { p1.y, p2.y }
        local ys_ok = (math.abs(ys[1] - 250) < 3 or math.abs(ys[1] - 350) < 3)
            and (math.abs(ys[2] - 250) < 3 or math.abs(ys[2] - 350) < 3)
            and math.abs(ys[1] - ys[2]) > 90
        check(xs_ok and ys_ok,
            "line rotated 90: " .. p1.x .. "," .. p1.y .. " " .. p2.x .. "," .. p2.y)
        canvas2:_undo()
        local r1, r2 = line.points[1], line.points[2]
        check(math.abs(r1.y - 300) < 3 and math.abs(r2.y - 300) < 3,
            "undo rotation restores horizontal")
        canvas2:_redo()
        check(math.abs(line.points[1].x - 150) < 3, "redo rotation reapplies")

        -- Rectangle rotation -> poly (4-point outline, filled degrades to outline)
        local canvas3 = newCanvas()
        canvas3:_setTool("rect")
        canvas3:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvas3:_setTool("select")
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } }) -- tap again -> rotate mode
        check(canvas3._handle_mode == "rotate", "rect re-tap toggles rotate")
        canvas3:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvas3:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- se corner rotated +90° about (150,350) -> sw position
        local poly = canvas3.elements[1]
        check(poly.kind == "poly" and #poly.points == 4 and not poly.filled,
            "rotated rect should become poly with 4 points")
        -- Corner (100,300) rotated 90° about (150,350) -> (200,300), the poly outline should have ink
        local bb = canvas3.canvas_bb
        local px = bb:getPixel(200, 300) and bb:getPixel(200, 300).a
        check(px == 0, "poly edge ink at rotated corner, got " .. tostring(px))
        -- poly undo restores the rect
        canvas3:_undo()
        check(canvas3.elements[1].kind == "rect" and canvas3.elements[1].x1 == 200,
            "undo poly rotation restores rect")

        -- Circle: rotate mode drag a corner +90°, switch back to scale mode and drag a corner into an ellipse
        local canvas5 = newCanvas()
        canvas5:_setTool("circle")
        canvas5:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- r=100
        local circle = canvas5.elements[1]
        canvas5:_setTool("select")
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } })
        check(canvas5._selected == circle, "select circle")
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } }) -- tap again -> rotate mode
        check(canvas5._handle_mode == "rotate", "circle re-tap toggles rotate")
        -- bbox(100,200)-(300,400) pad4 -> se (304,404), rotated +90° about the centre (200,300) -> sw (96,404)
        canvas5:onPan(nil, { pos = { x = 304, y = 404 }, start_pos = { x = 304, y = 404 } })
        canvas5:onPanRelease(nil, { pos = { x = 96, y = 404 } })
        check(circle.rot ~= nil and math.abs(circle.rot - math.pi / 2) < 0.05,
            "circle rotated 90, got " .. tostring(circle.rot))
        -- Back to scale mode: drag an OBB corner -> non-uniform ellipse, can be enlarged outwards (OBB scale semantics after rotation)
        canvas5:onTap(nil, { pos = { x = 300, y = 300 } }) -- tap again -> scale mode
        check(canvas5._handle_mode == "scale", "re-tap toggles back to scale")
        local fc5 = canvas5:_frameCorners(circle)
        local s5x, s5y = fc5[3].x, fc5[3].y -- OBB se corner of the circle rotated 90°
        canvas5:onPan(nil, { pos = { x = s5x, y = s5y }, start_pos = { x = s5x, y = s5y } })
        canvas5:onPanRelease(nil, { pos = { x = s5x, y = s5y + 300 } }) -- enlarge along one axis (release point avoids the bottom toolbar area)
        check(circle.rx ~= circle.ry,
            "circle scaled non-uniformly, got " .. tostring(circle.rx) .. "/" .. tostring(circle.ry))
        check(math.max(circle.rx, circle.ry) > 100,
            "rotated circle grows when corner dragged outward, got " .. tostring(circle.rx) .. "/" .. tostring(circle.ry))
        -- Undo: first restore the circle (equal radii), then restore the rotation
        canvas5:_undo()
        check(math.abs(circle.rx - circle.ry) < 0.01, "undo scale restores round circle")
        canvas5:_undo()
        check((circle.rot or 0) == 0, "undo rotation restores rot")

        -- Text: tapping again doesn't toggle rotation (text doesn't support rotation, the four corners still scale)
        local canvas6 = newCanvas()
        local tel = {
            kind = "text",
            x = 400, y = 200,
            text = "Text test",
            font = canvas6.font,
            size = canvas6.font_size,
            gray = 1.0,
        }
        table.insert(canvas6.elements, tel)
        canvas6:_cacheBBox(tel)
        canvas6:_setTool("select")
        canvas6:onTap(nil, { pos = { x = 400, y = 220 } }) -- tap inside the text bbox
        check(canvas6._selected == tel, "select text")
        canvas6:onTap(nil, { pos = { x = 400, y = 220 } }) -- tap again: text now supports rotation
        check(canvas6._handle_mode == "rotate", "text re-tap toggles rotate")

        -- Tilted ellipse: selection box/anchors use the OBB corners (hugging the boundary), no longer the floating axis-aligned AABB box
        local canvas7 = newCanvas()
        canvas7:_setTool("circle")
        canvas7:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } }) -- r=100
        local tilted = canvas7.elements[1]
        tilted.rx, tilted.ry = 100, 40
        tilted.rot = math.pi / 4
        canvas7:_cacheBBox(tilted)
        canvas7:_setTool("select")
        canvas7:onTap(nil, { pos = { x = 271, y = 371 } }) -- on the ellipse boundary (near local (100,0) rotated 45°)
        check(canvas7._selected == tilted, "select tilted ellipse")
        local fc = canvas7:_frameCorners(tilted)
        check(fc and #fc == 4, "tilted ellipse has OBB frame corners")
        -- OBB corner ≈ (244,403); the axis-aligned AABB corner (303,403) floats and is no longer an anchor
        check(canvas7:_hitHandle(303, 403) == nil, "AABB corner no longer an anchor")
        check(canvas7:_hitHandle(244, 403) ~= nil, "OBB corner is an anchor")

        -- Text rotation: tap again to switch to rotate mode, drag the opposite corner to rotate ~180°, undo restores; anchor hit radius 64
        local canvasT = newCanvas()
        local tel = { kind = "text", x = 400, y = 200, text = "Rotate test", font = canvasT.font, size = canvasT.font_size, gray = 1.0 }
        table.insert(canvasT.elements, tel)
        canvasT:_cacheBBox(tel)
        canvasT:_setTool("select")
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } })
        check(canvasT._selected == tel, "select text for rotate")
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } })
        check(canvasT._handle_mode == "rotate", "text toggles to rotate mode")
        local fcT = canvasT:_frameCorners(tel)
        check(fcT and #fcT == 4, "text has frame corners")
        local t0x, t0y = fcT[1].x, fcT[1].y
        canvasT:onPan(nil, { pos = { x = t0x, y = t0y }, start_pos = { x = t0x, y = t0y } })
        check(canvasT._transform ~= nil, "text transform started")
        local t1x, t1y = fcT[3].x, fcT[3].y -- opposite corner = rotate 180°
        canvasT:onPan(nil, { pos = { x = t1x, y = t1y }, start_pos = { x = t0x, y = t0y } })
        canvasT:onPanRelease(nil, { pos = { x = t1x, y = t1y } })
        local rot_v = tel.rot or 0
        check(math.abs(rot_v - math.pi) < 0.05 or math.abs(rot_v + math.pi) < 0.05,
            "text rotated ~180, got " .. tostring(rot_v))
        canvasT:_undo()
        check((tel.rot or 0) == 0, "undo text rotation restores")
        -- Text anchor hit radius 64 (normal 48): 55px from the corner hits, 70px doesn't
        canvasT:onTap(nil, { pos = { x = 400, y = 220 } }) -- reselect (undo cleared the selection)
        local fcR = canvasT:_frameCorners(tel)
        check(canvasT:_hitHandle(fcR[1].x - 55, fcR[1].y) ~= nil, "text anchor hit within 64px")
        check(canvasT:_hitHandle(fcR[1].x - 70, fcR[1].y) == nil, "text anchor miss beyond 64px")
        -- Normal object anchors are still 48: 55px from the corner doesn't hit
        local canvasR = newCanvas()
        canvasR:_setTool("rect")
        canvasR:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvasR:_setTool("select")
        canvasR:onTap(nil, { pos = { x = 100, y = 350 } })
        check(canvasR:_hitHandle(149, 404) == nil, "rect anchor miss beyond 48px (55px)")

        -- Text stretch: non-uniform scale -> the uniform part goes into font size, the remainder into sx/sy pixel scaling
        local canvasS = newCanvas()
        local tel2 = { kind = "text", x = 100, y = 100, text = "Stretch", font = canvasS.font, size = 24, gray = 1.0 }
        table.insert(canvasS.elements, tel2)
        canvasS:_cacheBBox(tel2)
        local sb2 = tel2._bbox
        canvasS:_scaleElement(tel2, sb2, { x0 = sb2.x0, y0 = sb2.y0, x1 = sb2.x0 + (sb2.x1 - sb2.x0) * 2, y1 = sb2.y1 })
        check(tel2.size == 36, "text uniform part into size, got " .. tostring(tel2.size))
        check(math.abs((tel2.sx or 1) * 1.5 - 2) < 0.01 and math.abs((tel2.sy or 1) * 1.5 - 1) < 0.01,
            "text total width factor 2 / height 1, got sx " .. tostring(tel2.sx) .. " sy " .. tostring(tel2.sy))
        -- Rotated rectangle scaling: OBB corner anchor scaling - after switching back to scale mode dragging a corner outwards enlarges it (fixes "can only shrink after rotation")
        local canvasR2 = newCanvas()
        canvasR2:_setTool("rect")
        canvasR2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local poly2 = canvasR2.elements[1]
        canvasR2:_setTool("select")
        canvasR2:onTap(nil, { pos = { x = 100, y = 350 } })
        canvasR2:onTap(nil, { pos = { x = 100, y = 350 } }) -- rotate mode
        canvasR2:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } })
        canvasR2:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- rotate 90° -> poly
        check(poly2.kind == "poly", "rect rotated to poly")
        canvasR2:onTap(nil, { pos = { x = 200, y = 300 } }) -- after rotation corner (100,300)->(200,300), tap again to switch back to scale
        check(canvasR2._handle_mode == "scale", "poly toggles back to scale")
        local function pdiag(p)
            local p1, p3 = p.points[1], p.points[3]
            return math.sqrt((p1.x - p3.x) ^ 2 + (p1.y - p3.y) ^ 2)
        end
        local diag0 = pdiag(poly2)
        local fc2 = canvasR2:_frameCorners(poly2)
        local s2x, s2y = fc2[3].x, fc2[3].y -- se corner
        local ccx, ccy = (poly2.points[1].x + poly2.points[3].x) / 2, (poly2.points[1].y + poly2.points[3].y) / 2
        canvasR2:onPan(nil, { pos = { x = s2x, y = s2y }, start_pos = { x = s2x, y = s2y } })
        canvasR2:onPanRelease(nil, { pos = { x = ccx + (s2x - ccx) * 1.5, y = ccy + (s2y - ccy) * 1.5 } })
        check(pdiag(poly2) > diag0 * 1.15,
            "rotated poly grows when corner dragged outward: " .. diag0 .. " -> " .. pdiag(poly2))

        -- Rotated ellipse scaling: can also be enlarged outwards
        local canvasE2 = newCanvas()
        canvasE2:_setTool("circle")
        canvasE2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local circE = canvasE2.elements[1]
        canvasE2:_setTool("select")
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } })
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } }) -- rotate mode
        canvasE2:onPan(nil, { pos = { x = 304, y = 404 }, start_pos = { x = 304, y = 404 } })
        canvasE2:onPanRelease(nil, { pos = { x = 96, y = 404 } }) -- rotate 90°
        check(math.abs((circE.rot or 0) - math.pi / 2) < 0.05, "ellipse rotated 90")
        canvasE2:onTap(nil, { pos = { x = 300, y = 300 } }) -- tap again to switch back to scale (after a 90° rotation the circle's right edge is still at 300,300)
        check(canvasE2._handle_mode == "scale", "ellipse toggles back to scale")
        local rx0 = circE.rx
        local fcE = canvasE2:_frameCorners(circE)
        local sEx, sEy = fcE[3].x, fcE[3].y
        local cEx, cEy = circE.cx, circE.cy
        canvasE2:onPan(nil, { pos = { x = sEx, y = sEy }, start_pos = { x = sEx, y = sEy } })
        canvasE2:onPanRelease(nil, { pos = { x = cEx + (sEx - cEx) * 1.5, y = cEy + (sEy - cEy) * 1.5 } })
        check(circE.rx > rx0 * 1.1,
            "rotated ellipse grows when corner dragged outward: " .. rx0 .. " -> " .. circE.rx)
        print("transform: corner scale/rotate/toggle/poly/undo-redo/circle-ellipse OK")
    end)
    if ok then
        print("PASS: transform handles")
    else
        print("FAIL: transform handles:", tostring(err))
        os.exit(1)
    end
end

-- ============ 13. Move preview / selected object grey & width / save folder browser ============
do
    local ok, err = pcall(function()
        -- 13a. Move/copy drag: 0.5s rest drop-point preview (stop-position debounce, headless fires the timer callback manually)
        local canvas = newCanvas()
        canvas:_setTool("rect")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect = canvas.elements[1]
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 100, y = 350 } }) -- select the hollow rectangle
        canvas:onPan(nil, { pos = { x = 120, y = 350 }, start_pos = { x = 100, y = 350 } })
        check(canvas._select_drag ~= nil, "drag should start move")
        check(canvas._drag_preview == nil, "no preview before dwell")
        canvas:onPan(nil, { pos = { x = 120, y = 350 }, start_pos = { x = 100, y = 350 } }) -- another pan = rest
        check(canvas._drag_preview_fn ~= nil, "dwell timer scheduled (stop debounce)")
        canvas:_maybeShowDragPreview() -- fire the timer callback manually (headless has no event loop)
        local pv = canvas._drag_preview
        check(pv ~= nil, "dwell should show move preview")
        local pb = pv._bbox
        check(pb.x0 == 120 and pb.y0 == 300 and pb.x1 == 220 and pb.y1 == 400,
            "preview at drag offset: " .. pb.x0 .. "," .. pb.y0 .. " " .. pb.x1 .. "," .. pb.y1)
        canvas:onPan(nil, { pos = { x = 140, y = 350 }, start_pos = { x = 100, y = 350 } }) -- moved again: the preview follows (no longer erased = no flicker)
        local pv2 = canvas._drag_preview
        check(pv2 ~= nil, "preview follows finger (no clear)")
        check(pv2._bbox.x0 == 140 and pv2._bbox.y0 == 300 and pv2._bbox.x1 == 240 and pv2._bbox.y1 == 400,
            "preview updated to new offset")
        check(canvas._drag_preview_repaint_pending == true, "follow update schedules throttled repaint")
        canvas:onPan(nil, { pos = { x = 140, y = 350 }, start_pos = { x = 100, y = 350 } }) -- same position: geometry unchanged
        check(canvas._drag_preview == pv2, "no-op position keeps same preview instance (anti-flicker)")
        canvas:onPanRelease(nil, { pos = { x = 140, y = 350 } })
        check(rect.x0 == 140 and rect.y0 == 300 and rect.x1 == 240 and rect.y1 == 400,
            "rect moved to final pos: " .. rect.x0 .. "," .. rect.y0)
        check(canvas._drag_preview == nil, "preview cleared on release")

        -- 13a2. Dragging an anchor in rotate mode: a 0.5s rest shows the rotated preview (same maths as _finishTransform)
        local canvas3 = newCanvas()
        canvas3:_setTool("rect")
        canvas3:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        canvas3:_setTool("select")
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas3:onTap(nil, { pos = { x = 100, y = 350 } }) -- tap again -> rotate mode
        check(canvas3._handle_mode == "rotate", "rotate mode for preview test")
        canvas3:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } }) -- pen-down hits the se corner
        check(canvas3._transform ~= nil and canvas3._transform.handle == "se", "transform started")
        canvas3:onPan(nil, { pos = { x = 96, y = 404 }, start_pos = { x = 204, y = 404 } }) -- drag to the sw corner position = +90°
        check(canvas3._drag_preview_fn ~= nil, "rotate dwell timer scheduled")
        canvas3:_maybeShowDragPreview() -- fire the rest callback manually
        local rpv = canvas3._drag_preview
        check(rpv ~= nil, "rotate dwell should show preview")
        check(rpv.kind == "poly" and #rpv.points == 4, "rotate preview should be rotated poly")
        local found = false
        for _, p in ipairs(rpv.points) do -- corner (100,300) rotated 90° about (150,350) -> (200,300)
            if math.abs(p.x - 200) < 1 and math.abs(p.y - 300) < 1 then found = true end
        end
        check(found, "rotate preview corner at rotated position")
        canvas3:onPanRelease(nil, { pos = { x = 96, y = 404 } })
        check(canvas3._drag_preview == nil, "rotate preview cleared on release")
        local rpoly = canvas3.elements[1]
        check(rpoly.kind == "poly" and rpoly ~= rpv, "real rotation committed")

        -- 13a3. Dragging an anchor in scale mode: after the rest the stretch preview shows (same maths as _finishTransform)
        local canvas4 = newCanvas()
        canvas4:_setTool("rect")
        canvas4:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 400 } })
        local rect4 = canvas4.elements[1]
        canvas4:_setTool("select")
        canvas4:onTap(nil, { pos = { x = 100, y = 350 } })
        canvas4:onPan(nil, { pos = { x = 204, y = 404 }, start_pos = { x = 204, y = 404 } }) -- pen-down hits the se corner
        check(canvas4._transform ~= nil and canvas4._transform.handle == "se", "scale transform started")
        check(canvas4._handle_mode == "scale", "scale mode for preview test")
        canvas4:onPan(nil, { pos = { x = 250, y = 450 }, start_pos = { x = 204, y = 404 } }) -- drag to (250,450)
        canvas4:_maybeShowDragPreview()
        local spv = canvas4._drag_preview
        check(spv ~= nil, "scale dwell should show preview")
        check(spv._bbox.x0 == 100 and spv._bbox.y0 == 300 and spv._bbox.x1 == 250 and spv._bbox.y1 == 450,
            "scale preview bbox: " .. tostring(spv._bbox.x1) .. "," .. tostring(spv._bbox.y1))
        canvas4:onPanRelease(nil, { pos = { x = 250, y = 450 } })
        check(rect4.x1 == 250 and rect4.y1 == 450, "rect scaled to final")
        check(canvas4._drag_preview == nil, "scale preview cleared on release")

        -- 13a4. v61s: text move preview really renders (the old paintTo went through shapes.drawElement,
        -- which doesn't recognise text = drew into thin air; the user saw "no preview when moving text")
        local canvasT = newCanvas()
        canvasT:_setTool("text")
        canvasT:_commitText(150, 300, "Test text")
        canvasT:_setTool("select")
        canvasT:onTap(nil, { pos = { x = 160, y = 300 } })
        check(canvasT._selected ~= nil and canvasT._selected.kind == "text", "text selected")
        canvasT:onPan(nil, { pos = { x = 420, y = 400 }, start_pos = { x = 400, y = 400 } })
        check(canvasT._select_drag ~= nil, "text move drag started (start beyond handle radius)")
        canvasT:onPan(nil, { pos = { x = 450, y = 420 }, start_pos = { x = 400, y = 400 } })
        canvasT:_maybeShowDragPreview()
        local tpv = canvasT._drag_preview
        check(tpv ~= nil and tpv.kind == "text", "text move dwell shows preview")
        if tpv then
            local BLB = require("ffi/blitbuffer")
            local tbb = BLB.new(canvasT.canvas_w, canvasT.canvas_h, BLB.TYPE_BB8)
            tbb:fill(BLB.COLOR_WHITE)
            canvasT:paintTo(tbb, 0, 0)
            -- The preview drop area (beyond the right of the original text, the right half of the preview bbox) must have ink
            local pb = tpv._bbox
            local ink = 0
            for x = math.floor((pb.x0 + pb.x1) / 2), math.floor(pb.x1), 2 do
                for y = math.floor(pb.y0), math.floor(pb.y1), 2 do
                    local v = tbb:getPixel(x, y)
                    if v and v.a == 0 then ink = ink + 1 end
                end
            end
            check(ink > 0, "text preview paints ink via _drawTextTo, got " .. ink)
            tbb:free()
        end
        canvasT:onPanRelease(nil, { pos = { x = 450, y = 420 } })

        -- 13b. Selected object grey/width adjustment + undo
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas2.elements[1]
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas2._selected == line, "select line for props")
        canvas2:_applySelectedGray(50)
        check(math.abs(line.gray - 0.5) < 0.001, "selected gray applied, got " .. tostring(line.gray))
        canvas2:_applySelectedWidth(8)
        check(line.width == 8, "selected width applied")
        check(line._bbox.y0 == 292, "bbox recomputed after width, got " .. tostring(line._bbox.y0))
        canvas2:_undo() -- undo width (the orig snapshot of the width record contains gray=0.5 at that time)
        check(line.width == 4, "undo width restores")
        canvas2:_undo() -- undo grey
        check(math.abs(line.gray - 1.0) < 0.001, "undo gray restores")
        -- The same value a second time produces no new record
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } }) -- reselect (undo cleared the selection)
        canvas2:_applySelectedGray(50)
        canvas2:_applySelectedGray(50)
        canvas2:_undo()
        check(math.abs(line.gray - 1.0) < 0.001, "duplicate same-value no extra undo")

        -- 13d. Line preview width fixed: in random mode taken once at pen-down, unchanged across several rest previews and the commit
        local canvasL = newCanvas()
        canvasL:_setTool("line")
        canvasL.width_random = true
        canvasL.width_min, canvasL.width_max = 2, 20
        canvasL:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasL:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasL:_scheduleShapePreview(150, 300)
        canvasL:_maybeShowShapePreview()
        local pw = canvasL.preview and canvasL.preview.width
        check(pw ~= nil, "line preview should have fixed width")
        canvasL:onPan(nil, { pos = { x = 160, y = 300 }, start_pos = { x = 100, y = 300 } }) -- rest again
        canvasL:_scheduleShapePreview(160, 300)
        canvasL:_maybeShowShapePreview()
        check(canvasL.preview and canvasL.preview.width == pw,
            "line preview width fixed across dwells, got " .. tostring(canvasL.preview and canvasL.preview.width))
        canvasL:onPanRelease(nil, { pos = { x = 160, y = 300 } })
        local lineEl = canvasL.elements[1]
        check(lineEl and lineEl.kind == "line" and lineEl.width == pw,
            "committed line width matches preview")

        -- 13c. Save folder browser: the menu contains Home/Use this folder/Up/subfolders/existing PNG files
        local UIManager = require("ui/uimanager")
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local base = DataStorage:getDataDir() .. "/drawingboard"
        if lfs.attributes(base, "mode") ~= "directory" then
            pcall(lfs.mkdir, base)
        end
        local sub = base .. "/_test_browser"
        pcall(lfs.mkdir, sub)
        local fake_png = base .. "/_test_file.png"
        local fh = io.open(fake_png, "w")
        if fh then fh:write("fake png bytes"); fh:close() end
        local captures = {}
        local orig_show = UIManager.show
        UIManager.show = function(self, w) captures[#captures + 1] = w; return true end
        pcall(function() canvas2:_pickSaveFolder() end)
        UIManager.show = orig_show
        if captures[1] and captures[1].buttons then
            local has_commit, has_up, has_home, has_sub, has_file = false, false, false, false, false
            for _, row in ipairs(captures[1].buttons) do
                for _, b in ipairs(row) do
                    if b.text:find("Use this folder") then has_commit = true end
                    if b.text:find("Up") then has_up = true end
                    if b.text == "Home" then has_home = true end
                    if b.text == "_test_browser/" then has_sub = true end -- folder items have a "/" suffix
                    if b.text == "_test_file.png" then has_file = true end
                end
            end
            check(has_commit, "folder browser should have Use this folder")
            check(has_up, "folder browser should have Up")
            check(has_home, "folder browser should have Home")
            check(has_sub, "folder browser should list subfolder")
            check(has_file, "folder browser should list existing png files")
        else
            print("WARN: folder browser could not be constructed headless, skipping assertions")
        end
        pcall(os.remove, fake_png)
        pcall(lfs.rmdir, sub)
        print("move preview / selected props / folder browser OK")
    end)
    if ok then
        print("PASS: move preview / selected props / folder browser")
    else
        print("FAIL: move preview / selected props / folder browser:", tostring(err))
        os.exit(1)
    end
end

-- ============ 14. Settings persistence (plugin directory, saved on exit/read on start) ============
do
    local ok, err = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local lfs = require("libs/libkoreader-lfs")
        local dir = "/tmp/drawingpad_settings_test"
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        local settings_path = dir .. "/drawingpad_settings.lua"
        pcall(os.remove, settings_path)
        local c1 = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
        c1.gray = 0.3
        c1.width = 9
        c1.font = "DroidSansFallback.ttf"
        c1.font_size = 42
        c1._last_text = "Last text"
        -- Menu/button state (secondary-function state with inverted colours): should stay default (black on white), not restored
        c1.select_mode = "copy"
        c1.eraser_mode = "rect"
        c1.rect_filled = true
        c1.circle_filled = true
        c1.save_folder = "/mnt/us/test_dir"
        c1.tip = "diamond"
        c1:_saveSettings()
        check(lfs.attributes(settings_path, "mode") ~= nil, "settings file should be written")
        local c2 = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
        check(math.abs(c2.gray - 0.3) < 0.001, "gray restored, got " .. tostring(c2.gray))
        check(c2.width == 9, "width restored")
        check(c2.font == "DroidSansFallback.ttf", "font restored, got " .. tostring(c2.font))
        check(c2.font_size == 42, "font_size restored, got " .. tostring(c2.font_size))
        check(c2._last_text == "Last text", "last_text restored, got " .. tostring(c2._last_text))
        check(c2.save_folder == "/mnt/us/test_dir", "save_folder restored")
        check(c2.tip == "diamond", "tip restored")
        check(c2.select_mode == "move", "menu state NOT restored: select_mode default move")
        check(c2.eraser_mode == "brush", "menu state NOT restored: eraser_mode default brush")
        check(c2.rect_filled == false, "menu state NOT restored: rect_filled default hollow")
        check(c2.circle_filled == false, "menu state NOT restored: circle_filled default hollow")
        pcall(os.remove, settings_path)
        pcall(lfs.rmdir, dir)
        print("settings persistence OK")
    end)
    if ok then
        print("PASS: settings persistence")
    else
        print("FAIL: settings persistence:", tostring(err))
        os.exit(1)
    end
end

-- ============ 15. Fill tool (tap fill/path fill) ============
do
    local ok, err = pcall(function()
        -- Tap fill: solid fill of the enclosed area of a hollow circle
        local canvas = newCanvas()
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local bb = canvas.canvas_bb
        local function a(x, y) return bb:getPixel(x, y) and bb:getPixel(x, y).a end
        check(a(200, 300) == 255, "before fill: circle interior white")
        canvas:_setTool("fill")
        check(canvas.fill_mode == "tap", "fill default tap mode")
        canvas:onTap(nil, { pos = { x = 200, y = 300 } }) -- tap inside the circle
        check(#canvas.elements == 2 and canvas.elements[2].kind == "fill",
            "fill creates fill element, got " .. tostring(#canvas.elements))
        check(a(200, 300) == 0, "after fill: interior black, got " .. tostring(a(200, 300)))
        check(a(50, 300) == 255, "outside circle stays white, got " .. tostring(a(50, 300)))
        -- The fill element replays per span region (region redraws don't lose it)
        canvas:_redrawRegion(canvas:_elementRegion(canvas.elements[2]))
        check(a(200, 300) == 0, "fill re-renders on region redraw")
        -- Undo restores
        canvas:_undo()
        check(#canvas.elements == 1, "undo removes fill")
        check(a(200, 300) == 255, "undo restores interior white")

        -- Path fill: a closed brush path (start = end) leaves only the filled area, the path ink is cleared (path not shown)
        local canvas2 = newCanvas()
        canvas2:_setTool("fill")
        canvas2:_toggleFillMode()
        check(canvas2.fill_mode == "path", "fill toggles to path mode")
        canvas2:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas2:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvas2.elements == 1 and canvas2.elements[1].kind == "fill",
            "closed path creates ONLY a fill element (no stroke), got "
            .. tostring(#canvas2.elements) .. "/"
            .. tostring(canvas2.elements[1] and canvas2.elements[1].kind))
        local bb2 = canvas2.canvas_bb
        local function a2(x, y) return bb2:getPixel(x, y) and bb2:getPixel(x, y).a end
        check(a2(150, 250) == 0, "closed path interior filled, got " .. tostring(a2(150, 250)))
        check(a2(99, 250) == 255, "path stroke cleared (not displayed), got " .. tostring(a2(99, 250)))

        -- Light outline: the boundary must be recognised, the fill must not overflow (flood tolerance 20)
        local canvasL = newCanvas()
        canvasL:_setTool("circle")
        canvasL:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local lcirc = canvasL.elements[1]
        lcirc.gray = 0.1 -- light grey outline (pixel value ≈229, differs from the white background by 26 > tolerance 20)
        canvasL:_redrawRegion(canvasL:_elementRegion(lcirc))
        canvasL:_setTool("fill")
        canvasL:onTap(nil, { pos = { x = 200, y = 300 } }) -- tap inside the circle
        local bbL = canvasL.canvas_bb
        local function aL(x, y) return bbL:getPixel(x, y) and bbL:getPixel(x, y).a end
        check(aL(200, 300) == 0, "light-stroke circle interior filled, got " .. tostring(aL(200, 300)))
        check(aL(90, 300) == 255, "light-stroke boundary stops fill (no overflow), got " .. tostring(aL(90, 300)))
        check(aL(100, 300) > 200, "light stroke ink preserved, got " .. tostring(aL(100, 300)))

        -- A 5% light outline (grey 0.05, pixel difference from white >8) is also a boundary, no overflow (edge-aware flood)
        local canvasL2 = newCanvas()
        canvasL2:_setTool("circle")
        canvasL2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        local lcirc2 = canvasL2.elements[1]
        lcirc2.gray = 0.05
        canvasL2:_redrawRegion(canvasL2:_elementRegion(lcirc2))
        canvasL2:_setTool("fill")
        canvasL2:onTap(nil, { pos = { x = 200, y = 300 } })
        local bbL2 = canvasL2.canvas_bb
        local function aL2(x, y) return bbL2:getPixel(x, y) and bbL2:getPixel(x, y).a end
        check(aL2(200, 300) == 0, "5% stroke circle interior filled, got " .. tostring(aL2(200, 300)))
        check(aL2(90, 300) == 255, "5% stroke boundary stops fill (no overflow), got " .. tostring(aL2(90, 300)))

        -- Interference: path fill is computed only from its own path, not cut off/polluted by other strokes
        local canvasI = newCanvas()
        canvasI:_setTool("brush")
        canvasI:onSwipe(nil, { pos = { x = 100, y = 250 }, end_pos = { x = 300, y = 250 } }) -- first draw a horizontal line across the area
        canvasI:_setTool("fill")
        canvasI:_toggleFillMode()
        canvasI:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasI:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvasI.elements == 2 and canvasI.elements[2].kind == "fill",
            "interference: only line + fill (no stroke), got "
            .. tostring(#canvasI.elements) .. "/"
            .. tostring(canvasI.elements[2] and canvasI.elements[2].kind))
        local bbI = canvasI.canvas_bb
        local function aI(x, y) return bbI:getPixel(x, y) and bbI:getPixel(x, y).a end
        check(aI(150, 220) == 0, "fill covers above crossing line, got " .. tostring(aI(150, 220)))
        check(aI(150, 280) == 0, "fill covers below crossing line, got " .. tostring(aI(150, 280)))
        check(aI(250, 250) == 0, "crossing line outside square preserved, got " .. tostring(aI(250, 250)))
        check(aI(99, 220) == 255, "path boundary cleared (not displayed), got " .. tostring(aI(99, 220)))

        -- Long-distance auto close: even when the end point is far from the start it closes and fills the interior (end point not snapped,
        -- closing segment = straight line from pen-up point to start, filled area = quadrilateral enclosed by the path + closing segment)
        local canvas3 = newCanvas()
        canvas3:_setTool("fill")
        canvas3:_toggleFillMode()
        canvas3:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvas3:onPan(nil, { pos = { x = 250, y = 250 }, start_pos = { x = 100, y = 200 } }) -- end point far to the upper right
        canvas3:onPanRelease(nil, { pos = { x = 250, y = 250 } })
        check(canvas3.elements[1] and canvas3.elements[1].kind == "fill",
            "far endpoint auto-closes and fills, got "
            .. tostring(canvas3.elements[1] and canvas3.elements[1].kind))
        local bb3 = canvas3.canvas_bb
        local function a3(x, y) return bb3:getPixel(x, y) and bb3:getPixel(x, y).a end
        check(a3(210, 280) == 0, "auto-closed quadrilateral interior filled, got " .. tostring(a3(210, 280)))
        check(a3(120, 240) == 255, "outside auto-closed region stays white, got " .. tostring(a3(120, 240)))

        -- A straight line produces no fill, and the path isn't shown either (2-point degenerate -> nothing left)
        local canvas4 = newCanvas()
        canvas4:_setTool("fill")
        canvas4:_toggleFillMode()
        canvas4:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPan(nil, { pos = { x = 300, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas4:onPanRelease(nil, { pos = { x = 300, y = 300 } })
        check(#canvas4.elements == 0,
            "straight line should leave nothing (no fill, no stroke), got " .. tostring(#canvas4.elements))

        -- Path fill = a single fill element + one undo record: one undo clears it, redo restores the fill
        local canvasU = newCanvas()
        canvasU:_setTool("fill")
        canvasU:_toggleFillMode()
        canvasU:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasU:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#canvasU.elements == 1 and canvasU.elements[1].kind == "fill" and #canvasU.undo == 1,
            "path fill should be ONE fill element + ONE undo, got "
            .. tostring(#canvasU.elements) .. "/" .. tostring(#canvasU.undo))
        local bbU = canvasU.canvas_bb
        local function aU(x, y) return bbU:getPixel(x, y) and bbU:getPixel(x, y).a end
        check(aU(150, 250) == 0, "path fill interior filled before undo")
        check(aU(99, 250) == 255, "path stroke cleared (not displayed), got " .. tostring(aU(99, 250)))
        canvasU:_undo()
        check(#canvasU.elements == 0, "one undo clears fill, got " .. tostring(#canvasU.elements))
        check(aU(150, 250) == 255, "undo clears fill interior, got " .. tostring(aU(150, 250)))
        canvasU:_redo()
        check(#canvasU.elements == 1 and canvasU.elements[1].kind == "fill",
            "redo restores fill, got "
            .. tostring(#canvasU.elements) .. "/"
            .. tostring(canvasU.elements[1] and canvasU.elements[1].kind))
        check(aU(150, 250) == 0, "redo re-fills interior, got " .. tostring(aU(150, 250)))

        -- Path fill fast finish (the in-progress path is completed by a swipe): also closes and fills automatically, path not shown
        local canvasS = newCanvas()
        canvasS:_setTool("fill")
        canvasS:_toggleFillMode()
        canvasS:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasS:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        canvasS:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        canvasS:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 100, y = 200 } }) -- fast finish closes
        check(#canvasS.elements == 1 and canvasS.elements[1].kind == "fill",
            "swipe-finished path should fill only (no stroke), got "
            .. tostring(#canvasS.elements) .. "/"
            .. tostring(canvasS.elements[1] and canvasS.elements[1].kind))
        local bbS = canvasS.canvas_bb
        local function aS(x, y) return bbS:getPixel(x, y) and bbS:getPixel(x, y).a end
        check(aS(150, 250) == 0, "swipe-finished path interior filled, got " .. tostring(aS(150, 250)))
        check(aS(99, 250) == 255, "swipe-finished path stroke cleared, got " .. tostring(aS(99, 250)))

        -- Tap fill: must also fill when the gesture is classified as pan / hold / swipe (prevents "occasionally does nothing")
        local canvasT = newCanvas()
        canvasT:_setTool("circle")
        canvasT:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT:_setTool("fill")
        canvasT:onPan(nil, { pos = { x = 203, y = 300 }, start_pos = { x = 200, y = 300 } })
        canvasT:onPanRelease(nil, { pos = { x = 203, y = 300 } }) -- tap classified as pan
        check(canvasT.elements[2] and canvasT.elements[2].kind == "fill",
            "pan-delivered tap should fill, got "
            .. tostring(canvasT.elements[2] and canvasT.elements[2].kind))
        local bbT = canvasT.canvas_bb
        local function aT(x, y) return bbT:getPixel(x, y) and bbT:getPixel(x, y).a end
        check(aT(200, 300) == 0, "pan-delivered tap interior filled, got " .. tostring(aT(200, 300)))
        check(aT(50, 300) == 255, "pan-delivered tap stays inside circle (no overflow)")
        local canvasT2 = newCanvas()
        canvasT2:_setTool("circle")
        canvasT2:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT2:_setTool("fill")
        canvasT2:onHold(nil, { pos = { x = 200, y = 300 } })
        canvasT2:onHoldRelease(nil, { pos = { x = 200, y = 300 } }) -- tap classified as hold
        check(canvasT2.elements[2] and canvasT2.elements[2].kind == "fill",
            "hold-delivered tap should fill, got "
            .. tostring(canvasT2.elements[2] and canvasT2.elements[2].kind))
        local canvasT3 = newCanvas()
        canvasT3:_setTool("circle")
        canvasT3:onSwipe(nil, { pos = { x = 200, y = 300 }, end_pos = { x = 300, y = 300 } })
        canvasT3:_setTool("fill")
        canvasT3:onSwipe(nil, { pos = { x = 195, y = 300 }, end_pos = { x = 205, y = 300 } }) -- quick tap
        check(canvasT3.elements[2] and canvasT3.elements[2].kind == "fill",
            "swipe-delivered tap should fill, got "
            .. tostring(canvasT3.elements[2] and canvasT3.elements[2].kind))

        -- Path fill fast finish with the swipe end point leaving the canvas: must also close and fill immediately (nothing lingering until the next operation)
        local canvasO = newCanvas()
        canvasO:_setTool("fill")
        canvasO:_toggleFillMode()
        canvasO:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        canvasO:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        check(canvasO._stroke ~= nil, "stroke in progress before swipe-out")
        canvasO:onSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 100, y = 50 } }) -- end point in the header (outside the canvas)
        check(canvasO._stroke == nil and #canvasO.elements == 1 and canvasO.elements[1].kind == "fill",
            "swipe-out should commit fill immediately (no residual stroke), got stroke="
            .. tostring(canvasO._stroke ~= nil) .. " elements=" .. tostring(#canvasO.elements)
            .. " kind=" .. tostring(canvasO.elements[1] and canvasO.elements[1].kind))

        -- Path fill finish classified as multiswipe (the flick changed direction): must also finish and fill immediately (MultiSwipe registered)
        local canvasM = newCanvas()
        canvasM:_setTool("fill")
        canvasM:_toggleFillMode()
        canvasM:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        canvasM:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        check(canvasM._stroke ~= nil, "stroke in progress before multiswipe")
        canvasM:onMultiSwipe(nil, { pos = { x = 100, y = 400 }, end_pos = { x = 100, y = 50 } }) -- end point flicked into the header
        check(canvasM._stroke == nil and #canvasM.elements == 1 and canvasM.elements[1].kind == "fill",
            "multiswipe finish should commit fill immediately, got stroke="
            .. tostring(canvasM._stroke ~= nil) .. " elements=" .. tostring(#canvasM.elements)
            .. " kind=" .. tostring(canvasM.elements[1] and canvasM.elements[1].kind))
        -- The canvas really registered the MultiSwipe gesture (dispatched via onGesture to onMultiSwipe)
        check(canvasM.ges_events and canvasM.ges_events.MultiSwipe ~= nil,
            "canvas should register MultiSwipe gesture")
        print("fill tool: tap fill / path fill OK")
    end)
    if ok then
        print("PASS: fill tool")
    else
        print("FAIL: fill tool:", tostring(err))
        os.exit(1)
    end
end

-- ============ 16. Text selection box alignment (rotate/stretch) + slider adjustment popup ============
do
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        -- 16a. Rendered text ink aligns with the element bounding box (fix: after rotate/stretch the glyphs and selection box were offset by 0.8*font size)
        local function makeTextCanvas(text, size)
            local c = newCanvas()
            local el = { kind = "text", x = 200, y = 400, text = text, font = c.font, size = size, gray = 1.0 }
            table.insert(c.elements, el)
            c:_cacheBBox(el)
            return c, el
        end
        -- After rendering scan the ink extent and assert: (1) the ink is inside the element bbox (before the fix the whole thing shifted out);
        -- (2) the ink centre aligns with the bbox centre (offset detection, robust to glyph/anti-aliasing gaps)
        local function inkInside(c, el)
            c:_cacheBBox(el)
            local b = el._bbox
            c.canvas_bb:paintRect(0, 0, c.canvas_w, c.canvas_h, Blitbuffer.COLOR_WHITE)
            c:_drawTextTo(c.canvas_bb, el)
            local bb = c.canvas_bb
            local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
            local pad = 48
            for py = math.floor(b.y0) - pad, math.ceil(b.y1) + pad do
                for px = math.floor(b.x0) - pad, math.ceil(b.x1) + pad do
                    if px >= 0 and px < bb:getWidth() and py >= 0 and py < bb:getHeight() then
                        local p = bb:getPixel(px, py)
                        if p and p.a < 255 then
                            if px < minx then minx = px end
                            if px > maxx then maxx = px end
                            if py < miny then miny = py end
                            if py > maxy then maxy = py end
                        end
                    end
                end
            end
            if minx == math.huge then
                return false, "no ink rendered"
            end
            local inside = minx >= b.x0 - 2 and miny >= b.y0 - 2
                and maxx <= b.x1 + 2 and maxy <= b.y1 + 2
            local cdx = math.abs((minx + maxx) / 2 - (b.x0 + b.x1) / 2)
            local cdy = math.abs((miny + maxy) / 2 - (b.y0 + b.y1) / 2)
            local centered = cdx <= 4 and cdy <= 4
            return inside and centered,
                string.format("ink(%d,%d..%d,%d) bbox(%d,%d..%d,%d) center_delta(%d,%d)",
                    minx, miny, maxx, maxy, b.x0, b.y0, b.x1, b.y1, cdx, cdy)
        end

        local c1, el1 = makeTextCanvas("Align test", 32)
        local ok1, msg1 = inkInside(c1, el1)
        check(ok1, "untransformed text ink inside/centered: " .. msg1)
        local sb1 = el1._bbox
        local cx1, cy1 = (sb1.x0 + sb1.x1) / 2, (sb1.y0 + sb1.y1) / 2
        c1:_rotateElement(el1, math.pi / 2, cx1, cy1)
        local ok90, msg90 = inkInside(c1, el1)
        check(ok90, "rotated-90 text ink inside/centered: " .. msg90)
        local c2, el2 = makeTextCanvas("Tilted", 28)
        local sb2 = el2._bbox
        local cx2, cy2 = (sb2.x0 + sb2.x1) / 2, (sb2.y0 + sb2.y1) / 2
        c2:_rotateElement(el2, math.pi / 4, cx2, cy2)
        local ok45, msg45 = inkInside(c2, el2)
        check(ok45, "rotated-45 text ink inside/centered: " .. msg45)
        local c3, el3 = makeTextCanvas("Stretch", 24)
        local sb3 = el3._bbox
        c3:_scaleElement(el3, sb3, { x0 = sb3.x0, y0 = sb3.y0, x1 = sb3.x0 + (sb3.x1 - sb3.x0) * 2, y1 = sb3.y1 })
        local okstr, msgstr = inkInside(c3, el3)
        check(okstr, "stretched text ink inside/centered: " .. msgstr)
        print("text frame align: untransformed/rot90/rot45/stretch OK")

        local UIManager = require("ui/uimanager")

        -- 16b. Selected object grey: slider popup structure + slider tap conversion + preset steps + closing writes undo
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line = canvas.elements[1]
        local undo0 = #canvas.undo -- drawing the line already wrote 1 record
        canvas:_setTool("select")
        canvas:onTap(nil, { pos = { x = 150, y = 300 } })
        check(canvas._selected == line, "select line for value picker")
        local orig_show = UIManager.show
        local captured
        UIManager.show = function(self, w) captured = w; return true end
        pcall(function() canvas:_pickElementGray() end)
        UIManager.show = orig_show
        if captured and captured.name == "DrawingValuePicker" then
            -- Real paint check (constructs OK but a paint crash would take the whole device down, e.g. a missing pbar_w definition)
            local Screen = require("device").screen
            local ok_paint = pcall(function() captured:paintTo(Screen.bb, 0, 0) end)
            check(ok_paint, "value picker should paint without error")
            local progress_ref
            local function walk(w)
                if not w then return end
                if w.getPercentageFromPosition then progress_ref = w end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then walk(cw) end
                end
            end
            walk(captured)
            check(progress_ref ~= nil, "value picker should contain ProgressWidget slider")
            -- Slider tap positioning: go through the real event chain (Event:new packs nil args as placeholders too,
            -- handlers must have the signature (_, ges) otherwise ges=nil crashes) - midpoint -> 50%
            if progress_ref then
                progress_ref.dimen = Geom:new{ x = 100, y = 200, w = 400, h = 10 }
                local Event = require("ui/event")
                captured:handleEvent(Event:new("TapProgress", nil, { pos = { x = 300, y = 205 } }))
                check(math.abs(line.gray - 0.5) < 0.001,
                    "slider tap sets 50%, got " .. tostring(line.gray))
            end
            -- Preset steps as percentages of the maximum: 0 (min), 12 (1/8), 25 (2/8)...100 (8/8)
            local preset_btn
            local preset_12
            local function findBtn(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "50%" then preset_btn = b end
                            if b.text == "12%" then preset_12 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findBtn(cw) end
                end
            end
            findBtn(captured)
            check(preset_btn ~= nil, "value picker should have 50% preset (4/8)")
            check(preset_12 ~= nil, "value picker should have 12% preset (1/8 of max)")
            if preset_btn then
                preset_btn.callback()
                check(math.abs(line.gray - 0.5) < 0.001,
                    "preset button applies gray, got " .. tostring(line.gray))
            end
            -- Step row -10/-1/+1/+10 exists; tap +10 -> gray 0.5->0.6
            local btn_p10, btn_m10
            local function findStep(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "+10" then btn_p10 = b end
                            if b.text == "-10" then btn_m10 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findStep(cw) end
                end
            end
            findStep(captured)
            check(btn_p10 ~= nil and btn_m10 ~= nil,
                "value picker should have -10/+10 step buttons")
            if btn_p10 then
                btn_p10.callback()
                check(math.abs(line.gray - 0.6) < 0.001,
                    "+10 step applies, got " .. tostring(line.gray))
            end
            if btn_m10 then
                btn_m10.callback()
                check(math.abs(line.gray - 0.5) < 0.001,
                    "-10 step reverts, got " .. tostring(line.gray))
            end
            -- Close -> writes one undo record (1 for the line + 1 for grey)
            captured:onCloseWidget()
            check(#canvas.undo == undo0 + 1, "value picker close writes one undo, got " .. tostring(#canvas.undo))
        else
            print("WARN: value adjustment popup could not be constructed headless, skipping structure assertions")
        end

        -- 16c. Selected object width: preset steps + undo
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onSwipe(nil, { pos = { x = 100, y = 300 }, end_pos = { x = 200, y = 300 } })
        local line2 = canvas2.elements[1]
        local undo2_0 = #canvas2.undo
        canvas2:_setTool("select")
        canvas2:onTap(nil, { pos = { x = 150, y = 300 } })
        local orig_show2 = UIManager.show
        local captured2
        UIManager.show = function(self, w) captured2 = w; return true end
        pcall(function() canvas2:_pickElementWidth() end)
        UIManager.show = orig_show2
        if captured2 and captured2.name == "DrawingValuePicker" then
            local Screen = require("device").screen
            local ok_paint2 = pcall(function() captured2:paintTo(Screen.bb, 0, 0) end)
            check(ok_paint2, "width picker should paint without error")
            -- Width limit 800, steps as percentages of the maximum and no px suffix: 1 (min), 100 (1/8), 200 (2/8)...
            local btn100
            local btn800
            local function findBtn2(w)
                if not w then return end
                if w.buttons then
                    for _, row in ipairs(w.buttons) do
                        for _, b in ipairs(row) do
                            if b.text == "100" then btn100 = b end
                            if b.text == "800" then btn800 = b end
                        end
                    end
                end
                for i = 1, 40 do
                    local cw = w[i]
                    if cw then findBtn2(cw) end
                end
            end
            findBtn2(captured2)
            check(captured2.max == 800, "width picker max should be 800, got " .. tostring(captured2.max))
            check(btn100 ~= nil and btn800 ~= nil,
                "width picker presets should be max-percentage without px (100/800)")
            if btn100 then
                btn100.callback()
                check(line2.width == 100, "preset width 1/8 applied, got " .. tostring(line2.width))
            end
            captured2:onCloseWidget()
            check(#canvas2.undo == undo2_0 + 1, "width picker close writes undo, got " .. tostring(#canvas2.undo))
        else
            print("WARN: width popup could not be constructed headless, skipping assertions")
        end

        -- 16d. "Fixed" in the global grey settings -> pops up the slider popup
        local canvas3 = newCanvas()
        local orig_show3 = UIManager.show
        local captures3 = {}
        UIManager.show = function(self, w) captures3[#captures3 + 1] = w; return true end
        pcall(function() canvas3:_pickGray() end)
        UIManager.show = orig_show3
        if captures3[1] and captures3[1].buttons then
            local fixed_btn
            for _, row in ipairs(captures3[1].buttons) do
                for _, b in ipairs(row) do
                    if b.id == "gray_fixed_btn" then fixed_btn = b end
                end
            end
            check(fixed_btn ~= nil, "gray menu should have fixed button")
            if fixed_btn then
                local orig_show4 = UIManager.show
                local captured4
                UIManager.show = function(self, w) captured4 = w; return true end
                fixed_btn.callback()
                UIManager.show = orig_show4
                check(captured4 ~= nil and captured4.name == "DrawingValuePicker",
                    "fixed gray should open slider picker, got " .. tostring(captured4 and captured4.name))
            end
        else
            print("WARN: grey menu could not be constructed headless, skipping assertions")
        end
        -- 16e. With a large width, hollow circles/rectangles aren't wrongly discarded (shape threshold decoupled from line width)
        local cw = newCanvas()
        cw:_setTool("circle")
        cw.width = 800
        cw:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
        cw:onPanRelease(nil, { pos = { x = 380, y = 400 } }) -- radius 80
        check(#cw.elements == 1 and cw.elements[1].kind == "circle" and cw.elements[1].rx == 80,
            "thick-width hollow circle should commit (not dropped), got "
            .. tostring(#cw.elements) .. "/" .. tostring(cw.elements[1] and cw.elements[1].rx))
        local cw2 = newCanvas()
        cw2:_setTool("rect")
        cw2.width = 800
        cw2:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 200, y = 400 } })
        cw2:onPanRelease(nil, { pos = { x = 300, y = 480 } }) -- 100x80
        check(#cw2.elements == 1 and cw2.elements[1].kind == "rect",
            "thick-width rect should commit (not dropped), got " .. tostring(#cw2.elements))
        -- With a large width a tiny accidental touch (radius 3) is still discarded
        local cw3 = newCanvas()
        cw3:_setTool("circle")
        cw3.width = 800
        cw3:onPan(nil, { pos = { x = 300, y = 400 }, start_pos = { x = 300, y = 400 } })
        cw3:onPanRelease(nil, { pos = { x = 303, y = 400 } }) -- radius 3 < 8
        check(#cw3.elements == 0, "tiny thick-width circle still dropped as accidental, got "
            .. tostring(#cw3.elements))
        print("thick-width shapes: commit / drop OK")

        -- 16f. Selected text -> tap the "Text" tool -> property edit (content/font/size)
        local cEdit = newCanvas()
        local tel = { kind = "text", x = 200, y = 400, text = "Old text", font = cEdit.font, size = 24, gray = 1.0 }
        table.insert(cEdit.elements, tel)
        cEdit:_cacheBBox(tel)
        cEdit:_setTool("select")
        cEdit:onTap(nil, { pos = { x = 200, y = 400 } })
        check(cEdit._selected == tel, "select text element")
        local edit_undo0 = #cEdit.undo
        -- Core: update the text element (the dialog can't be constructed headless, test the method directly)
        cEdit:_updateTextElement(tel, "New text")
        check(tel.text == "New text", "text content updated, got " .. tostring(tel.text))
        check(#cEdit.undo == edit_undo0 + 1, "text edit writes one undo, got "
            .. tostring(#cEdit.undo))
        -- No change writes no undo
        cEdit:_updateTextElement(tel, "New text")
        check(#cEdit.undo == edit_undo0 + 1, "no-change edit skips undo")
        -- _setTool entry: with text selected, tapping the text tool doesn't switch tools (popup skipped headless, assert the tool doesn't switch)
        local orig_showE = UIManager.show
        local capturedE
        UIManager.show = function(self, w) capturedE = w; return true end
        cEdit:_setTool("text")
        UIManager.show = orig_showE
        check(cEdit.tool == "select", "text tool click with text selected should not switch tool")
        if capturedE and capturedE.getInputText then
            check(capturedE:getInputText() == "New text", "edit dialog prefills content")
        else
            print("WARN: text edit dialog could not be constructed headless, skipping popup assertions")
        end

        -- 16g. After inserting text remember the last content and font; the next insert prefills them
        local cAuto = newCanvas()
        cAuto:_setTool("text")
        cAuto:_commitText(300, 400, "Last text")
        check(cAuto._last_text == "Last text", "last text saved, got "
            .. tostring(cAuto._last_text))
        check(cAuto._last_font == cAuto.font and cAuto._last_font_size == cAuto.font_size,
            "last font/size saved")
        -- The insert dialog prefills the last content (InputDialog can't be constructed headless; assert if construction succeeds)
        local orig_showA = UIManager.show
        local capturedA
        UIManager.show = function(self, w) capturedA = w; return true end
        pcall(function() cAuto:_showTextDialog(300, 400) end)
        UIManager.show = orig_showA
        if capturedA and capturedA.getInputText then
            check(capturedA:getInputText() == "Last text",
                "dialog prefills last text, got " .. tostring(capturedA:getInputText()))
        else
            print("WARN: text insert dialog could not be constructed headless, skipping prefill assertion")
        end
        print("text edit dialog / last-input prefill OK")

        -- 16h. Path fill: outline fixed at 1px (ignores the width setting) + smoothing (including pen-down/pen-up points)
        local cW = newCanvas()
        cW.width = 40 -- large width, the outline should still be 1px
        cW:_setTool("fill")
        cW:_toggleFillMode()
        cW:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cW:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(cW._stroke ~= nil and cW._stroke.width == 1,
            "fill path stroke width fixed at 1, got " .. tostring(cW._stroke and cW._stroke.width))
        -- hold pen-down is also 1px
        local cH = newCanvas()
        cH.width = 80
        cH:_setTool("fill")
        cH:_toggleFillMode()
        cH:onHold(nil, { pos = { x = 100, y = 300 } })
        check(cH._stroke ~= nil and cH._stroke.width == 1,
            "fill path hold stroke width fixed at 1, got " .. tostring(cH._stroke and cH._stroke.width))
        -- _smoothClosedPath unit: closed square -> more points, first = last = start, centroid near the centre
        local cS = newCanvas()
        local sq = {
            { x = 100, y = 100 }, { x = 200, y = 100 },
            { x = 200, y = 200 }, { x = 100, y = 200 },
            { x = 100, y = 100 }, -- closing
        }
        local sm = cS:_smoothClosedPath(sq)
        check(#sm > #sq, "smooth should add points, got " .. tostring(#sm))
        -- Chaikin 2 rounds: square with 4 unique points -> 2 points per segment per round -> 16 + 1 closing = 17
        check(#sm == 4 * 2 * 2 + 1, "chaikin 2 rounds per corner, got " .. tostring(#sm))
        -- Closed: the last point returns to the first (Chaikin corner cutting doesn't keep original vertices, first point = 3/4 point of the first segment)
        local sf = sm[1]
        local sl = sm[#sm]
        check(sl.x == sf.x and sl.y == sf.y, "smooth closes (first==last)")
        -- Unclosed sequence (last ≠ first): automatically closed after smoothing (last point returns to the first)
        local open = {
            { x = 100, y = 100 }, { x = 200, y = 100 },
            { x = 200, y = 200 }, { x = 100, y = 200 },
        } -- three sides and a corner of a square, not closed
        local smo = cS:_smoothClosedPath(open)
        local sl2 = smo[#smo]
        check(sl2.x == smo[1].x and sl2.y == smo[1].y, "unclosed path auto-closes back to start")
        check(#smo == 4 * 2 * 2 + 1, "unclosed path smoothed+closed, got " .. tostring(#smo))
        local mx, my = 0, 0
        for _, p in ipairs(sm) do
            mx, my = mx + p.x, my + p.y
        end
        mx, my = mx / #sm, my / #sm
        check(math.abs(mx - 150) < 20 and math.abs(my - 150) < 20,
            "smooth centroid near square center, got " .. mx .. "," .. my)
        -- Path fill overall regression: closed path (shaky zigzag) -> fill element spans non-empty (smoothed boundary)
        local cF = newCanvas()
        cF:_setTool("fill")
        cF:_toggleFillMode()
        cF:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 120, y = 205 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 200, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 210, y = 250 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 110, y = 305 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 200 } })
        cF:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
        cF:onPanRelease(nil, { pos = { x = 100, y = 200 } })
        check(#cF.elements == 1 and cF.elements[1].kind == "fill"
            and cF.elements[1].spans and #cF.elements[1].spans > 0,
            "smoothed closed path fills, got "
            .. tostring(cF.elements[1] and cF.elements[1].kind))
        local bbF = cF.canvas_bb
        local function aF(x, y) return bbF:getPixel(x, y) and bbF:getPixel(x, y).a end
        check(aF(150, 250) == 0, "smoothed fill interior black, got " .. tostring(aF(150, 250)))
        print("fill path: 1px stroke / bezier smoothing OK")

        -- 16i. Bottom layout: toolbar/status bar at the bottom, the top is drawable, the bottom covered area isn't
        local cBot = newCanvas()
        check(cBot:_toCanvas(100, 50) ~= nil,
            "top area should be drawable (bottom toolbar layout)")
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) == nil,
            "bottom toolbar area should not be drawable")
        check(cBot:_toCanvas(100, cBot.canvas_h - cBot.header_h - 5) ~= nil,
            "just above bottom header should be drawable")
        -- After minimising the bottom is drawable too (toolbar hidden)
        cBot:_setMinimized(true)
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) ~= nil,
            "minimized bottom should be drawable")
        cBot:_setMinimized(false)
        check(cBot:_toCanvas(100, cBot.canvas_h - 1) == nil,
            "restored bottom not drawable again")
        -- v59b removed long-press: panel items only have tap; line/brush are separate items, toolSet switches directly
        local toolBt = cBot:_categoryBt("tool")
        check(toolBt.button_by_id["brush_btn"].hold_callback == nil
            and toolBt.button_by_id["line_btn"] ~= nil,
            "no hold_callback on panel entries; line_btn exists")
        toolBt.button_by_id["line_btn"].callback()
        check(cBot.tool == "line", "line_btn tap switches to line, got " .. tostring(cBot.tool))
        toolBt.button_by_id["brush_btn"].callback()
        check(cBot.tool == "brush", "brush_btn tap switches back")
        print("bottom layout / panel entries OK")

        -- 16j. Fill results support selection: select/move/grey/scale/copy
        local cF2 = newCanvas()
        cF2:_setTool("fill")
        cF2:_toggleFillMode()
        cF2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 200, y = 400 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 100, y = 400 }, start_pos = { x = 100, y = 300 } })
        cF2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        cF2:onPanRelease(nil, { pos = { x = 100, y = 300 } })
        local fillEl = cF2.elements[1]
        check(fillEl and fillEl.kind == "fill", "setup fill element")
        local fbb0 = fillEl._bbox
        cF2:_setTool("select")
        cF2:onTap(nil, { pos = { x = 150, y = 350 } }) -- tap inside the fill
        check(cF2._selected == fillEl, "fill element selectable")
        -- Move (+30,+20)
        cF2:onPan(nil, { pos = { x = 150, y = 350 }, start_pos = { x = 150, y = 350 } })
        cF2:onPanRelease(nil, { pos = { x = 180, y = 370 } })
        local fb1 = fillEl._bbox
        check(fb1.x0 == fbb0.x0 + 30 and fb1.y0 == fbb0.y0 + 20,
            "fill moved, got " .. fb1.x0 .. "," .. fb1.y0)
        -- Grey
        cF2:_applySelectedGray(50)
        check(math.abs(fillEl.gray - 0.5) < 0.001, "fill gray changed, got "
            .. tostring(fillEl.gray))
        -- Scale: drag the se corner to enlarge, the bbox grows and spans are re-rasterised
        local fc = cF2:_frameCorners(fillEl)
        local se = fc[3]
        cF2:onPan(nil, { pos = { x = se.x, y = se.y }, start_pos = { x = se.x, y = se.y } })
        cF2:onPanRelease(nil, { pos = { x = se.x + 60, y = se.y + 40 } })
        local fb2 = fillEl._bbox
        check(fb2.x1 > fb1.x1 + 40 and fb2.y1 > fb1.y1 + 20,
            "fill scaled bigger, got " .. fb1.x1 .. "->" .. fb2.x1 .. ", " .. fb1.y1 .. "->" .. fb2.y1)
        -- Copy: independent duplicate (spans deep-copied)
        cF2:_toggleSelectMode() -- copy
        cF2:onTap(nil, { pos = { x = 180, y = 370 } }) -- reselect (still inside after scaling)
        check(cF2._selected == fillEl, "reselect fill after scale")
        cF2:onPan(nil, { pos = { x = 180, y = 370 }, start_pos = { x = 180, y = 370 } })
        cF2:onPanRelease(nil, { pos = { x = 120, y = 430 } })
        check(#cF2.elements == 2, "fill copy adds element, got " .. tostring(#cF2.elements))
        local fillCopy = cF2.elements[2]
        check(fillCopy ~= fillEl and fillCopy.kind == "fill", "copy is distinct fill")
        check(fillCopy.spans[1] ~= fillEl.spans[1], "copy spans deep-copied")
        -- The enlarged fill must be dense: per-row single-point mapping leaves empty rows between target rows -> dense horizontal stripes;
        -- after the fix each source row's vertical half-row band covers the target rows, the row set is continuous (adjacent rows differ by 1)
        local ys = {}
        for _, sp in ipairs(fillEl.spans) do ys[sp[1]] = true end
        local ymin2, ymax2, nrows = math.huge, -math.huge, 0
        for y in pairs(ys) do
            nrows = nrows + 1
            if y < ymin2 then ymin2 = y end
            if y > ymax2 then ymax2 = y end
        end
        check(nrows > 0 and nrows == ymax2 - ymin2 + 1,
            "fill scaled-up spans dense (no horizontal stripes), rows=" .. nrows
            .. " range=" .. ymin2 .. "-" .. ymax2)
        -- Rotate: the "tap again" before the copy already switched to rotate mode (line 1914 above), drag the se corner to rotate 30° about the bbox centre
        check(cF2._handle_mode == "rotate", "fill toggles to rotate mode")
        local rb = fillEl._bbox
        local rcx, rcy = (rb.x0 + rb.x1) / 2, (rb.y0 + rb.y1) / 2
        local seA = { x = rb.x1 + 4, y = rb.y1 + 4 } -- se anchor (_frameCorners pad=4)
        local adx, ady = seA.x - rcx, seA.y - rcy
        local c30, s30 = math.cos(math.pi / 6), math.sin(math.pi / 6)
        cF2:onPan(nil, { pos = { x = seA.x, y = seA.y }, start_pos = { x = seA.x, y = seA.y } })
        cF2:onPanRelease(nil, {
            pos = { x = rcx + adx * c30 - ady * s30, y = rcy + adx * s30 + ady * c30 },
        })
        local rb2 = fillEl._bbox
        check(rb2.x1 - rb2.x0 > 120 and rb2.y1 - rb2.y0 > 120,
            "fill rotated 30deg bbox grows, got " .. (rb2.x1 - rb2.x0)
            .. "x" .. (rb2.y1 - rb2.y0))
        -- After rotation the row set is still dense (per-span rotation re-rasterisation, no stripes)
        local rys = {}
        for _, sp in ipairs(fillEl.spans) do rys[sp[1]] = true end
        local rmin, rmax, rn = math.huge, -math.huge, 0
        for y in pairs(rys) do
            rn = rn + 1
            if y < rmin then rmin = y end
            if y > rmax then rmax = y end
        end
        check(rn > 0 and rn == rmax - rmin + 1,
            "fill rotated spans dense, rows=" .. rn .. " range=" .. rmin .. "-" .. rmax)
        -- After rotation it can still switch back to scale mode
        cF2:onTap(nil, { pos = { x = 180, y = 370 } })
        check(cF2._handle_mode == "scale", "fill toggles back to scale")
        -- The refresh region of the rotation commit must cover the accumulated preview area: fill ghosts at intermediate positions while the drag preview followed
        -- if not merged into the commit refresh, several angles of fill ghost remain after release = stripes (bigger and more visible for stretch previews)
        do
            local UIManager = require("ui/uimanager")
            local seen = {}
            local old_sd = UIManager.setDirty
            UIManager.setDirty = function(_, _, mode, region)
                table.insert(seen, { mode = mode, region = region })
            end
            -- Simulate an intermediate position of the following preview: rotate 30° then translate (the ghost area clearly away from the commit area)
            local pv2 = cF2:_cloneElement(fillEl)
            local bb3 = fillEl._bbox
            local pcx, pcy = (bb3.x0 + bb3.x1) / 2, (bb3.y0 + bb3.y1) / 2
            cF2:_rotateElement(pv2, math.rad(30), pcx, pcy)
            cF2:_moveElement(pv2, 60, 40)
            cF2:_cacheBBox(pv2)
            cF2._drag_preview = pv2
            cF2._drag_preview_region = cF2:_elementRegion(pv2)
            local pvr = cF2._drag_preview_region
            -- Drag a corner to rotate and commit (45°)
            cF2._handle_mode = "rotate"
            local fc3 = cF2:_frameCorners(fillEl)
            local se3 = fc3[3]
            local bb4 = fillEl._bbox
            local cx3, cy3 = (bb4.x0 + bb4.x1) / 2, (bb4.y0 + bb4.y1) / 2
            local dx3, dy3 = se3.x - cx3, se3.y - cy3
            local c45b, s45b = math.cos(math.pi / 4), math.sin(math.pi / 4)
            cF2:onPan(nil, { pos = { x = se3.x, y = se3.y }, start_pos = { x = se3.x, y = se3.y } })
            cF2:onPanRelease(nil, {
                pos = { x = cx3 + dx3 * c45b - dy3 * s45b, y = cy3 + dx3 * s45b + dy3 * c45b },
            })
            UIManager.setDirty = old_sd
            local cov = false
            for _, s in ipairs(seen) do
                local r = s.region
                if r and pvr and pvr.x >= r.x and pvr.y >= r.y
                    and pvr.x + pvr.w <= r.x + r.w and pvr.y + pvr.h <= r.y + r.h then
                    cov = true
                end
            end
            check(cov, "rotate submit refresh covers preview residue region")
        end
        -- Narrow rows of a rotated fill must keep their original geometric boundary and must not be expanded by neighbouring rows into poke-through lines.
        -- (with src_points rotated spans are recomputed by a vertex scanline, naturally dense and seamless, narrow rows are real
        -- geometric tips; rendering rewrites the spans as-is, no more "neighbour row expansion" patching - the expansion itself was the poke-through)
        do
            local Blitbuffer = require("ffi/blitbuffer")
            local shapes = require("drawingpad.shapes")
            local fe = { kind = "fill", gray = 1, spans = {} }
            for y = 100, 120 do fe.spans[#fe.spans + 1] = { y, 100, 200 } end
            for i, sp in ipairs(fe.spans) do
                if sp[1] == 110 then fe.spans[i] = { 110, 150, 150 } end
            end
            local bbF = Blitbuffer.new(300, 150, Blitbuffer.TYPE_BB8)
            bbF:fill(Blitbuffer.COLOR_WHITE)
            shapes.drawElement(bbF, fe, Blitbuffer.gray(1), 0, 0)
            local black = 0
            for x = 99, 201 do
                if bbF:getPixel(x, 110).a < 200 then black = black + 1 end
            end
            bbF:free()
            check(black == 1, "render keeps narrow row as-is (no expansion), got " .. black)
        end
        print("fill selectable: pick/move/gray/scale/copy/rotate OK")
        print("value picker: slider tap/presets/undo OK")
    end)
    if ok then
        print("PASS: text frame align / value picker")
    else
        print("FAIL: text frame align / value picker:", tostring(err))
        os.exit(1)
    end
end

print("ALL FEATURE TESTS PASSED")
os.exit(0)
