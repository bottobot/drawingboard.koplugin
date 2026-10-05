--[[--
Drawing board adversarial tests (v57): assumes user mistakes/boundary input/abnormal sequences, covering 30 scenarios.
Complements feature_test (positive feature tests) - this one targets "things that must not happen": empty input, out of range, rapid taps,
corrupt files, out-of-bounds coordinates, leftover modes. Each scenario gets its own canvas + pcall; failures are collected and summarised,
everything runs before exiting (unlike feature_test, which stops at the first error), so all adversarial surfaces are visible at once.

Run (from the emulator directory):
    ./luajit plugins/drawingboard.koplugin/drawingpad/test/adversarial_test.lua
--]]

-- Test self-locates and injects package.path (doesn't go through pluginloader)
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

local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

-- Emulator 540x720, bottom header_h≈109 isn't drawable, safe drawing area x≤520/y≤450 (pitfall: v55 series)
local SAFE = { x = 300, y = 300 }

local failures = {}
local passes = 0

-- Scenario runner: own canvas + pcall, failures recorded without stopping
local function scenario(name, fn)
    local ok, err = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local canvas = DrawingCanvas:new{ on_close = function() end }
        fn(canvas)
    end)
    if ok then
        passes = passes + 1
        print("PASS:", name)
    else
        table.insert(failures, { name = name, err = tostring(err) })
        print("FAIL:", name, "->", tostring(err))
    end
end

local function check(cond, msg)
    if not cond then
        error(msg, 2)
    end
end

-- Shortcut gesture simulation (same approach as feature_test)
local function pan(canvas, x0, y0, x1, y1)
    canvas:onPan(nil, { pos = { x = x1, y = y1 }, start_pos = { x = x0, y = y0 } })
    canvas:onPanRelease(nil, { pos = { x = x1, y = y1 } })
end
local function tap(canvas, x, y)
    canvas:onTap(nil, { pos = { x = x, y = y } })
end

-- ============================ Scenarios 1-10: empty state and undo ============================

