--[[--
drawingpad.stylus - Kobo stylus (pen) support (DrawingCanvas mixin module).
Kobo fork, 2026-10 (Kobo Libra Colour + Kobo Stylus 2, KOReader >= 2026.07). Kept in its own module with small
hooks elsewhere so upstream merges stay easy:
- drawing_canvas.lua: mixes this module in, installs the finger filter, paintTo clip hook, settings defaults
- strokes.lua:  _extendStroke(x, y, f) per-point width factor, live refresh mode/interval/clip hooks
- shapes.lua:   per-point width (shapes.pointWidth) in crSegment/polyline
- actions.lua:  detach on onCloseWidget, Export folder for PNG export
- menus.lua:    Options panel items (Pressure sensitivity / Finger drawing / Export folder)

KOReader stylus API (frontend/device/input.lua): Input:registerStylusCallback(fn) / :unregisterStylusCallback().
On every SYN_REPORT, Input:routeStylusEvents() calls fn(input, slot) for each stylus MT slot
(slot.tool PEN=1 / ERASER=2 / HIGHLIGHTER=3, or slot.slot == input.pen_slot). The barrel button turns PEN into
ERASER while held. Returning true removes the slot from gesture detection. slot = {slot, id, x, y, tool, timev};
id == -1 means lifted/hovering. x/y are native portrait touch coordinates (the device adjust hooks already ran,
screen rotation is NOT applied), so they go through the gesture detector's own rotation mapping (_stylusToScreen).

Pressure is not stored in the slot: while the canvas is shown, a wrapper chained onto Device.input.eventAdjustHook
records ABS_MT_PRESSURE per MT slot (the exact previous hook is restored on close).

Old KOReader without the stylus API: nothing is registered and the pen keeps behaving like a finger (as before).
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")

local M = {}

-- ABS_MT_TOOL_TYPE values (input.lua TOOL_TYPE_*, literal fallbacks for cores that don't export them)
local TOOL_PEN, TOOL_ERASER, TOOL_HIGHLIGHTER = 1, 2, 3
pcall(function()
    local Input = require("device/input")
    TOOL_PEN = Input.TOOL_TYPE_PEN or TOOL_PEN
    TOOL_ERASER = Input.TOOL_TYPE_ERASER or TOOL_ERASER
    TOOL_HIGHLIGHTER = Input.TOOL_TYPE_HIGHLIGHTER or TOOL_HIGHLIGHTER
end)

-- linux/input.h codes (ffi/linux_input_h; literal fallbacks = the kernel ABI values)
local EV_ABS, ABS_MT_SLOT, ABS_MT_PRESSURE = 3, 47, 58
pcall(function()
    local C = require("ffi").C
    require("ffi/linux_input_h")
    EV_ABS, ABS_MT_SLOT, ABS_MT_PRESSURE = C.EV_ABS, C.ABS_MT_SLOT, C.ABS_MT_PRESSURE
end)

-- Monotonic milliseconds (palm-rejection window)
local time_ok, time = pcall(require, "ui/time")
local function nowMs()
    if time_ok and time and time.monotonic and time.to_ms then
        local ok, ms = pcall(function() return time.to_ms(time.monotonic()) end)
        if ok and type(ms) == "number" then
            return ms
        end
    end
    return os.time() * 1000
end

local FINGER_MODES = { auto = true, on = true, off = true }
local FINGER_NEXT = { auto = "on", on = "off", off = "auto" }

local function dbg(...)
    logger.dbg("drawingpad stylus:", ...)
end

-- ============================ Attach / detach ============================

-- Register the stylus callback and the pressure hook (called when the canvas is shown). Idempotent.
-- Feature-detects the API: without it the pen stays a finger (unchanged behaviour).
function M:_stylusAttach()
    if self._stylus_attached then
        return
    end
    local input = Device and Device.input
    if not (input and type(input.registerStylusCallback) == "function"
            and type(input.unregisterStylusCallback) == "function") then
        dbg("no stylus API in this KOReader, pen behaves like a finger")
        return
    end
    self._pen = { state = nil }
    self._finger_auto_off = false
    if not FINGER_MODES[self.finger_draw] then
        self.finger_draw = "auto"
    end

    -- Pressure hook: chain onto the instance's current eventAdjustHook (Input calls it as self:eventAdjustHook(ev)).
    -- prev_own = the instance's own field (nil = the class default is inherited), restored verbatim on detach.
    local ok_hook, err_hook = pcall(function()
        local hs = {
            active = true,
            cur_slot = input.cur_slot,
            p = {},       -- latest pressure per MT slot
            last = nil,   -- latest pressure on any slot (fallback)
            seen = false, -- any pressure event seen at all
            max = const.STYLUS_PRESSURE_MAX_START,
        }
        local prev_own = rawget(input, "eventAdjustHook")
        local prev_fn = input.eventAdjustHook
        local pressure_code = input.pressure_event or ABS_MT_PRESSURE
        local wrapper = function(this, ev)
            prev_fn(this, ev)
            if hs.active and ev ~= nil and ev.type == EV_ABS then
                local code = ev.code
                if code == ABS_MT_SLOT then
                    hs.cur_slot = ev.value
                elseif code == ABS_MT_PRESSURE or code == pressure_code then
                    local v = tonumber(ev.value)
                    if v then
                        if v > hs.max then
                            hs.max = v -- running max adapts upwards
                        end
                        hs.p[hs.cur_slot or -1] = v
                        hs.last = v
                        hs.seen = true
                    end
                end
            end
        end
        input.eventAdjustHook = wrapper
        self._pen_hook = hs
        self._pen_hook_wrapper = wrapper
        self._pen_hook_prev = prev_own
    end)
    if not ok_hook then
        logger.warn("drawingpad stylus: pressure hook not installed:", tostring(err_hook))
    end

    -- Stylus callback: errors never escape into Input (a throw there would break all input)
    local canvas = self
    local cb = function(inp, slot)
        local ok, ret = pcall(canvas._stylusOnSlot, canvas, inp, slot)
        if not ok then
            logger.warn("drawingpad stylus: callback error:", tostring(ret))
            pcall(canvas._stylusResetPen, canvas)
            return false
        end
        return ret == true
    end
    self._stylus_prev_cb = rawget(input, "stylus_callback")
    self._stylus_cb = cb
    self._stylus_input = input
    input:registerStylusCallback(cb)
    self._stylus_attached = true
    dbg("attached; pressure hook", ok_hook, "finger_draw", self.finger_draw,
        "pressure_sensitive", self.pressure_sensitive)
end

-- Unregister the callback and restore the exact previous eventAdjustHook. Idempotent, every step guarded:
-- called from onCloseWidget, and by the callback itself if it ever fires for a torn-down canvas.
function M:_stylusDetach()
    local input = self._stylus_input or (Device and Device.input)
    if self._stylus_attached then
        pcall(self._stylusResetPen, self)
    end
    self._stylus_attached = false
    if input and self._stylus_cb then
        local ok, err = pcall(function()
            if input.stylus_callback == self._stylus_cb then
                local prev = self._stylus_prev_cb
                if type(prev) == "function" then
                    input:registerStylusCallback(prev)
                else
                    input:unregisterStylusCallback()
                end
            end
        end)
        if not ok then
            logger.warn("drawingpad stylus: unregister failed:", tostring(err))
            input.stylus_callback = nil
        end
    end
    self._stylus_cb = nil
    self._stylus_prev_cb = nil
    if self._pen_hook then
        self._pen_hook.active = false -- even if the chain can't be unwound, our wrapper is now a pure pass-through
    end
    if input and self._pen_hook_wrapper then
        if input.eventAdjustHook == self._pen_hook_wrapper then
            input.eventAdjustHook = self._pen_hook_prev -- nil = back to the inherited Input:eventAdjustHook
        else
            -- Someone chained another hook on top of ours meanwhile: unwinding would drop theirs; leave the pass-through
            logger.warn("drawingpad stylus: eventAdjustHook was re-chained, leaving a pass-through wrapper")
        end
    end
    self._pen_hook_wrapper = nil
    self._pen_hook_prev = nil
    self._stylus_input = nil
    dbg("detached")
end

-- Shown: attach (Show is sent by UIManager:show; not consumed, so return nothing)
function M:onShow()
    local ok, err = pcall(self._stylusAttach, self)
    if not ok then
        logger.warn("drawingpad stylus: attach failed:", tostring(err))
        pcall(self._stylusDetach, self)
    end
end

-- Suspend: finish a pen stroke that is still in flight (no lift event will come); stay attached (the canvas stays open)
function M:onSuspend()
    local ok, err = pcall(function()
        local st = self._pen
        if st and st.state == "own" then
            self:_stylusUp()
        end
        self:_stylusResetPen()
    end)
    if not ok then
        logger.warn("drawingpad stylus: suspend cleanup failed:", tostring(err))
    end
end

-- Drop all per-contact pen state (does not commit anything)
function M:_stylusResetPen()
    local st = self._pen
    if st then
        if st.saved_tool then
            self.tool = st.saved_tool
        end
        st.state = nil
        st.mode = nil
        st.saved_tool = nil
        st.moved = false
    end
    self._live_refresh_mode = nil
    self._live_refresh_interval = nil
    self._pen_clip_paint = nil
    self._stylus_synth = false
end

-- ============================ Geometry ============================

-- Pen touch coordinates (native portrait) -> screen coordinates in the current rotation.
-- Uses the gesture detector's own adjustGesCoordinate on a synthetic "tap" (exactly what finger gestures go through);
-- fallback = a copy of GestureDetector:translateCoordinates.
function M:_stylusToScreen(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    local input = Device.input
    local gd = input and input.gesture_detector
    if gd and type(gd.adjustGesCoordinate) == "function" then
        local ges = { ges = "tap", pos = { x = x, y = y } }
        local ok = pcall(gd.adjustGesCoordinate, gd, ges)
        if ok and ges.pos and type(ges.pos.x) == "number" then
            return ges.pos.x, ges.pos.y
        end
    end
    local screen = (gd and gd.screen) or Device.screen
    local mode = screen:getTouchRotation()
    if mode == screen.DEVICE_ROTATED_CLOCKWISE then
        return screen:getWidth() - y, x
    elseif mode == screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        return y, screen:getHeight() - x
    elseif mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return screen:getWidth() - x, screen:getHeight() - y
    end
    return x, y
end

-- The canvas is the topmost non-toast window (popups/dialogs/keyboard/PathChooser on top get the pen as a finger)
function M:_stylusCanvasOnTop()
    local stack = UIManager._window_stack
    if type(stack) == "table" then
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and not w.toast and not w.invisible then
                return w == self
            end
        end
        return false
    end
    return UIManager:getTopmostVisibleWidget() == self
end

-- Screen point is on a toolbar control (minimised restore button; the toolbar strip is already excluded by _toCanvas)
function M:_stylusOnControl(x, y)
    if self._minimized and self.restore_btn then
        local d = self.restore_btn.dimen
        if d and d.x and d.y and d.w and d.h then
            return x >= d.x and x < d.x + d.w and y >= d.y and y < d.y + d.h
        end
        -- Not painted yet: it sits in the bottom-left corner (see paintTo)
        local ok, size = pcall(function() return self.restore_btn:getSize() end)
        if ok and size and size.w and size.h then
            return x < size.w and y >= (self.canvas_h or 0) - size.h
        end
    end
    return false
end

-- Normalised pressure (0..1) -> width factor (MIN..1), or nil when this device reports no pressure
function M:_stylusPressureFactor(slot)
    local hs = self._pen_hook
    if not hs or not hs.seen then
        return nil
    end
    local v = slot and hs.p[slot.slot]
    if v == nil then
        v = hs.last
    end
    if v == nil then
        return nil
    end
    local maxv = math.max(const.STYLUS_PRESSURE_MAX_FLOOR, hs.max)
    local p = math.max(0, math.min(1, v / maxv))
    local mf = const.STYLUS_PRESSURE_MIN_FACTOR
    return math.floor((mf + (1 - mf) * p) * 100 + 0.5) / 100
end

-- ============================ Palm rejection ============================

function M:_stylusFingerMode()
    local m = self.finger_draw
    return FINGER_MODES[m] and m or "auto"
end

function M:_stylusFingerDrawingOn()
    local m = self:_stylusFingerMode()
    return m == "on" or (m == "auto" and not self._finger_auto_off)
end

-- Any pen event while the canvas is on top (hover included): starts the palm window, auto mode turns finger drawing off
function M:_stylusNoteActivity()
    local st = self._pen
    st.last_ms = nowMs()
    if not self._finger_auto_off and self:_stylusFingerMode() == "auto" then
        self._finger_auto_off = true
        dbg("first pen event: finger drawing off (auto)")
    end
    -- A finger (palm) operation still in flight when the pen arrives is closed now (its release will be ignored)
    if self._stroke or self._stroke_pending or self._shape_start or self._erase_path
            or self._select_drag or self._transform then
        self:_stylusCancelFingerOps()
    end
end

-- Should a finger gesture on the canvas be ignored? (the toolbar/panels/menus are separate widgets and never get here)
function M:_stylusBlocksFinger()
    if self._stylus_synth then
        return false -- our own synthesized gesture (pen driving a non-brush tool)
    end
    local st = self._pen
    if not (st and self._stylus_attached) then
        return false -- no stylus support: fingers work as before
    end
    if st.state == "own" then
        return true
    end
    if not self:_stylusFingerDrawingOn() then
        return true
    end
    if st.last_ms and nowMs() - st.last_ms < const.STYLUS_PALM_WINDOW_MS then
        return true
    end
    -- A finger gesture goes through: no pen-only refresh state may leak into the finger path
    self._live_refresh_mode = nil
    self._live_refresh_interval = nil
    self._pen_clip_paint = nil
    return false
end

-- Close whatever a finger left in progress (commit a live stroke so canvas ink and elements stay consistent; drop the rest)
function M:_stylusCancelFingerOps()
    if self._stroke then
        self:_finishStroke(nil)
    end
    self._stroke_pending = nil
    if self._shape_start or self._shape_preview_region or self.preview then
        local reg = self._shape_preview_region
        self._shape_start = nil
        self:_cancelShapePreview()
        self._shape_preview_region = nil
        self._shape_pos = nil
        if reg then
            UIManager:setDirty(self, "partial", reg)
        end
    end
    self._erase_path = nil
    if self._select_drag or self._transform or self._drag_preview then
        local reg = self._drag_preview_region
        self:_invalidateTasks()
        self._select_drag = nil
        self._transform = nil
        if reg then
            UIManager:setDirty(self, "partial", reg)
        end
    end
end

-- Wrap the canvas gesture handlers with the palm filter (called once on the class, before the pcall wrappers)
local FINGER_HANDLERS = {
    "onTap", "onPan", "onPanRelease", "onSwipe", "onMultiSwipe",
    "onHold", "onHoldPan", "onHoldRelease", "onTwoFingerPan", "onPinch",
}
function M.installFingerFilter(Class)
    for _, name in ipairs(FINGER_HANDLERS) do
        local orig = Class[name]
        if type(orig) == "function" then
            Class[name] = function(self, arg, ges, ...)
                if self._stylusBlocksFinger and self:_stylusBlocksFinger() then
                    return true
                end
                return orig(self, arg, ges, ...)
            end
        end
    end
end

-- ============================ Pen contact ============================

-- Input callback: return true to take the slot away from gesture detection
function M:_stylusOnSlot(input, slot)
    local st = self._pen
    if not (st and self._stylus_attached) or type(slot) ~= "table" then
        return false
    end
    if not self.canvas_bb then
        -- Torn down without onCloseWidget reaching us: self-heal instead of leaking
        self:_stylusDetach()
        return false
    end
    local id = slot.id
    local contact = type(id) == "number" and id >= 0
    local pen_tool = slot.tool == TOOL_PEN or slot.tool == TOOL_ERASER or slot.tool == TOOL_HIGHLIGHTER
    if st.state == "own" and slot.slot ~= st.slot then
        return false -- some other slot while our contact is live
    end
    if not pen_tool and st.state ~= "own" then
        -- routeStylusEvents also forwards input.pen_slot regardless of tool: a finger/palm that lands in that
        -- MT slot (tool FINGER) is not a pen. (Our own contact is still followed: on Wacom-protocol devices
        -- the lift frame reports tool FINGER.)
        if st.state == "declined" and not contact then
            st.state = nil
        end
        return false
    end
    if pen_tool and slot.tool ~= st.hw_tool then
        dbg("tool change", st.hw_tool, "->", slot.tool, "slot", slot.slot,
            "(1=pen 2=eraser/button 3=highlighter)")
        st.hw_tool = slot.tool
    end
    if st.state == "own" then
        st.last_ms = nowMs()
        if contact then
            self:_stylusMove(slot)
        else
            self:_stylusUp()
        end
        return true
    elseif st.state == "declined" then
        if not contact then
            st.state = nil
        end
        return false
    end
    -- Idle: hover, or a new contact
    local on_top = self:_stylusCanvasOnTop()
    if on_top then
        self:_stylusNoteActivity()
    end
    if not contact then
        return false
    end
    if not on_top then
        st.state = "declined" -- a popup/dialog is on top: the pen acts as a finger there for this whole contact
        return false
    end
    local x, y = self:_stylusToScreen(slot.x, slot.y)
    local cx, cy
    if x and not self:_stylusOnControl(x, y) then
        cx, cy = self:_toCanvas(x, y)
    end
    if not cx then
        st.state = "declined" -- toolbar/status bar/restore button: let gesture detection turn it into a tap
        dbg("down outside the canvas, left to gestures", x, y)
        return false
    end
    self:_stylusDown(slot, cx, cy)
    return true
end

function M:_stylusDown(slot, x, y)
    local st = self._pen
    if self._stroke or self._stroke_pending or self._shape_start or self._erase_path
            or self._select_drag or self._transform then
        self:_stylusCancelFingerOps()
    end
    -- Barrel button (ERASER) = the existing eraser for this stroke only; HIGHLIGHTER behaves like the pen for now
    local eff = self.tool
    if slot.tool == TOOL_ERASER then
        eff = "eraser"
    end
    st.state = "own"
    st.slot = slot.slot
    st.sx, st.sy = x, y
    st.lx, st.ly = x, y
    st.moved = false
    st.saved_tool = nil
    st.last_ms = nowMs()
    st.stack_n = type(UIManager._window_stack) == "table" and #UIManager._window_stack or nil
    if eff == "brush" or (eff == "fill" and self.fill_mode == "path") then
        -- Same stroke pipeline as the finger pan path (renderStrokeTail/_extendStroke/_finishStroke), minus the
        -- finger debounce (the pen is precise): layers/undo/opacity/blend/tips all behave identically
        st.mode = "stroke"
        st.use_pressure = eff == "brush" and self.pressure_sensitive ~= false
            and self._pen_hook ~= nil and self._pen_hook.seen
        local f = st.use_pressure and self:_stylusPressureFactor(slot) or nil
        self._stroke = {
            kind = "freehand",
            points = { { x = x, y = y, f = f } },
            gray = self:_resolveGray(),
            alpha = self:_resolveAlpha(), blend = self.alpha_blend,
            width = (eff == "fill") and 1 or self:_resolveWidth(), -- stroke fill outline is always 1px
            tip = self.tip,
        }
        self._live_refresh_mode = const.STYLUS_LIVE_REFRESH_MODE
        self._live_refresh_interval = const.STYLUS_REFRESH_INTERVAL
        local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
        if rx0 then
            self._stroke_region = self:_mergeRegions(self._stroke_region,
                self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
        end
        self:_flushStrokeRepaint()
        dbg("down", x, y, "tool", eff, "hw", slot.tool, "width", self._stroke.width, "f", f)
    else
        -- Every other tool: drive the existing gesture handlers with synthesized tap/pan/pan_release
        st.mode = "gesture"
        if eff ~= self.tool then
            st.saved_tool = self.tool
            self.tool = eff
        end
        dbg("down", x, y, "tool", eff, "hw", slot.tool, "(gesture mode)")
    end
end

function M:_stylusMove(slot)
    local st = self._pen
    local x, y = self:_stylusToScreen(slot.x, slot.y)
    if not x then
        return
    end
    if st.mode == "stroke" then
        if not self._stroke then
            return
        end
        local cx, cy = self:_toCanvas(x, y)
        if not cx then
            return -- over the toolbar: skip the point, the stroke continues when the pen comes back
        end
        st.lx, st.ly = cx, cy
        local f = st.use_pressure and self:_stylusPressureFactor(slot) or nil
        self:_extendStroke(cx, cy, f)
    elseif st.mode == "gesture" then
        st.lx, st.ly = x, y
        if not st.moved then
            local slop = Device.screen:scaleBySize(const.STYLUS_TAP_SLOP)
            if math.abs(x - st.sx) < slop and math.abs(y - st.sy) < slop then
                return
            end
            st.moved = true
        end
        self:_stylusSynth("onPan", { ges = "pan", pos = { x = x, y = y }, start_pos = { x = st.sx, y = st.sy } })
    end
end

function M:_stylusUp()
    local st = self._pen
    if st.mode == "stroke" then
        self._live_refresh_mode = nil
        self._live_refresh_interval = nil
        self._pen_clip_paint = nil
        local s = self._stroke
        local region = s and self:_strokeRegion(s)
        if s then
            self:_finishStroke(nil)
        end
        -- One quality refresh of the whole stroke bbox (the live frames used the fast waveform)
        if region then
            UIManager:setDirty(self, const.STYLUS_FINAL_REFRESH_MODE, region)
        end
        dbg("up", st.lx, st.ly, "points", s and #s.points)
    elseif st.mode == "gesture" then
        if st.moved then
            self:_stylusSynth("onPanRelease", { ges = "pan_release", pos = { x = st.lx, y = st.ly } })
        else
            self:_stylusSynth("onTap", { ges = "tap", pos = { x = st.sx, y = st.sy } })
        end
        if st.saved_tool then
            self.tool = st.saved_tool
            st.saved_tool = nil
        end
        dbg("up", st.lx, st.ly, "tool", self.tool, st.moved and "(drag)" or "(tap)")
    end
    st.state = nil
    st.mode = nil
    st.moved = false
    st.last_ms = nowMs()
end

-- Call a gesture handler on behalf of the pen (bypasses the palm filter)
function M:_stylusSynth(name, ges)
    local fn = self[name]
    if type(fn) ~= "function" then
        return
    end
    self._stylus_synth = true
    local ok, err = pcall(fn, self, nil, ges)
    self._stylus_synth = false
    if not ok then
        logger.warn("drawingpad stylus:", name, "failed:", tostring(err))
    end
end

-- paintTo hook: during a live pen stroke only the dirty rectangle is re-blitted (the full canvas blit per frame
-- costs more than the stroke itself). Falls back to the full paint whenever anything else could be on screen there.
function M:_stylusClipPaint(bb, x, y)
    local r = self._pen_clip_paint
    self._pen_clip_paint = nil
    if not (const.STYLUS_CLIP_PAINT and r and self.canvas_bb) then
        return false
    end
    local st = self._pen
    if not (st and st.state == "own" and st.mode == "stroke" and self._live_refresh_mode) then
        return false
    end
    if self.preview or self._drag_preview or self._selected or self._minimized then
        return false
    end
    -- A window opened/closed since pen-down (e.g. a toast timing out) may need the full canvas repainted
    if st.stack_n == nil or type(UIManager._window_stack) ~= "table" or #UIManager._window_stack ~= st.stack_n then
        return false
    end
    -- Must not touch the toolbar/status strip at the bottom
    if r.x < 0 or r.y < 0 or r.x + r.w > self.canvas_w or r.y + r.h > self.canvas_h - (self.header_h or 0) then
        return false
    end
    bb:blitFrom(self.canvas_bb, x + r.x, y + r.y, r.x, r.y, r.w, r.h)
    return true
end

-- ============================ Settings / menu ============================

-- PNG export folder (Export folder setting; "" = default koreader/drawingboard)
function M:_exportFolder()
    local f = self.export_folder
    if type(f) == "string" and f ~= "" then
        return f
    end
    return DataStorage:getDataDir() .. "/drawingboard"
end

-- Refresh the open Options panel after a toggle (labels come from text_fn)
function M:_stylusRefreshPanel()
    self:_syncToolLabels()
    local p = self._category_popup
    if p then
        if p[1] and p[1].dimen then
            UIManager:setDirty(p, "ui", p[1].dimen)
        else
            UIManager:setDirty(p, "partial")
        end
    end
end

function M:_toggleStylusPressure()
    self.pressure_sensitive = not (self.pressure_sensitive ~= false)
    dbg("pressure sensitivity", self.pressure_sensitive)
    self:_stylusRefreshPanel()
end

function M:_cycleFingerDraw()
    self.finger_draw = FINGER_NEXT[self:_stylusFingerMode()] or "auto"
    dbg("finger drawing", self.finger_draw, "auto_off", self._finger_auto_off)
    self:_stylusRefreshPanel()
end

function M:_fingerDrawLabel()
    local m = self:_stylusFingerMode()
    local txt = L.t("Finger drawing: ") .. L.t(m)
    if m == "auto" and self._finger_auto_off then
        txt = txt .. L.t(" (off)")
    end
    return txt
end

-- Pick the Export folder (KOReader PathChooser: long-press a folder to choose it). Choosing it also resets the
-- per-dialog save folder so the next PNG export lands there.
function M:_pickExportFolder()
    local lfs = require("libs/libkoreader-lfs")
    local start = self:_exportFolder()
    if lfs.attributes(start, "mode") ~= "directory" then
        pcall(lfs.mkdir, start)
        if lfs.attributes(start, "mode") ~= "directory" then
            start = DataStorage:getDataDir()
        end
    end
    local function apply(path)
        if type(path) ~= "string" or path == "" then
            return
        end
        path = path:gsub("/+$", "")
        if path == "" then
            path = "/"
        end
        self.export_folder = (path == DataStorage:getDataDir() .. "/drawingboard") and "" or path
        self.save_folder = ""
        dbg("export folder", self:_exportFolder())
        self:_saveSettings()
        local components = require("drawingpad.components")
        components.showToast(L.t("Export folder:") .. "\n" .. self:_exportFolder(), 3)
    end
    local ok, err = pcall(function()
        local PathChooser = require("ui/widget/pathchooser")
        UIManager:show(PathChooser:new{
            select_directory = true,
            select_file = false,
            show_files = false,
            path = start,
            onConfirm = apply,
        })
    end)
    if not ok then
        -- Fallback: type the path
        logger.warn("drawingpad stylus: PathChooser failed:", tostring(err))
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = L.t("Export folder"),
            input = self:_exportFolder(),
            buttons = { {
                { text = L.t("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = L.t("Use this folder"), is_enter_default = true,
                  callback = function()
                      local path = dlg:getInputText()
                      UIManager:close(dlg)
                      if lfs.attributes(path, "mode") ~= "directory" then
                          pcall(lfs.mkdir, path)
                      end
                      if lfs.attributes(path, "mode") == "directory" then
                          apply(path)
                      end
                  end },
            } },
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end
end

return M
