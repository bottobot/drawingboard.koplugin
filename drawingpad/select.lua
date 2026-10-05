--[[--
drawingpad.select - object selection (move/copy) and transform (scale/rotate handles) methods (DrawingCanvas mixin module).
--]]

local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local const = require("drawingpad.const")

local M = {}

-- ============================ Object selection (move/copy) ============================

-- Long-press the select button: toggle move/copy mode (button text and status bar follow)
function M:_toggleSelectMode()
    self.select_mode = (self.select_mode == "move") and "copy" or "move"
    self:_syncToolLabels()
    self:_log("select_mode ->", self.select_mode)
    self:_updateStatus()
end

-- Set/clear the selected object (updates the highlight refresh region).
-- When the selected object changes, handles return to scale mode (only tapping the same object again toggles scale/rotate)
function M:_setSelected(el)
    if self._selected == el then
        return
    end
    local old = self._selected
    self._selected = el
    self._handle_mode = "scale"
    local region = nil
    if old then
        region = self:_mergeRegions(region, self:_elementRegion(old))
    end
    if el then
        region = self:_mergeRegions(region, self:_elementRegion(el))
    end
    UIManager:setDirty(self, "partial", region)
end

-- Full refresh region for the selection handles: bbox expanded by handle half-width + pad (about 12px), so that when toggling scale/rotate styles
-- the handle pixels are refreshed too (_elementRegion only covers bbox±4, drawing handles would leave ghosting)
function M:_handleRegion(el)
    local b = el._bbox or self:_elementBBox(el)
    if not b then
        return nil
    end
    local margin = 4 + Screen:scaleBySize(6) + 2
    local rx0 = math.max(0, math.floor(b.x0) - margin)
    local ry0 = math.max(0, math.floor(b.y0) - margin)
    local rx1 = math.min(self.canvas_w, math.ceil(b.x1) + margin)
    local ry1 = math.min(self.canvas_h, math.ceil(b.y1) + margin)
    if rx1 <= rx0 or ry1 <= ry0 then
        return nil
    end
    return Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 }
end

-- Apply move/copy by a displacement (shared by select-tool pen-up and fast drag)
function M:_applySelectDelta(dx, dy)
    local el = self._selected
    if not el or (dx == 0 and dy == 0) then
        return
    end
    if self.select_mode == "copy" then
        -- Copy: clone -> translate -> push onto the stack, original object untouched
        local copy = self:_cloneElement(el)
        self:_moveElement(copy, dx, dy)
        table.insert(self.elements, copy)
        self:_cacheBBox(copy)
        self:_pushUndo({ kind = "add", el = copy })
        self:_clearRedo()
        local region = self:_elementRegion(copy)
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
        self:_log("select copy", el.kind, dx, dy)
    else
        -- Move: record the old region first, after translating redraw old ∪ new (restores the underlying ink in the old region)
        local old_region = self:_elementRegion(el)
        self:_moveElement(el, dx, dy)
        self:_cacheBBox(el)
        local region = self:_mergeRegions(old_region, self:_elementRegion(el))
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
        self:_pushUndo({ kind = "move", el = el, dx = dx, dy = dy })
        self:_clearRedo()
        self:_log("select move", el.kind, dx, dy)
    end
end

-- Select-tool pen-up: move/copy the selected object by the drag end-start displacement.
-- First cancel the preview and erase its accumulated region (intermediate positions during preview following must be refreshed too, to prevent leftovers)
function M:_finishSelectDrag(x, y)
    self:_cancelDragPreview()
    local prev_region = self._drag_preview_region
    self._drag_preview_region = nil
    local drag = self._select_drag
    self._select_drag = nil
    if not (drag and x) then
        -- No move happened (released outside the canvas, etc.): erase the leftover preview already shown
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    self:_applySelectDelta(math.floor(x - drag.x0 + 0.5), math.floor(y - drag.y0 + 0.5))
    if prev_region then
        UIManager:setDirty(self, "partial", prev_region)
    end
end

