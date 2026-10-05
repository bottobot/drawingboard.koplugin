--[[--
Drawing board stability unit tests (crash fixes):
1. Scheduled tasks: scheduleIn returns nil so there is no handle -> keep the closure reference, unschedule cancels by reference;
   preview timers don't pile up while dragging shapes (the old pile-up once produced 40+ "preview shown" lines in the same second on the device);
   after close/tool switch the tasks are removed from the queue, and manually firing a pending callback after close doesn't error
2. Element bbox cache: after commit el._bbox exists and matches _elementBBox; tap-delete still hits after the prefilter
3. Region redraw: after deleting the upper stroke, the overlap restores the lower ink and only the upper-only area turns white (pixel assertions)
4. Stroke thinning: 10000 points -> 4096 keeping first and last; the minimum step drops 1px dense points
5. Text nil-face guard: a missing font doesn't throw, the text element is still committed
6. Save: _nextSavePath adds a number within the same second; _doSave really writes a PNG (magic check)

Run (from the KOReader root):
    ./koreader-emulator-x86_64-linux-gnu-debug/koreader/luajit plugins/drawingboard.koplugin/drawingpad/test/stability_test.lua
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
-- (the sdl device module accesses G_reader_settings at load time; same order as render_test)
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _inited = false
local function newCanvas()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    return DrawingCanvas:new{ on_close = function() end }
end

local function check(cond, msg)
    if not cond then
        error("FAIL: " .. msg)
    end
end

-- ============ 1. Scheduled tasks: cancel by closure reference + no pile-up ============
do
    local ok, err = pcall(function()
        local UIManager = require("ui/uimanager")
        local orig_scheduleIn = UIManager.scheduleIn
        local orig_unschedule = UIManager.unschedule
        local queue = {}
        local scheduled, unscheduled = 0, 0
        -- Simulate the real behaviour: scheduleIn returns nothing (nil); unschedule removes by closure reference
        UIManager.scheduleIn = function(self, seconds, action)
            scheduled = scheduled + 1
            table.insert(queue, action)
            return nil
        end
        UIManager.unschedule = function(self, action)
            local removed = false
            for i = #queue, 1, -1 do
                if queue[i] == action then
                    table.remove(queue, i)
                    removed = true
                    unscheduled = unscheduled + 1
                end
            end
            return removed
        end

        local canvas = newCanvas()
        canvas:_setTool("circle")
        -- 5 consecutive drag pans: each cancels the previous preview timer and reschedules -> the queue always holds 1
        for i = 1, 5 do
            canvas:_trackShapeAnchor({ pos = { x = 100 + i * 10, y = 300 }, start_pos = { x = 100, y = 300 } })
        end
        check(#queue == 1, "shape preview tasks should not accumulate, got " .. #queue)
        check(scheduled == 5 and unscheduled == 4,
            "expect 5 scheduled / 4 cancelled, got " .. scheduled .. "/" .. unscheduled)
        -- Close: pending tasks are removed from the queue (the old version couldn't cancel, they still fired after close)
        canvas:onCloseWidget()
        check(#queue == 0, "close should remove pending tasks, got " .. #queue)

        -- Brush throttle: continuous extension queues only 1 task; cancelled after a tool switch
        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 150, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas2:onPan(nil, { pos = { x = 200, y = 300 }, start_pos = { x = 100, y = 300 } })
        check(#queue == 1, "stroke repaint should have 1 pending task, got " .. #queue)
        canvas2:_setTool("eraser")
        check(#queue == 0, "tool switch should cancel stroke repaint, got " .. #queue)
        -- Manually fire a pending callback after close (extreme fallback): no error
        canvas2:onCloseWidget()
        local ok_cb = pcall(function()
            canvas2:_flushStrokeRepaint()
            canvas2:_maybeShowShapePreview()
        end)
        check(ok_cb, "callbacks after close should not throw")

        UIManager.scheduleIn = orig_scheduleIn
        UIManager.unschedule = orig_unschedule
    end)
    if ok then
        print("PASS: timer cancel-by-closure (no accumulation, close/tool-switch cancels)")
    else
        print("FAIL: timer cancel-by-closure:", tostring(err))
        os.exit(1)
    end
end

-- ============ 2. Element bbox cache ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 220, y = 360 } })
        canvas:_setTool("circle")
        canvas:onSwipe(nil, { pos = { x = 300, y = 300 }, end_pos = { x = 380, y = 360 } })
        canvas:_commitText(400, 300, "Test")
        check(#canvas.elements == 3, "setup elements, got " .. #canvas.elements)
        for _, el in ipairs(canvas.elements) do
            check(el._bbox ~= nil, "element missing _bbox: " .. tostring(el.kind))
            local b = canvas:_elementBBox(el)
            check(b and b.x0 == el._bbox.x0 and b.y0 == el._bbox.y0
                and b.x1 == el._bbox.x1 and b.y1 == el._bbox.y1,
                "cached bbox mismatch for " .. tostring(el.kind))
        end
        -- Tap-delete still hits after the bbox prefilter (pen-up point (220,360))
        canvas:_setTool("eraser")
        local hit = canvas:_eraseAt(220, 360)
        check(hit and #canvas.elements == 2, "eraseAt after bbox cache failed")
        print("bbox: 3 elements cached & consistent, eraseAt hit OK")
    end)
    if ok then
        print("PASS: element bbox cache")
    else
        print("FAIL: element bbox cache:", tostring(err))
        os.exit(1)
    end
end

-- ============ 3. Region redraw: pixel assertions ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas.width = 12
        -- Lower stroke A: y=300, black (grey 1.0)
        canvas.gray = 1.0
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 400, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 300 } })
        -- Upper stroke B: y=305, mid grey (grey 0.5)
        canvas.gray = 0.5
        canvas:onPan(nil, { pos = { x = 100, y = 305 }, start_pos = { x = 100, y = 305 } })
        canvas:onPan(nil, { pos = { x = 400, y = 305 }, start_pos = { x = 100, y = 305 } })
        canvas:onPanRelease(nil, { pos = { x = 400, y = 305 } })
        check(#canvas.elements == 2, "setup two strokes, got " .. #canvas.elements)
        local bb = canvas.canvas_bb
        local function a(y) return bb:getPixel(250, y) and bb:getPixel(250, y).a end
        -- Before deletion: overlap (302) = B's grey, B-only (308) = B grey, A-only (295) = black
        check(a(302) ~= 255 and a(302) ~= 0, "before: overlap should be B gray, got " .. tostring(a(302)))
        check(a(308) ~= 255 and a(308) ~= 0, "before: B-only should be gray, got " .. tostring(a(308)))
        check(a(295) == 0, "before: A-only should be black, got " .. tostring(a(295)))
        -- Point (250,308) lands only on B's ink -> delete B (keep A)
        canvas:_setTool("eraser")
        local hit = canvas:_eraseAt(250, 308)
        check(hit, "eraseAt should hit top stroke")
        check(#canvas.elements == 1, "should delete top stroke, got " .. #canvas.elements)
        -- After deletion: B-only turns white; the overlap restores lower A's black; A-only is still black
        check(a(308) == 255, "after: B-only should be white, got " .. tostring(a(308)))
        check(a(302) == 0, "after: overlap should restore bottom ink (black), got " .. tostring(a(302)))
        check(a(295) == 0, "after: A-only should still be black, got " .. tostring(a(295)))
        -- Undo: restore B, the overlap returns to B's grey
        canvas:_undo()
        check(#canvas.elements == 2, "undo should restore B")
        check(a(302) ~= 255 and a(302) ~= 0, "undo: overlap should be B gray again, got " .. tostring(a(302)))
        -- Redo: delete B again
        canvas:_redo()
        check(#canvas.elements == 1, "redo should delete B again")
        check(a(308) == 255 and a(302) == 0, "redo: B-only white, overlap black")
        print("redrawRegion pixels: overlap restores bottom ink, B-only clears, undo/redo consistent")
    end)
    if ok then
        print("PASS: region-limited redraw (pixels)")
    else
        print("FAIL: region-limited redraw:", tostring(err))
        os.exit(1)
    end
end

-- ============ 4. Stroke thinning + minimum step ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        local pts = {}
        for i = 1, 10000 do
            pts[i] = { x = i, y = math.floor(i / 10) }
        end
        local out = canvas:_thinPoints(pts)
        check(#out == 4096, "thin should cap at 4096, got " .. #out)
        check(out[1].x == 1 and out[#out].x == 10000, "thin should keep first/last")

        local canvas2 = newCanvas()
        canvas2:_setTool("brush")
        canvas2.width = 32 -- min_step = floor(32/8) = 4
        canvas2:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        for i = 101, 200 do -- 1px steps, 100 times
            canvas2:onPan(nil, { pos = { x = i, y = 300 }, start_pos = { x = 100, y = 300 } })
        end
        canvas2:onPanRelease(nil, { pos = { x = 200, y = 300 } })
        local s = canvas2.elements[1]
        check(s ~= nil and s.kind == "freehand", "stroke should commit")
        check(#s.points < 50, "min_step should cut dense points, got " .. #s.points)
        check(s.points[1].x == 100 and s.points[#s.points].x == 200, "first/last kept")
        print(string.format("thin: 10000->4096 first/last kept; min_step: 100 1px-steps -> %d points", #s.points))
    end)
    if ok then
        print("PASS: stroke thinning + min step")
    else
        print("FAIL: stroke thinning:", tostring(err))
        os.exit(1)
    end
end

-- ============ 5. Text nil-face guard ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        -- Nonexistent font: getFace returns nil, _drawTextTo should skip instead of throwing
        local ok1 = pcall(function()
            canvas:_drawTextTo(canvas.canvas_bb, {
                kind = "text", x = 10, y = 30, text = "abc",
                font = "no_such_font_xyz.ttf", size = 24, gray = 1.0,
            })
        end)
        check(ok1, "_drawTextTo with missing font should not throw")
        -- Text commit path (fired by the dialog button callback, already pcall-wrapped by wrapHandler): a missing font doesn't crash,
        -- the text element is still committed (drawing is skipped)
        canvas.font = "no_such_font_xyz.ttf"
        local ok2 = pcall(function()
            canvas:_commitText(50, 50, "Missing font test")
        end)
        check(ok2, "_commitText with missing font should not throw")
        check(#canvas.elements == 1 and canvas.elements[1].kind == "text",
            "text element should still commit")
        print("text nil-face guard OK (draw skipped, commit kept)")
    end)
    if ok then
        print("PASS: text missing-font guard")
    else
        print("FAIL: text missing-font guard:", tostring(err))
        os.exit(1)
    end
end

-- ============ 6. Save: same-second numbering + real PNG ============
do
    local ok, err = pcall(function()
        local canvas = newCanvas()
        canvas:_setTool("brush")
        canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
        canvas:onPan(nil, { pos = { x = 200, y = 350 }, start_pos = { x = 100, y = 300 } })
        canvas:onPanRelease(nil, { pos = { x = 220, y = 360 } })
        local lfs = require("libs/libkoreader-lfs")
        local dir = "/tmp/drawingpad_save_test"
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        -- Name clash numbering: pre-create a file with the same name, the next one should get _2
        local fname = "drawing_20260815_120000.png"
        local first = dir .. "/" .. fname
        local f = io.open(first, "wb")
        f:write("dummy")
        f:close()
        local p1 = canvas:_nextSavePath(dir, lfs, fname)
        check(p1 == dir .. "/drawing_20260815_120000_2.png",
            "same-name collision should get _2, got " .. p1)
        -- Real save: PNG magic check
        local target = dir .. "/drawing_real.png"
        local saved = canvas:_doSave(target)
        check(saved == target, "_doSave should return the path")
        local mf = io.open(saved, "rb")
        local magic = mf and mf:read(8)
        if mf then mf:close() end
        local expected = string.char(137, 80, 78, 71, 13, 10, 26, 10)
        check(magic == expected, "saved PNG magic mismatch")
        -- Save resolution = canvas (device screen) resolution, no white-margin cropping
        local mf2 = io.open(saved, "rb")
        local hdr = mf2 and mf2:read(24)
        if mf2 then mf2:close() end
        if hdr and #hdr >= 24 then
            local w = hdr:byte(17) * 16777216 + hdr:byte(18) * 65536 + hdr:byte(19) * 256 + hdr:byte(20)
            local h = hdr:byte(21) * 16777216 + hdr:byte(22) * 65536 + hdr:byte(23) * 256 + hdr:byte(24)
            check(w == canvas.canvas_w and h == canvas.canvas_h,
                string.format("saved PNG %dx%d should match screen %dx%d", w, h, canvas.canvas_w, canvas.canvas_h))
        else
            print("WARN: cannot read PNG dimensions, skip resolution assertion")
        end
        local crop = canvas:_contentBBox()
        check(crop ~= nil, "contentBBox should find content")
        -- Clean up
        os.remove(first)
        os.remove(saved)
        print(string.format("save: same-second numbering + PNG magic OK (crop %dx%d)", crop.w, crop.h))
    end)
    if ok then
        print("PASS: save flow")
    else
        print("FAIL: save flow:", tostring(err))
        os.exit(1)
    end
end

print("ALL STABILITY TESTS PASSED")
os.exit(0)