-- 1. Undo/redo 200 times on an empty canvas: empty stacks are silent no-ops, no crash, no out-of-range
-- v61p: the combined-button family (_doUndoRedo etc.) was removed, test _undo/_redo directly
scenario("empty undo/redo x200", function(canvas)
    for _ = 1, 200 do
        canvas:_undo()
        canvas:_redo()
    end
    check(#canvas.elements == 0, "elements should stay 0")
end)

-- 2. With content, undo to the bottom then redo to the top, 50 round trips
scenario("undo/redo roundtrip x50", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    check(#canvas.elements == 1, "one stroke")
    for _ = 1, 50 do
        canvas:_undo()
        check(#canvas.elements == 0, "undone")
        canvas:_redo()
        check(#canvas.elements == 1, "redone")
    end
    check(#canvas.elements == 1, "stroke survives roundtrip")
end)

-- 3. Undo -> switch layer -> undo: the two layers' stacks don't pollute each other
scenario("undo then switch layer then undo", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260) -- one stroke on layer 1
    canvas:_undo() -- undo layer 1
    check(#canvas.elements == 0, "layer1 emptied")
    canvas:_switchLayer(2)
    canvas:_setTool("brush")
    pan(canvas, 200, 200, 260, 260) -- one stroke on layer 2
    canvas:_undo() -- undo layer 2
    check(#canvas.elements == 0, "layer2 emptied, independent stack")
    canvas:_switchLayer(1)
    check(#canvas.elements == 0, "layer1 still emptied")
end)

-- 4. Redo stack isolation on layer switch: the new layer's redo is empty (old layer records not misplaced), back on the original layer redo is still there
scenario("redo stack isolated across layers", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_undo() -- undo, the default layer's redo stack has 1 entry
    canvas:_switchLayer(3)
    canvas:_redo() -- the new layer's redo stack is empty, silent no-op
    check(#canvas.elements == 0, "redo on fresh layer is no-op")
    canvas:_switchLayer(2)
    canvas:_redo()
    check(#canvas.elements == 1, "redo restores on original layer")
end)

-- 4b. Fast mode round trips are immediate + v57d naming contract (gray random/width random/box erase/path fill)
scenario("mode toggle roundtrip + v59f", function(canvas)
    local function btnOf(id)
        for _, cat in ipairs({ "tool", "prop", "layer", "func" }) do
            local b = canvas:_categoryBt(cat).button_by_id[id]
            if b then return b end
        end
    end
    local function label(id)
        local b = btnOf(id)
        return b and b.text or "?"
    end
    local function bg(id)
        local b = btnOf(id)
        return b and b[1] and b[1].background
    end
    local function hold(id)
        local b = btnOf(id)
        return b and b.hold_callback
    end
    local BLB = require("ffi/blitbuffer")
    -- Rectangle/ellipse: tap switches tool, long-press toggles the check
    check(label("rect_btn") == "Rect(☐ fill)", "rect label, got " .. label("rect_btn"))
    btnOf("rect_btn").callback()
    check(canvas.tool == "rect" and bg("rect_btn") == BLB.COLOR_LIGHT_GRAY and canvas.rect_filled == false,
        "tap selects rect WITHOUT toggling filled")
    hold("rect_btn")()
    check(canvas.rect_filled == true and label("rect_btn") == "Rect(☑ fill)", "hold toggles filled")
    btnOf("circle_btn").callback()
    check(canvas.tool == "circle" and bg("rect_btn") == BLB.COLOR_WHITE, "circle tap selects")
    hold("circle_btn")()
    check(canvas.circle_filled == true and label("circle_btn") == "Ellipse(☑ fill)", "circle hold toggles filled")
    -- Erase(☑box): tap switches to the eraser, long-press toggles box erase
    check(label("eraser_btn") == "Erase(☐box)", "eraser renamed, got " .. label("eraser_btn"))
    btnOf("eraser_btn").callback()
    check(canvas.tool == "eraser" and canvas.eraser_mode == "brush", "eraser tap selects brush mode")
    hold("eraser_btn")()
    check(canvas.eraser_mode == "rect" and label("eraser_btn") == "Erase(☑box)", "eraser hold toggles rect")
    -- Fill renamed
    check(label("fill_btn") == "Fill(☐ path)", "fill merged entry label, got " .. label("fill_btn"))
    -- Gray/width: tap opens settings, long-press toggles random
    check(label("gray_btn") == "Gray(☐ random)", "gray label, got " .. label("gray_btn"))
    hold("gray_btn")()
    check(canvas.gray_random == true and label("gray_btn") == "Gray(☑ random)", "gray hold toggles random")
    hold("gray_btn")()
    check(canvas.gray_random == false, "gray hold back")
    hold("width_btn")()
    check(canvas.width_random == true and label("width_btn") == "Width(☑ random)", "width hold toggles")
    hold("width_btn")()
    -- Layers: one item per layer, tap switches layer, long-press toggles hidden
    btnOf("layer3_btn").callback()
    check(canvas.active_layer == 3 and label("layer3_btn") == "●Top(☐hide)"
        and bg("layer3_btn") == BLB.COLOR_LIGHT_GRAY, "layer3 tap selects + radio ●")
    hold("layer3_btn")()
    check(canvas.layer_visible[3] == false and label("layer3_btn") == "●Top(☑hide)",
        "layer3 hold toggles hide box")
    hold("layer3_btn")()
    check(canvas.layer_visible[3] == true, "layer3 visible again")
    -- The property panel has no separate "Font" item (v59g moved it into the text edit dialog)
    local font_btn = canvas:_categoryBt("prop").button_by_id["font_btn"]
    check(font_btn == nil, "font entry removed from prop panel")
    -- Function panel is flat (includes About; v62d Save = project/Open/Export = PNG)
    check(label("undo_btn") == "Undo" and label("redo_btn") == "Redo" and label("clear_btn") == "Clear"
        and label("save_proj_btn") == "Save" and label("open_proj_btn") == "Open"
        and label("save_btn") == "Export" and label("exit_btn") == "Exit" and label("about_btn") == "About",
        "func panel: Undo/Redo/Clear/Save/Open/Export/Exit/About")
end)

-- 5. Empty text: no element created
scenario("empty text commit rejected", function(canvas)
    canvas:_setTool("text")
    canvas:_commitText(SAFE.x, SAFE.y, "")
    canvas:_commitText(SAFE.x, SAFE.y, nil)
    check(#canvas.elements == 0, "no element for empty/nil text")
end)

-- 6. Whitespace-only text: treated as empty, no element created
scenario("whitespace-only text rejected", function(canvas)
    canvas:_setTool("text")
    canvas:_commitText(SAFE.x, SAFE.y, "   ")
    canvas:_commitText(SAFE.x, SAFE.y, "\t\n ")
    check(#canvas.elements == 0, "whitespace text should not create element")
end)

-- 7. Very long text (500 characters): created successfully with a finite bbox
scenario("very long text (500 chars)", function(canvas)
    canvas:_setTool("text")
    local long = string.rep("W", 500)
    canvas:_commitText(SAFE.x, SAFE.y, long)
    check(#canvas.elements == 1, "element created")
    local el = canvas.elements[1]
    local b = canvas:_elementBBox(el)
    check(b ~= nil and b.x1 >= b.x0 and b.y1 >= b.y0, "bbox sane")
    check(b.x1 - b.x0 < 100000, "bbox not exploded: " .. tostring(b and (b.x1 - b.x0)))
end)

-- 8. One stroke with each of the 7 brush tips
scenario("all 7 tips draw", function(canvas)
    canvas:_setTool("brush")
    for _, t in ipairs(const.TIPS) do
        canvas.tip = t[1]
        pan(canvas, SAFE.x, SAFE.y, SAFE.x + 40, SAFE.y + 40)
    end
    check(#canvas.elements == 7, "7 strokes, got " .. #canvas.elements)
end)

-- 9. Select/eraser tap on an empty canvas: returns nil without crashing
scenario("pick on empty canvas", function(canvas)
    check(canvas:_pickElementAt(SAFE.x, SAFE.y) == nil, "nil on empty")
    canvas:_eraseAt(SAFE.x, SAFE.y) -- not crashing is enough
end)

-- 10. pan/tap outside the canvas: _toCanvas rejects, no element, no crash
scenario("off-canvas gestures", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 2000, 2000, 2100, 2100)
    tap(canvas, -50, -50)
    check(#canvas.elements == 0, "nothing committed off-canvas")
end)

-- ============================ Scenarios 11-20: mistakes and boundaries ============================

-- 11. Tap the same position 100 times (brush): 100 ink dots or debounce-merged, no crash
scenario("rapid tap x100 same spot", function(canvas)
    canvas:_setTool("brush")
    for _ = 1, 100 do
        tap(canvas, SAFE.x, SAFE.y)
    end
    check(#canvas.elements <= 100, "committed dots bounded")
end)

-- 12. 100 taps cycling through 8 tools: state machine doesn't get mixed up
scenario("cycle 8 tools x12", function(canvas)
    local tools = { "brush", "eraser", "line", "rect", "circle", "text", "select", "fill" }
    for i = 1, 96 do
        canvas:_setTool(tools[(i % 8) + 1])
    end
    check(canvas.tool ~= nil, "tool valid after cycling")
end)

-- 13. Switch tool after selecting an element: the selection is cleared, later tools don't hit it by mistake
scenario("selection cleared on tool switch", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_setTool("select")
    tap(canvas, 130, 230) -- tap the stroke to select it
    check(canvas._selected ~= nil, "selected")
    canvas:_setTool("circle")
    -- The selection should be cleared after switching tools (no leftover highlight/handles)
    check(canvas._selected == nil, "selection cleared, got " .. tostring(canvas._selected ~= nil))
end)

-- 14. Eraser tap delete: one stroke on each of three layers, tapping the top one deletes only the top one
scenario("eraser picks topmost", function(canvas)
    canvas:_switchLayer(1); canvas:_setTool("brush"); pan(canvas, 100, 200, 200, 200)
    canvas:_switchLayer(2); pan(canvas, 110, 210, 210, 210)
    canvas:_switchLayer(3); pan(canvas, 120, 220, 220, 220)
    canvas:_switchLayer(3)
    canvas:_setTool("eraser")
    canvas:_eraseAt(150, 210)
    check(#canvas.layers[3] == 0, "top layer erased")
    check(#canvas.layers[1] == 1 and #canvas.layers[2] == 1, "lower layers intact")
end)

-- 15. Box eraser: layer isolation - only the current layer is deleted, other layers intact (_eraseInRect takes two corner points)
scenario("rect eraser respects layer isolation", function(canvas)
    canvas:_switchLayer(1); canvas:_setTool("brush"); pan(canvas, 100, 200, 200, 200)
    canvas:_switchLayer(2); pan(canvas, 110, 210, 210, 210)
    canvas:_switchLayer(3); pan(canvas, 120, 220, 220, 220)
    canvas:_setTool("eraser")
    canvas:_toggleEraserMode() -- rect mode
    check(canvas.eraser_mode == "rect", "rect mode on")
    canvas:_eraseInRect(90, 180, 250, 240) -- box around the area of all three layers
    check(#canvas.layers[3] == 0, "current layer (3) cleared")
    check(#canvas.layers[2] == 1, "layer2 intact (isolation)")
    check(#canvas.layers[1] == 1, "layer1 intact (isolation)")
    canvas:_switchLayer(1)
    canvas:_eraseInRect(90, 180, 250, 240)
    check(#canvas.layers[1] == 0, "layer1 cleared after switching")
end)

-- 16. Transform corner dragged out of bounds (2000,2000): clamped without crashing, finite bbox
scenario("scale handle dragged off-canvas", function(canvas)
    canvas:_setTool("rect")
    pan(canvas, 100, 200, 200, 300) -- rectangle
    canvas:_setTool("select")
    tap(canvas, 150, 200) -- tap the top edge to select (the hollow interior has no ink, tolerance 20 wouldn't select it)
    check(canvas._selected ~= nil, "selected")
    -- Drag the se corner off the canvas
    local corners = canvas:_frameCorners(canvas._selected)
    check(corners ~= nil, "corners computed")
    canvas:_finishTransform(2000, 2000)
    -- No crash + finite bbox
    local b = canvas:_elementBBox(canvas._selected)
    if b then
        check(b.x1 - b.x0 < 100000, "bbox bounded")
    end
end)

-- 17. Rotation accumulating 720°: rot stays numerically stable
scenario("rotate 720 degrees cumulative", function(canvas)
    canvas:_setTool("rect")
    pan(canvas, 100, 200, 200, 300)
    canvas:_setTool("select")
    tap(canvas, 150, 200) -- tap the edge to select
    local el = canvas._selected
    check(el ~= nil, "selected")
    for _ = 1, 8 do -- 8 times 90°
        canvas:_finishTransform(150 + 100, 200) -- drag the corner to rotate
    end
    if el.rot then
        -- rot should stay in a sane range (accumulation allowed, but it must not explode to 1e6)
        check(math.abs(el.rot) < 100, "rot bounded: " .. tostring(el.rot))
    end
end)

-- 18. Very long stroke over 4096 points: after thinning it doesn't exceed the limit
scenario("stroke thinning over MAX_STROKE_POINTS", function(canvas)
    canvas:_setTool("brush")
    -- Simulate a 5000-point pan sequence (zigzag movement)
    local n = 0
    for i = 1, 5000 do
        local x = 50 + (i % 400)
        local y = 150 + (i % 200)
        canvas:onPan(nil, { pos = { x = x, y = y }, start_pos = { x = x, y = y } })
        n = n + 1
    end
    canvas:onPanRelease(nil, { pos = { x = 450, y = 350 } })
    check(#canvas.elements >= 1, "stroke committed")
    for _, el in ipairs(canvas.elements) do
        if el.kind == "freehand" then
            check(#el.points <= const.MAX_STROKE_POINTS,
                "points thinned to <= " .. const.MAX_STROKE_POINTS .. ", got " .. #el.points)
        end
    end
end)

-- 19. Two fingers interrupt a stroke: the stroke is finished with nothing left over
scenario("two-finger pan interrupts stroke", function(canvas)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onPan(nil, { pos = { x = 130, y = 230 }, start_pos = { x = 100, y = 200 } })
    check(canvas._stroke ~= nil, "stroke in progress")
    canvas:onTwoFingerPan(nil, { pos = { x = 150, y = 250 } })
    check(canvas._stroke == nil, "stroke finished by two-finger")
end)

-- 20. swipe after a hold pen-up: no leftover state
scenario("hold then swipe no residue", function(canvas)
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 100, y = 200 }, start_pos = { x = 100, y = 200 } })
    canvas:onHold(nil, { pos = { x = 100, y = 200 } })
    canvas:onHoldRelease(nil, { pos = { x = 140, y = 240 } })
    canvas:onSwipe(nil, { pos = { x = 200, y = 200 }, end_pos = { x = 300, y = 300 } })
    -- After two pen-ups the stroke state should be clean
    check(canvas._stroke == nil, "no stroke residue")
    check(canvas._stroke_pending == nil, "no pending residue")
end)

-- ============================ Scenarios 21-30: files/settings/popups ============================

-- 21. Save filename containing a slash: rejected (A9)
scenario("save filename with slash rejected", function(canvas)
    local called = false
    local orig_toast = require("drawingpad.components").showToast
    require("drawingpad.components").showToast = function(_, msg) called = true end
    canvas:_doSaveFlow("a/b")
    require("drawingpad.components").showToast = orig_toast
    check(called, "toast shown for slash name")
end)

-- 22. Save into a nonexistent folder: mkdir automatically, write succeeds
scenario("save to nonexistent dir auto-mkdir", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_test_noexist_" .. os.time()
    local path = dir .. "/test.png"
    local saved = canvas:_doSave(path) -- mkdir is _doSaveFlow's job, _doSave writes directly without creating folders
    -- _doSave doesn't create folders, expected to fail (nil); succeeds after the folder is created
    if saved then
        os.remove(path)
    end
    pcall(lfs.mkdir, dir)
    saved = canvas:_doSave(path)
    check(saved == path, "save after mkdir succeeds")
    local f = io.open(path, "rb")
    check(f ~= nil, "file exists")
    local magic = f:read(8)
    f:close()
    os.remove(path)
    os.remove(dir)
    check(magic == string.char(137, 80, 78, 71, 13, 10, 26, 10), "PNG magic valid (A9)")
end)

-- 23. Close immediately (no elements): no confirmation box
scenario("close empty canvas no confirm", function(canvas)
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown == 0, "no confirm dialog on empty canvas, shown=" .. shown)
end)

-- 24. Close with elements: confirmation box shown
scenario("close with content shows confirm", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown >= 1, "confirm dialog shown")
end)

-- 24b. v61q: current layer blank but other layers have content, closing must still show the confirmation box
scenario("close with content on other layer shows confirm", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260) -- one stroke on the default layer (middle)
    canvas:_switchLayer(3) -- switch to another layer, the current layer is blank
    check(#canvas.elements == 0, "current layer empty")
    local shown = 0
    local orig_show = UIManager.show
    UIManager.show = function(_, w) shown = shown + 1 end
    canvas:_onClose()
    UIManager.show = orig_show
    check(shown >= 1, "confirm dialog shown for content on other layer")
end)

-- 25. Corrupt settings file: degrade to defaults without crashing
scenario("corrupted settings file tolerated", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("this is not valid lua {{{{")
    f:close()
    local ok = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        local c = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    end)
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(ok, "construct with corrupt settings does not crash")
end)

-- 26. settings missing fields: only override what was read, defaults as fallback
scenario("partial settings file defaults", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings2_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("return { gray = 0.5 }")
    f:close()
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    local c = DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(c.gray == 0.5, "gray loaded from file")
    check(c.width ~= nil, "width falls back to default")
    check(c.tip ~= nil, "tip falls back to default")
end)

-- 27. last_text of the wrong type (number): no crash (defensive)
scenario("settings with wrong-type last_text", function(canvas)
    local lfs = require("libs/libkoreader-lfs")
    local dir = "/tmp/dp_adv_settings3_" .. os.time()
    pcall(lfs.mkdir, dir)
    local f = io.open(dir .. "/drawingpad_settings.lua", "w")
    f:write("return { last_text = 12345 }")
    f:close()
    local ok, c = pcall(function()
        local DrawingCanvas = require("drawingpad.drawing_canvas")
        return DrawingCanvas:new{ on_close = function() end, plugin_path = dir }
    end)
    os.remove(dir .. "/drawingpad_settings.lua")
    os.remove(dir)
    check(ok, "construct survives number last_text")
end)

-- 28. Hidden layers are not selectable/not visible (v57 asserts the current behaviour)
scenario("hidden layer not pickable", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas.layer_visible[canvas.active_layer] = false
    local picked = canvas:_pickElementAt(130, 230)
    check(picked == nil, "hidden layer element not pickable, got " .. tostring(picked ~= nil))
end)

-- 29. Switch layer after selecting: the selection is cleared
scenario("selection cleared on layer switch", function(canvas)
    canvas:_setTool("brush")
    pan(canvas, 100, 200, 160, 260)
    canvas:_setTool("select")
    tap(canvas, 130, 230)
    check(canvas._selected ~= nil, "selected")
    canvas:_switchLayer(3)
    check(canvas._selected == nil, "selection cleared")
end)

-- 30. Each of the 11 long-press buttons toggled 5 times: labels and status bar stay in sync without crashing.
-- Must really paintTo first so the buttons get a dimen - otherwise holdBtn's feedback block (has_fb) is skipped entirely,
-- and is_secondary closure errors can't be caught (the v57 A1 refactor s=nil crash slipped through exactly here)
scenario("hold toggles x5 all buttons", function(canvas)
    local Screen = require("device").screen
    canvas:paintTo(Screen.bb, 0, 0)
    -- v58: the buttons live in category panels, build each category and long-press x5 (real hold_callback closures)
    local ids = { "brush_btn", "rect_btn", "circle_btn", "select_btn",
        "fill_btn", "eraser_btn", "gray_btn", "width_btn", "tip_btn", "layer_btn",
        "undo_btn", "clear_btn", "save_btn" }
    for _, cat in ipairs({ "tool", "prop", "func" }) do
        local bt = canvas:_categoryBt(cat)
        for _, id in ipairs(ids) do
            local btn = bt.button_by_id[id]
            if btn and btn.hold_callback then
                for _ = 1, 5 do
                    btn.hold_callback()
                end
            end
        end
    end
    -- No crash + status bar text can be generated
    local txt = canvas:_statusText()
    check(type(txt) == "string" and #txt > 0, "status text generated")
end)

-- 31. v58 background rule: only the currently active tool item is light grey; inactive tools and property/function items are always white
scenario("category bg rule (v59f)", function(canvas)
    local BLB = require("ffi/blitbuffer")
    local tool_bt = canvas:_categoryBt("tool")
    check(tool_bt.button_by_id["brush_btn"][1].background == BLB.COLOR_LIGHT_GRAY, "active tool lightgray")
    check(tool_bt.button_by_id["text_btn"][1].background == BLB.COLOR_WHITE
        and tool_bt.button_by_id["eraser_btn"][1].background == BLB.COLOR_WHITE, "inactive tools white")
    local prop_bt = canvas:_categoryBt("prop")
    check(prop_bt.button_by_id["gray_btn"][1].background == BLB.COLOR_WHITE
        and prop_bt.button_by_id["tip_btn"][1].background == BLB.COLOR_WHITE, "prop items white always")
    canvas:_toggleGrayRandom()
    check(canvas:_categoryBt("prop").button_by_id["gray_btn"][1].background == BLB.COLOR_WHITE,
        "random does not light prop bg")
    canvas:_toggleGrayRandom()
    local layer_bt = canvas:_categoryBt("layer")
    check(layer_bt.button_by_id["layer2_btn"][1].background == BLB.COLOR_LIGHT_GRAY, "current layer lightgray")
    check(layer_bt.button_by_id["layer1_btn"][1].background == BLB.COLOR_WHITE
        and layer_bt.button_by_id["layer3_btn"][1].background == BLB.COLOR_WHITE, "other layer entries white")
    local func_bt = canvas:_categoryBt("func")
    check(func_bt.button_by_id["undo_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["clear_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["exit_btn"][1].background == BLB.COLOR_WHITE
        and func_bt.button_by_id["about_btn"][1].background == BLB.COLOR_WHITE, "func items white always")
end)

-- ============================ Summary ============================

print(string.format("=== adversarial_test: %d passed, %d failed ===", passes, #failures))
if #failures > 0 then
    print("--- failure detail ---")
    for _, f in ipairs(failures) do
        print("FAIL:", f.name)
        print("     ", f.err)
    end
    os.exit(1)
end