-- ============================ Drag preview (move/rotate/scale) ============================
-- Two stages: ① shown for the first time only after the finger rests for MOVE_PREVIEW_DELAY (0.2s, uniform for all objects including text) (stop-position debounce);
-- ② once shown, subsequent pans update it live following the finger (no longer erased on each move, eliminating flicker/jitter),
-- redraws are throttled with merged regions per DRAG_PREVIEW_REFRESH_INTERVAL (e-ink doesn't refresh per event, prevents stutter).
-- Drag the body -> drop preview; drag a handle in rotate mode -> rotate preview; drag a handle in scale mode -> stretch preview.

-- Called on each pan: if the preview isn't shown yet, reschedule the first-display timer; if shown, follow and update live
function M:_scheduleDragPreview(x, y)
    if self._drag_preview then
        self:_updateDragPreview(x, y)
        return
    end
    if self._drag_preview_fn then
        UIManager:unschedule(self._drag_preview_fn)
        self._drag_preview_fn = nil
    end
    self._drag_preview_pos = { x = x, y = y }
    local fn = function()
        self:_maybeShowDragPreview()
    end
    self._drag_preview_fn = fn
    UIManager:scheduleIn(const.MOVE_PREVIEW_DELAY, fn)
end

-- Build the preview element for the current drag type (clone of the selected object + transform); returns nil if nothing changed.
-- The rotate/scale/move maths is exactly the same as at commit (_finishTransform/_applySelectDelta), so what you see is what gets committed
function M:_buildDragPreview(x, y)
    local el = self._selected
    if not el then
        return nil
    end
    local pv
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a0 = math.atan2(tr.y0 - cy, tr.x0 - cx)
        local a1 = math.atan2(y - cy, x - cx)
        if math.abs(a1 - a0) < 0.02 then
            return nil -- angle barely changed
        end
        pv = self:_cloneElement(el)
        self:_rotateElement(pv, a1 - a0, cx, cy)
    elseif tr then
        -- Scale: rotated shapes scale along the two OBB axes, others compute a new bounding box from the handle dragged to the current position
        pv = self:_cloneElement(el)
        if not self:_scaleElementOriented(pv, tr.handle, x, y) then
            local sb = tr.bbox
            local nb = self:_transformBBox(tr.handle, sb, x, y)
            if nb.x0 == sb.x0 and nb.y0 == sb.y0 and nb.x1 == sb.x1 and nb.y1 == sb.y1 then
                return nil -- size unchanged
            end
            self:_scaleElement(pv, sb, nb)
        end
    else
        local drag = self._select_drag
        if not drag then
            return nil
        end
        local dx = math.floor(x - drag.x0 + 0.5)
        local dy = math.floor(y - drag.y0 + 0.5)
        if dx == 0 and dy == 0 then
            return nil -- no displacement
        end
        pv = self:_cloneElement(el)
        self:_moveElement(pv, dx, dy)
    end
    return pv
end

-- First-display timer fired: build the preview and refresh it immediately
function M:_maybeShowDragPreview()
    self._drag_preview_fn = nil
    if not self.canvas_bb then
        return -- callback still pending after close: just discard it
    end
    local pos = self._drag_preview_pos
    if not pos then
        return
    end
    local pv = self:_buildDragPreview(pos.x, pos.y)
    if not pv then
        return
    end
    self:_cacheBBox(pv)
    -- Record the rotation angle at first display as the throttling baseline for later follow rebuilds
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        self._drag_preview_angle = math.atan2(pos.y - cy, pos.x - cx)
    end
    self._drag_preview = pv
    self._drag_preview_region = self:_elementRegion(pv)
    local el = self._selected
    self:_log("drag preview shown", el and el.kind,
        self._transform and (self._handle_mode == "rotate" and "rotate" or "scale") or "move")
    UIManager:setDirty(self, "partial", self._drag_preview_region)
end

-- After the preview is shown: follow the finger to update the preview element, merge the region into the accumulated region, throttled redraw.
-- Skip if the bbox matches the current preview (geometry unchanged, e.g. tiny moves/rotating a circle), no repeated refresh = no flicker, saves waveforms.
-- Rotation previews are additionally rebuild-throttled by angle: fully re-rasterising on every pan (milliseconds to hundreds of milliseconds for a large fill) is
-- the main cause of drag stutter, so angle changes below DRAG_ROTATE_RECALC_ANGLE are skipped (only the drop position is updated)
function M:_updateDragPreview(x, y)
    self._drag_preview_pos = { x = x, y = y }
    if not self._drag_preview then
        return
    end
    local tr = self._transform
    if tr and self._handle_mode == "rotate" then
        local sb = tr.bbox
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a = math.atan2(y - cy, x - cx)
        local last = self._drag_preview_angle
        if last and math.abs(a - last) < const.DRAG_ROTATE_RECALC_ANGLE then
            return -- angle barely changed: skip rebuild and redraw
        end
        self._drag_preview_angle = a
    end
    local pv = self:_buildDragPreview(x, y)
    if not pv then
        return
    end
    self:_cacheBBox(pv)
    local cur = self._drag_preview
    if cur._bbox and pv._bbox
        and cur._bbox.x0 == pv._bbox.x0 and cur._bbox.y0 == pv._bbox.y0
        and cur._bbox.x1 == pv._bbox.x1 and cur._bbox.y1 == pv._bbox.y1 then
        return -- visible result unchanged, no redraw
    end
    self._drag_preview = pv
    self._drag_preview_region = self:_mergeRegions(self._drag_preview_region, self:_elementRegion(pv))
    if not self._drag_preview_repaint_pending then
        self._drag_preview_repaint_pending = true
        local fn = function()
            self:_flushDragPreviewRepaint()
        end
        self._drag_preview_repaint_fn = fn
        UIManager:scheduleIn(const.DRAG_PREVIEW_REFRESH_INTERVAL, fn)
    end
end

-- Preview follow throttle window fired: refresh the merged accumulated region
function M:_flushDragPreviewRepaint()
    if self._drag_preview_repaint_fn then
        UIManager:unschedule(self._drag_preview_repaint_fn)
        self._drag_preview_repaint_fn = nil
    end
    self._drag_preview_repaint_pending = false
    if not self.canvas_bb then
        return -- callback still pending after close: just discard it
    end
    local reg = self._drag_preview_region
    self._drag_preview_region = nil
    if reg then
        UIManager:setDirty(self, "partial", reg)
    end
end

-- Cancel the preview timer and throttle task, clear the preview element (the accumulated region is kept for the pen-up refresh/erase)
function M:_cancelDragPreview()
    if self._drag_preview_fn then
        UIManager:unschedule(self._drag_preview_fn)
        self._drag_preview_fn = nil
    end
    if self._drag_preview_repaint_fn then
        UIManager:unschedule(self._drag_preview_repaint_fn)
        self._drag_preview_repaint_fn = nil
    end
    self._drag_preview_repaint_pending = false
    self._drag_preview = nil
    self._drag_preview_angle = nil
end

-- ============================ Selected object grey/width adjustment ============================

-- Adjust the selected object's grey (0-1): undoable, redraws the affected region.
-- no_undo=true lets the direct adjustment popup call it per tick (a single undo is written on close)
function M:_applySelectedGray(v, no_undo)
    local el = self._selected
    if not el then
        return
    end
    local g = v / 100
    if math.abs((el.gray or 1) - g) < 0.001 then
        return -- value unchanged, no record created
    end
    local orig = self:_cloneElement(el)
    el.gray = g
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    -- Sudden grey changes use the ui waveform to clear EPD ghosting (partial leaves the old grey, visible as the slider moves tick by tick)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected gray", el.kind, v)
    end
end

-- Adjust the selected object's line width (px): undoable. Line width affects the bounding box, so redraw the old ∪ new region.
-- no_undo=true lets the direct adjustment popup call it per tick (a single undo is written on close)
function M:_applySelectedWidth(v, no_undo)
    local el = self._selected
    if not el or el.kind == "text" then
        return -- text has no line width
    end
    if el.width == v then
        return
    end
    local old_region = self:_elementRegion(el)
    local orig = self:_cloneElement(el)
    el.width = v
    self:_cacheBBox(el)
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    -- Same as grey: width changes use the ui waveform to clear ghosting (partial leaves the old width outline)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected width", el.kind, v)
    end
end

-- Adjust the selected object's opacity (0-100, 100=opaque): undoable, redraws the affected region.
-- no_undo=true lets the direct adjustment popup call it per tick (a single undo is written on close)
function M:_applySelectedAlpha(v, no_undo)
    local el = self._selected
    if not el then
        return
    end
    local a = v / 100
    if math.abs((el.alpha or 1) - a) < 0.001 then
        return -- value unchanged, no record created
    end
    local orig = self:_cloneElement(el)
    el.alpha = a
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    -- Same as grey: opacity changes use the ui waveform to clear EPD ghosting (partial leaves the old grey, visible as the slider moves tick by tick)
    UIManager:setDirty(self, "ui", region)
    if not no_undo then
        self:_pushUndo({ kind = "transform", el = el, orig = orig, final = self:_cloneElement(el) })
        self:_clearRedo()
        self:_log("set selected alpha", el.kind, v)
    end
end

-- ============================ Transform (scale/rotate handles) ============================

-- Corners of the selection box (handle positions): tilted ellipses (rot≠0)/rotated rectangles (poly) use the object's own rotated bounding box (OBB)
-- hugging the boundary, avoiding axis-aligned AABB corners floating far away; other objects use the axis-aligned bounding box + pad.
-- Hit testing and handle drawing share the same set of corners, guaranteeing "what you see is what you tap"
function M:_frameCorners(el)
    local pad = 4
    if el.kind == "circle" and (el.rot or 0) ~= 0 then
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local c, s = math.cos(el.rot), math.sin(el.rot)
        -- Ellipse OBB corners = centre ± rx·u ± ry·v (u/v are the two rotated axes)
        local pts = {
            { x = el.cx + rx * c - ry * s, y = el.cy + rx * s + ry * c },
            { x = el.cx + rx * c + ry * s, y = el.cy + rx * s - ry * c },
            { x = el.cx - rx * c + ry * s, y = el.cy - rx * s - ry * c },
            { x = el.cx - rx * c - ry * s, y = el.cy - rx * s + ry * c },
        }
        -- Expand radially by pad (handles float slightly outside the ellipse)
        for _, p in ipairs(pts) do
            local dx, dy = p.x - el.cx, p.y - el.cy
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                p.x = p.x + dx / len * pad
                p.y = p.y + dy / len * pad
            end
        end
        return pts
    elseif el.kind == "poly" then
        -- Rotated rectangle converted to poly: take its corners, expand by pad about the centroid
        local pts = {}
        local cx, cy = 0, 0
        for i, p in ipairs(el.points) do
            pts[i] = { x = p.x, y = p.y }
            cx, cy = cx + p.x, cy + p.y
        end
        cx, cy = cx / #pts, cy / #pts
        for _, p in ipairs(pts) do
            local dx, dy = p.x - cx, p.y - cy
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                p.x = p.x + dx / len * pad
                p.y = p.y + dy / len * pad
            end
        end
        return pts
    elseif el.kind == "text" and (el.rot or 0) ~= 0 then
        -- Rotated text: rotate the 4 render corners about the anchor (same maths as the bounding box), expand radially by pad.
        -- Rotation centre = left end of the baseline (same anchor as the _drawTextTo transform branch: baseline = el.y + 0.8*font size),
        -- otherwise the selection box rotates about el.y while rendering rotates about the baseline, misaligned by 0.8*font size after rotation
        local e = self:_textExtent(el)
        if not e then
            return nil
        end
        local ax = el.x or 0
        local ay = e.baseline
        local c, sn = math.cos(el.rot), math.sin(el.rot)
        local pts = {}
        local corners = {
            { ax - 1, e.baseline - e.yt - 1 },
            { ax + e.w + 1, e.baseline - e.yt - 1 },
            { ax + e.w + 1, e.baseline + e.yb + 1 },
            { ax - 1, e.baseline + e.yb + 1 },
        }
        for i, co in ipairs(corners) do
            local dx, dy = co[1] - ax, co[2] - ay
            local px, py = ax + dx * c - dy * sn, ay + dx * sn + dy * c
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                px = px + dx / len * pad
                py = py + dy / len * pad
            end
            pts[i] = { x = px, y = py }
        end
        return pts
    end
    local b = el._bbox or self:_elementBBox(el)
    if not b then
        return nil
    end
    return {
        { x = b.x0 - pad, y = b.y0 - pad },
        { x = b.x1 + pad, y = b.y0 - pad },
        { x = b.x1 + pad, y = b.y1 + pad },
        { x = b.x0 - pad, y = b.y1 + pad },
    }
end

-- Hit-test the selected object's four corner transform handles; returns the handle name (nw/ne/se/sw) or nil.
-- Scale/rotate share the same four corners: tapping again toggles _handle_mode, and drags are routed by mode (see _finishTransform).
-- Text doesn't support rotation (tapping again doesn't toggle), but the four scale corners still hit as usual
function M:_hitHandle(x, y)
    local el = self._selected
    if not el then
        return nil
    end
    local pts = self:_frameCorners(el)
    if not pts then
        return nil
    end
    local ids = { "nw", "ne", "se", "sw" }
    local radius = (el.kind == "text")
        and const.TEXT_HANDLE_HIT_RADIUS or const.HANDLE_HIT_RADIUS
    for i, p in ipairs(pts) do
        if math.abs(x - p.x) <= radius and math.abs(y - p.y) <= radius then
            return ids[i]
        end
    end
    return nil
