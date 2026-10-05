--[[--
drawingpad.gestures - gesture entry-point methods (DrawingCanvas mixin module).
All tap/pan/swipe/hold gestures are dispatched from here to the brush/eraser/shape/select logic.
--]]

-- Self-locate: add this file's directory to package.path so require("shapes") works regardless of directory
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- Both same-directory short names (shapes/const) and the parent-directory drawingpad.* prefix resolve, regardless of where drawingpad lives
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

local M = {}

function M:onTap(_, ges)
    local committed = false -- whether the tap changed ink/objects (decides the pen-up full refresh; text popups/plain selection count as lightweight changes and don't refresh)
    if ges and ges.pos then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            if self.tool == "text" then
                self:_showTextDialog(x, y)
            elseif self.tool == "eraser" then
                -- Eraser tap: delete that object
                self:_eraseAt(x, y)
                committed = true
            elseif self.tool == "fill" then
                -- Tap fill: flood-fill the enclosed area at the tap point; stroke fill doesn't ink on a light tap (prevents stray dots from accidental touches),
                -- it only acts as a fallback to finish an in-progress stroke whose pen-up was missed (the degenerate path is erased by _commitFillPath without a trace)
                if self.fill_mode == "tap" then
                    self:_fillAt(x, y)
                    committed = true
                elseif self._stroke then
                    self:_finishStroke(nil)
                    committed = true
                end
            elseif self.tool == "brush" then
                -- Quick light tap: produce an ink dot (debounce doesn't block deliberate taps);
                -- if a previous gesture left an unfinished stroke, finish it at its last point first to avoid joining
                if self._stroke then
                    self:_finishStroke(nil)
                end
                self:_commitDot(x, y)
                committed = true
            elseif self.tool == "select" then
                -- Select/deselect; tapping an already selected object again toggles scale/rotate handles
                local el = self:_pickElementAt(x, y)
                if el and el == self._selected then
                    self._handle_mode = (self._handle_mode == "rotate") and "scale" or "rotate"
                    UIManager:setDirty(self, "partial", self:_handleRegion(el))
                else
                    self:_setSelected(el)
                end
            end
        end
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

function M:onPan(_, ges)
    if not ges or not ges.pos then
        return true
    end
    local tool = self.tool
    local brush_like = tool == "brush" or (tool == "fill" and self.fill_mode == "path")
    if brush_like or tool == "eraser" then
        if tool == "eraser" then
            if self.eraser_mode == "rect" then
                -- Rectangle box erase: dragging only records the anchor (0.5s grey box preview), pen-up deletes objects inside the box
                self:_trackShapeAnchor(ges)
            else
                -- Brush erase: dragging collects the path, pen-up deletes intersecting objects (no drawing, no refresh)
                self:_trackErasePath(ges)
            end
            return true
        end
        -- Brush pen-down debounce: record the touch-down point first (pending); no ink until movement reaches the threshold (absorbs pen-down jitter);
        -- once the threshold is reached the stroke formally starts, first point = touch-down point, drawing the "touch-down -> current point" segment
        -- Cross-gesture protection: an in-progress stroke exists but the touch-down point ≠ the stroke's first point = the previous gesture missed its pen-up
        -- (e.g. a two-finger interruption without pan_release); finish it at its last point first so the new stroke doesn't join the previous one's end
        if self._stroke and ges.start_pos then
            local first = self._stroke.points[1]
            if first and (ges.start_pos.x ~= first.x or ges.start_pos.y ~= first.y) then
                self:_finishStroke(nil)
            end
        end
        if not self._stroke and ges.start_pos then
            local sx, sy = self:_toCanvas(ges.start_pos.x, ges.start_pos.y)
            if sx and not self._stroke_pending then
                self._stroke_pending = { x = sx, y = sy, micro = {} }
            end
        end
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            if self._stroke then
                self:_extendStroke(x, y)
            elseif self._stroke_pending then
                local p = self._stroke_pending
                -- Record the micro-trace as early as possible: record whenever a pan event arrives and differs from the last point (even inside the PAN
                -- dead zone), preserving arc information at the stroke start, rendered as the complete starting path when the stroke starts
                local last_micro = p.micro[#p.micro] or p
                if #p.micro < 32 and (x ~= last_micro.x or y ~= last_micro.y) then
                    p.micro[#p.micro + 1] = { x = x, y = y }
                end
                -- Early trigger: the stroke formally starts once movement exceeds the EARLY_TRIGGER threshold; the smaller the threshold, the earlier,
                -- so small arcs at the start enter Catmull-Rom rendering sooner and keep their curvature (0 = start on the first point)
                if math.abs(x - p.x) >= const.STROKE_EARLY_TRIGGER_DIST
                    or math.abs(y - p.y) >= const.STROKE_EARLY_TRIGGER_DIST then
                    -- Movement exceeded the threshold: stroke start = touch-down point + micro-trace + current point, formed in one go
                    self._stroke_pending = nil
                    local points = { { x = p.x, y = p.y } }
                    for _, mp in ipairs(p.micro) do
                        points[#points + 1] = mp
                    end
                    self._stroke = {
                        kind = "freehand",
                        points = points,
                        gray = self:_resolveGray(),
                        alpha = self:_resolveAlpha(), blend = self.alpha_blend,
                        -- Stroke fill: outline fixed at 1px (only delimits the area, ignores the width setting)
                        width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                        tip = self.tip,
                    }
                    -- Stroke start: first merge the bounding box of what's already drawn (start dot/the first segment just rendered) into the accumulated region,
                    -- then "refresh the first segment immediately" (without waiting for the throttle window, reducing perceived start latency = responsiveness tweak).
                    -- The region must be merged here: without it, the region-less
                    -- setDirty(partial, nil) below is a full-screen refresh in KOReader - on the real device
                    -- this showed up as "a flash on fast pen-down" (slow pen-down starts via onHold, which has an if rx0 guard)
                    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
                    if rx0 then
                        self._stroke_region = self:_mergeRegions(self._stroke_region,
                            self:_dirtyRegion(rx0, ry0, rx1, ry1,
                                (self._stroke and self._stroke.width or 2) + 2))
                    end
                    self:_extendStroke(x, y)
                    self:_flushStrokeRepaint()
                end
            end
        end
    elseif tool == "line" or tool == "rect" or tool == "circle" then
        -- Shape tools: dragging only records the anchor and current point, no per-frame preview following the path;
        -- the shape is confirmed once on pen-up with the last updated point (faster display)
        self:_trackShapeAnchor(ges)
    elseif tool == "select" then
        -- Select first, then drag: on touch-down with a selected object, first check whether a transform handle was hit;
        -- hit a handle -> transform (scale/rotate), otherwise record the drag start point (move/copy on release)
        if self._selected and not self._select_drag and not self._transform then
            local sx, sy = self:_toCanvas(
                ges.start_pos and ges.start_pos.x or ges.pos.x,
                ges.start_pos and ges.start_pos.y or ges.pos.y)
            if sx then
                local handle = self:_hitHandle(sx, sy)
                if handle then
                    local el = self._selected
                    local b = el._bbox or self:_elementBBox(el)
                    self._transform = {
                        handle = handle,
                        x0 = sx, y0 = sy,
                        bbox = { x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1 },
                        old_region = self:_elementRegion(el),
                        orig = self:_cloneElement(el),
                    }
                else
                    self._select_drag = { x0 = sx, y0 = sy }
                end
            end
        elseif self._select_drag and not self._transform then
            -- Dragging: update the 0.5s rest drop-point preview (stop debounce; once shown it follows the finger live)
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_scheduleDragPreview(x, y)
            end
        elseif self._transform then
            -- Handle-drag transform (rotate/scale): show the preview after resting 0.5s, then follow the finger live (throttled/debounced)
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_scheduleDragPreview(x, y)
            end
        end
    end
    return true
end

-- v61r: automatic refresh on pen-up (all tools): after a stroke is committed, add one full-canvas partial (fast local waveform,
-- no flashing); v61s changed full to partial at the user's request - drives only changed pixels, no black flash from a full refresh,
-- while evening out the ghosting accumulated from per-segment partials during drawing; gestures that didn't commit ink don't trigger it
function M:_penUpRefresh()
    UIManager:setDirty(self, "partial")
end

function M:onPanRelease(_, ges)
    local committed = false -- whether this gesture committed ink/object changes (decides the pen-up full refresh)
    if self._stroke then
        if ges and ges.pos then
            local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
            if x then
                self:_finishStroke(x, y)
            else
                self:_finishStroke(nil)
            end
        else
            self:_finishStroke(nil)
        end
        committed = true
    elseif self._stroke_pending then
        -- Released before movement reached the debounce threshold: if there are several micro-trace points (a small arc drawn during debounce), commit a short stroke
        -- along the full trace so the small arc at the start isn't lost; single point/no micro-trace = quick light tap, still produces an ink dot
        local p = self._stroke_pending
        self._stroke_pending = nil
        if #p.micro >= 2 then
            local points = { { x = p.x, y = p.y } }
            for _, mp in ipairs(p.micro) do
                points[#points + 1] = mp
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(), blend = self.alpha_blend,
                width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
            end
            self:_finishStroke(nil)
        elseif self.tool ~= "fill" then
            -- Single point/no micro-trace = quick light tap: the brush still produces an ink dot; stroke fill doesn't ink (prevents accidental dots)
            self:_commitDot(p.x, p.y)
            committed = true
        end
    elseif self._shape_start then
        -- Shape tools / rectangle box erase: confirm once with the last updated point
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        if self.tool == "eraser" then
            self:_commitEraseRect(x, y)
        else
            self:_commitShape(x, y)
        end
        committed = true
    elseif self._erase_path then
        -- Brush erase: delete objects intersecting the path's bounding box
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_commitErasePath(x, y)
        committed = true
    elseif self._transform then
        -- Select tool transform: scale/rotate the selected object by dragging a handle
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_finishTransform(x, y)
        committed = true
    elseif self._select_drag then
        -- Select tool: on release, move/copy the selected object by the end-start displacement
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        self:_finishSelectDrag(x, y)
        committed = true
    elseif self.tool == "fill" and self.fill_mode == "tap" then
        -- Tap fill: when the gesture is classified as pan/hold (a tap with slight movement/rest), fill at the release point -
        -- onTap only covers the pure tap classification, otherwise "tap fill occasionally does nothing"
        local x, y
        if ges and ges.pos then
            x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        end
        if x then
            self:_fillAt(x, y)
            committed = true
        end
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

-- Two-finger gestures are ignored (no drawing, no conflict); but they interrupt an in-progress stroke and pan_release may never arrive afterwards,
-- so finish the stroke at its last point here to stop the next stroke from joining the previous one's end
function M:onTwoFingerPan()
    self:_finishStroke(nil)
    self:_penUpRefresh()
    return true
end

function M:onPinch()
    self:_finishStroke(nil)
    self:_penUpRefresh()
    return true
end

-- A fast drag is classified as swipe (not pan): shape tools confirm once from start -> end,
-- brush/eraser draw a quick straight line, avoiding "fast drawing does nothing".
-- Note: for swipe, pos = start point and end_pos = end point (opposite of pan semantics).
function M:onSwipe(_, ges)
    if not ges or not ges.pos then
        return true
    end
    -- The previous gesture may have ended as a swipe (pan_release not fired): shapes/eraser clear leftover anchors,
    -- the brush's in-progress stroke is finished at the end point below (not discarded, not joined)
    local pending = self._stroke_pending -- capture first: the debounce-period micro-trace is reused in the brush branch below
    self:_invalidateTasks()
    self._shape_start = nil
    self._erase_path = nil
    self._stroke_pending = nil
    self._select_drag = nil
    self._transform = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    self._shape_pos = nil
    local in_progress_stroke = self._stroke
    local px, py = ges.pos.x, ges.pos.y
    local ex = (ges.end_pos and ges.end_pos.x) or px
    local ey = (ges.end_pos and ges.end_pos.y) or py
    local sx, sy = self:_toCanvas(px, py)
    local x, y = self:_toCanvas(ex, ey)
    if not (sx and x) then
        -- swipe start/end outside the canvas: still need to finish the in-progress outline path,
        -- otherwise the fill is delayed until the next operation's pen-down (cross-gesture protection) triggers it
        if in_progress_stroke then
            self:_finishStroke(nil)
            self:_penUpRefresh()
        end
        return true
    end
    local tool = self.tool
    local committed = false
    if tool == "line" or tool == "rect" or tool == "circle" then
        -- Shape tools: start = anchor, end = swipe end point, confirm once
        self._shape_start = { x = sx, y = sy }
        self:_commitShape(x, y)
        committed = true
    elseif tool == "eraser" then
        -- Eraser: fast drag deletes objects intersecting the start -> end bounding box
        self:_eraseInRect(math.min(sx, x), math.min(sy, y), math.max(sx, x), math.max(sy, y))
        committed = true
    elseif tool == "fill" and self.fill_mode == "tap" then
        -- Tap fill: when a quick tap is classified as swipe, fill at the end point (prevents "tap fill occasionally does nothing")
        self:_fillAt(x, y)
        committed = true
    elseif tool == "brush" or (tool == "fill" and self.fill_mode == "path") then
        if in_progress_stroke then
            -- Fast finish: finish the in-progress stroke at the end point, avoiding discard/joined strokes;
            -- a stroke-fill path that ends with a swipe is still closed and filled inside _finishStroke
            self:_finishStroke(x, y)
            committed = true
        elseif pending and #(pending.micro or {}) >= 1 then
            -- Micro-trace already recorded during debounce (a fast small arc classified as swipe before reaching the start threshold):
            -- touch-down point + micro-trace + end point form the complete path that gets committed, preserving the start arc's curvature
            -- (the old version drew only a straight line between first and last, flattening the arc). Applies to stroke fill too: _finishStroke
            -- closes and fills internally, and a degenerate path automatically clears its ink without a trace
            local points = { { x = pending.x, y = pending.y } }
            for _, mp in ipairs(pending.micro) do
                points[#points + 1] = mp
            end
            local last_m = points[#points]
            if last_m.x ~= x or last_m.y ~= y then
                points[#points + 1] = { x = x, y = y }
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(), blend = self.alpha_blend,
                width = (tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
            end
            self:_finishStroke(nil)
            committed = true
        else
            if tool == "fill" then
                -- Pure fast stroke fill: a swipe has only 2 points (first and last), can't delimit a closed area, so ignore it
                return true
            end
            -- Pure fast straight line
            local stroke = {
                kind = "freehand",
                points = { { x = sx, y = sy }, { x = x, y = y } },
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(), blend = self.alpha_blend,
                width = self:_resolveWidth(),
                tip = self.tip,
            }
            shapes.thickLine(self:_alphaBB(self.canvas_bb, stroke), sx, sy, x, y,
                stroke.width, Blitbuffer.gray(stroke.gray), stroke.tip)
            table.insert(self.elements, stroke)
            self:_cacheBBox(stroke)
            self:_pushUndo({ kind = "add", el = stroke })
            self:_clearRedo()
            self:_log("commit swipe stroke", tool)
            UIManager:setDirty(self, "partial", self:_dirtyRegion(sx, sy, x, y, stroke.width + 2))
            committed = true
        end
    elseif tool == "select" then
        -- Select tool fast drag: move/copy the selected object by the start -> end displacement
        self:_applySelectDelta(math.floor(x - sx + 0.5), math.floor(y - sy + 0.5))
        committed = true
    end
    if committed then
        self:_penUpRefresh()
    end
    return true
end

-- multiswipe (replaces swipe when a fast flick changes direction): reuse the swipe logic to finish the stroke,
-- otherwise in-progress stroke-fill/brush strokes never get their finishing event and linger (swallowed by stop_events_propagation)
function M:onMultiSwipe(_, ges)
    return self:onSwipe(nil, ges)
end

-- A brief rest before pen-up is classified as a hold-family gesture (hold_pan/hold_release) rather than pan/pan_release;
-- forward them all to the pan logic so the previous stroke is committed and the next stroke doesn't join it
function M:onHoldPan(_, ges)
    return self:onPan(nil, ges)
end

function M:onHoldRelease(_, ges)
    return self:onPanRelease(nil, ges)
end

-- Held without moving (hold gesture, KOREADER threshold 0.5s):
-- brush: resting ≥0.5s at pen-down shows the start point (dot) - creates an in-progress stroke and draws the start point without committing,
-- further dragging (hold_pan) extends the same stroke, release commits it as a whole (without dragging it becomes a single dot);
-- if a stroke is already in progress, it is finished at the rest point first
function M:onHold(_, ges)
    if self._stroke then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        self:_finishStroke(x, y)
    elseif (self.tool == "brush" or (self.tool == "fill" and self.fill_mode == "path"))
        and ges and ges.pos then
        local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
        if x then
            -- Pen-down rest: the touch-down point (pending) becomes a real stroke; without pending use the rest point.
            -- The micro-trace recorded during debounce is carried over (start arc kept); create an in-progress stroke and
            -- render the existing points (single point = start dot, not committed to the element stack); subsequent hold_pan drags
            -- extend the same stroke, which is committed as a whole on pen-up
            local p = self._stroke_pending or { x = x, y = y, micro = {} }
            self._stroke_pending = nil
            local points = { { x = p.x, y = p.y } }
            for _, mp in ipairs(p.micro or {}) do
                points[#points + 1] = mp
            end
            self._stroke = {
                kind = "freehand",
                points = points,
                gray = self:_resolveGray(),
                alpha = self:_resolveAlpha(), blend = self.alpha_blend,
                -- Stroke fill: outline fixed at 1px (only delimits the area, ignores the width setting)
                width = (self.tool == "fill") and 1 or self:_resolveWidth(),
                tip = self.tip,
            }
            local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
            if rx0 then
                self._stroke_region = self:_mergeRegions(self._stroke_region,
                    self:_dirtyRegion(rx0, ry0, rx1, ry1, self._stroke.width + 2))
                self:_flushStrokeRepaint()
            end
        end
    end
    return true
end

-- Pen-down dead zone tuning (v56/v56b): the gesture detection layer only sends the first pan after moving PAN_THRESHOLD past touch-down
-- (arc information inside the dead zone is lost at the source = the main reason strokes couldn't start with a curve); hold is only sent after the finger stays
-- still for the hold interval (slow pen-downs wait 0.5s). While the board is open, two settings of the GestureDetector instance are adjusted dynamically:
--   PAN_THRESHOLD → scaleByDPI(GESTURE_PAN_THRESHOLD_DP)
--   ges_hold_interval → scaled proportionally (GESTURE_HOLD_INTERVAL_MS/500, independent of the time module/units)
-- Restored on close. KOReader source is untouched, gesture behaviour outside the board is unaffected.
-- require is inside the method (pcall-protected) to avoid load-order problems in headless tests / wbuilder scenarios
function M:_applyGestureTuning()
    local ok, gd = pcall(function()
        local Device = require("device")
        return Device.input and Device.input.gesture_detector or nil
    end)
    if not ok or not gd then return end
    -- Idempotent: repeated calls don't overwrite the saved original value (otherwise a second apply would save the "adjusted value" as the original)
    if gd._drawingpad_orig_pan_threshold == nil and gd._drawingpad_orig_hold_interval == nil then
        if type(gd.PAN_THRESHOLD) == "number" and gd.screen and gd.screen.scaleByDPI then
            gd._drawingpad_orig_pan_threshold = gd.PAN_THRESHOLD
            gd.PAN_THRESHOLD = gd.screen:scaleByDPI(const.GESTURE_PAN_THRESHOLD_DP)
        end
        if type(gd.ges_hold_interval) == "number" and gd.ges_hold_interval > 0 then
            gd._drawingpad_orig_hold_interval = gd.ges_hold_interval
            gd.ges_hold_interval = gd.ges_hold_interval
                * (const.GESTURE_HOLD_INTERVAL_MS / 500)
        end
    end
end

function M:_restoreGestureTuning()
    local ok, gd = pcall(function()
        local Device = require("device")
        return Device.input and Device.input.gesture_detector or nil
    end)
    if not ok or not gd then return end
    if gd._drawingpad_orig_pan_threshold ~= nil then
        gd.PAN_THRESHOLD = gd._drawingpad_orig_pan_threshold
        gd._drawingpad_orig_pan_threshold = nil
    end
    if gd._drawingpad_orig_hold_interval ~= nil then
        gd.ges_hold_interval = gd._drawingpad_orig_hold_interval
        gd._drawingpad_orig_hold_interval = nil
    end
end

return M