end

-- Select-tool transform pen-up: apply scale/rotate to the selected object from the handle drag (undoable).
-- Same four corner handles: when _handle_mode=="rotate" dragging a corner rotates about the bounding-box centre, otherwise it scales against the opposite corner.
-- First cancel the preview and erase its accumulated region (intermediate positions during following must be refreshed too, to prevent leftovers)
function M:_finishTransform(x, y)
    self:_cancelDragPreview()
    local prev_region = self._drag_preview_region
    self._drag_preview_region = nil
    local tr = self._transform
    self._transform = nil
    if not (tr and x) then
        -- No transform happened (released outside the canvas, etc.): erase the leftover preview already shown
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    local el = self._selected
    if not el then
        return
    end
    local sb = tr.bbox
    if self._handle_mode == "rotate" then
        local cx, cy = (sb.x0 + sb.x1) / 2, (sb.y0 + sb.y1) / 2
        local a0 = math.atan2(tr.y0 - cy, tr.x0 - cx)
        local a1 = math.atan2(y - cy, x - cx)
        self:_rotateElement(el, a1 - a0, cx, cy)
    else
        -- Rotated shapes (handles on OBB corners) scale along their own two axes, otherwise take the AABB corner-handle path
        if not self:_scaleElementOriented(el, tr.handle, x, y) then
            local nb = self:_transformBBox(tr.handle, sb, x, y)
            self:_scaleElement(el, sb, nb)
        end
    end
    self:_cacheBBox(el)
    local region = self:_mergeRegions(tr.old_region, self:_elementRegion(el))
    if prev_region then
        -- Also white-out + refresh the ghosting of intermediate positions accumulated while the preview followed:
        -- if omitted, fill ghosts at several angles remain after release (horizontal stripes, larger and more visible in the bigger stretch preview region)
        region = self:_mergeRegions(region, prev_region)
    end
    self:_pushUndo({ kind = "transform", el = el, orig = tr.orig, final = self:_cloneElement(el) })
    self:_clearRedo()
    self:_redrawRegion(region)
    -- Rotate/scale are sudden content changes over large grey areas; an EPD partial refresh leaves grey streaks (horizontal stripes, larger and more visible when stretched);
    -- refresh once with the "ui" waveform to clear the ghosting
    UIManager:setDirty(self, "ui", region)
    self:_log("transform", tr.handle)
end

return M
