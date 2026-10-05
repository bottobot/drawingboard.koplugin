--[[--
drawingpad.strokes - brush/eraser/shape tool and refresh throttling methods (DrawingCanvas mixin module).
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

-- Invalidate all pending scheduled tasks (called on close/tool switch/minimise/clear).
-- scheduleIn returns nil so there is no handle, but UIManager:unschedule cancels by closure reference;
-- calling unschedule here on the same saved closure really removes it from the task queue,
-- eliminating the hazard of "zombie timers still firing after close"
function M:_invalidateTasks()
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
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
    self._drag_preview_region = nil
    self._stroke_repaint_pending = false
    self._stroke_region = nil
    self:_freeAlphaStrokeSnap() -- free the snapshot when a semi-transparent stroke is aborted (the next stroke takes a new one)
end

-- Incremental spline rendering: consume the segments in points not yet rendered (_seg count), drawn the same way as shapes.polyline
-- segment for segment (Catmull-Rom interpolation through points). Segment P_k→P_{k+1} needs neighbours P_{k-1}/P_{k+2} for its tangents,
-- so rendering lags one point behind (the last segment is completed by _renderStrokeClose on pen-up),
-- guaranteeing the live stroke is identical to the undo/save redraw. Returns the bounding box of what was drawn this time (nil if nothing).
function M:_renderStrokeTail(s)
    s = s or self._stroke
    if not s then return nil end
    local pts = s.points
    local n = #pts
    if n == 0 then return nil end
    local gray = Blitbuffer.gray(s.gray)
    -- v62s: semi-transparent strokes are drawn live as **opaque** grey straight into the canvas incrementally (the same fast geometry path as opaque strokes,
    -- least computation; the user's chosen approach "opaque grey preview, corrected by the pen-up refresh"). Per-segment blending (round caps
    -- overlapping between segments apply alpha repeatedly) and whole-stroke replay (quadratic growth) are both abandoned; on pen-up the live_alpha branch
    -- replays the whole stroke's region once, correcting the opaque preview into an even semi-transparency.
    -- Exempting the fill tool no longer makes sense: the fill outline also uses the opaque preview, and the commit already replays the whole region to erase it
    local pbb = self:_alphaBB(self.canvas_bb, s)
    if type(pbb) == "table" and pbb.__dp_alpha and pbb.__dp_alpha < 255 then
        pbb = self.canvas_bb
        -- v62v: pre-stroke snapshot (taken only once) - the pen-up fast path restores the snapshot + composites the whole stroke in a single pass
        if not s._alpha_snap_done then
            s._alpha_snap_done = true
            self:_takeAlphaStrokeSnap()
        end
    end
    local minx, miny, maxx, maxy
    if not s._tip_drawn then
        -- Full-width start-point tip (visible on touch-down; full width from pen-down, so small arcs at the start are clearly visible).
        -- Its extent is also included in the return value: callers merge this bounding box into _stroke_region - the call that only drew the start
        -- dot and couldn't render a segment yet (needs the right neighbour) used to return nil, so the "refresh immediately on pen-down"
        -- setDirty(partial, nil) = full-screen refresh = flash on fast pen-down (slow pen-down goes through onHold,
        -- which has an `if rx0 then` guard, so no flash)
        s._tip_drawn = true
        shapes.tip(pbb, pts[1].x, pts[1].y, shapes.pointWidth(s.width, pts[1]), gray, s.tip)
        minx, maxx = pts[1].x, pts[1].x
        miny, maxy = pts[1].y, pts[1].y
    end
    -- Segment P_k→P_{k+1} has right neighbour P_{k+2}: renderable only when k ≤ n-2,
    -- i.e. the loop condition s._seg + 3 ≤ n (the last segment is left to _renderStrokeClose)
    while (s._seg or 0) + 3 <= n do
        local k = (s._seg or 0) + 1 -- render segment P_k→P_{k+1}
        local p0 = pts[math.max(1, k - 1)]
        local p1, p2, p3 = pts[k], pts[k + 1], pts[k + 2]
        if pbb then
            shapes.crSegment(pbb, p0, p1, p2, p3, s.width, gray, s.tip)
        end
        minx = math.min(minx or p1.x, p0.x, p1.x, p2.x, p3.x)
        maxx = math.max(maxx or p1.x, p0.x, p1.x, p2.x, p3.x)
        miny = math.min(miny or p1.y, p0.y, p1.y, p2.y, p3.y)
        maxy = math.max(maxy or p1.y, p0.y, p1.y, p2.y, p3.y)
        s._seg = k
    end
    if minx then
        return minx, miny, maxx, maxy
    end
    return nil
end

-- Finishing segment: the remaining last segment P_{n-1}→P_n (end-side neighbour clamped to the last point, same as shapes.polyline);
-- only called when incremental rendering has already happened. Returns the bounding box.
function M:_renderStrokeClose(s)
    s = s or self._stroke
    if not s or not s._tip_drawn then return nil end
    local pts = s.points
    local n = #pts
    if n < 2 then return nil end
    local gray = Blitbuffer.gray(s.gray)
    local pbb = self:_alphaBB(self.canvas_bb, s)
    -- v62s: semi-transparent live preview in opaque grey (same as _renderStrokeTail)
    if type(pbb) == "table" and pbb.__dp_alpha and pbb.__dp_alpha < 255 then
        pbb = self.canvas_bb
    end
    local minx, miny, maxx, maxy
    while (s._seg or 0) < n - 1 do
        local k = (s._seg or 0) + 1
        local p0 = pts[math.max(1, k - 1)]
        local p1, p2 = pts[k], pts[k + 1]
        shapes.crSegment(pbb, p0, p1, p2, p2, s.width, gray, s.tip)
        minx = math.min(minx or p1.x, p0.x, p1.x, p2.x)
        maxx = math.max(maxx or p1.x, p0.x, p1.x, p2.x)
        miny = math.min(miny or p1.y, p0.y, p1.y, p2.y)
        maxy = math.max(maxy or p1.y, p0.y, p1.y, p2.y)
        s._seg = k
    end
    if minx then
        return minx, miny, maxx, maxy
    end
    return nil
end

-- Append a point and incrementally draw the new segment (straight into the canvas BB; it belongs to the "in-progress" stroke until pen-up)
-- Kobo fork: optional f = pen pressure width factor stored on the point (nil for finger strokes)
function M:_extendStroke(x, y, f)
    local s = self._stroke
    if not s then
        return
    end
    local pts = s.points
    local last = pts[#pts]
    if last and last.x == x and last.y == y then
        return -- dedup
    end
    -- Slow strokes produce many dense points within 1px: set a minimum step proportional to brush width and skip points within it.
    -- Step capped at 3px: thicker brushes no longer skip dense points either, so small arcs don't get straightened by thinning
    -- (per-stroke memory still has the MAX_STROKE_POINTS even thinning on pen-up as a backstop).
    -- Ink from round/thick tips within the step overlaps completely, so there's no visual difference, but per-stroke point counts drop by an order of magnitude,
    -- and long-session memory and eraser/save scan costs converge significantly
    local min_step = math.min(3, math.max(1, math.floor(s.width / 8)))
    if last and math.abs(last.x - x) < min_step and math.abs(last.y - y) < min_step then
        return
    end
    table.insert(pts, { x = x, y = y, f = f })
    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail()
    if not rx0 then
        return
    end
    -- Throttled refresh: data goes into the canvas live, the screen refreshes merged regions per window (e-ink doesn't refresh per event, prevents stutter);
    -- thick strokes use a wider throttle window to cut waveform refreshes
    self._stroke_region = self:_mergeRegions(self._stroke_region,
        self:_dirtyRegion(rx0, ry0, rx1, ry1, s.width + 2))
    if not self._stroke_repaint_pending then
        self._stroke_repaint_pending = true
        -- Kobo fork: a live pen stroke (stylus.lua) sets its own shorter throttle window
        local interval = self._live_refresh_interval or ((s.width >= const.THICK_WIDTH)
            and const.THICK_REFRESH_INTERVAL or const.STROKE_REFRESH_INTERVAL)
        -- Store the closure reference: scheduleIn returns nil so there is no handle, unschedule cancels by closure reference,
        -- and on close/tool switch _invalidateTasks unschedules the same closure to invalidate the task
        local fn = function()
            self:_flushStrokeRepaint()
        end
        self._stroke_repaint_fn = fn
        UIManager:scheduleIn(interval, fn)
    end
end

-- Throttle window fired: refresh the merged region (named method so it can be cancelled on close/uniformly pcall-protected).
-- The refresh-immediately-on-pen-down path also calls this: it cancels any already queued throttle task, avoiding a queue backlog.
-- With no accumulated region **no refresh is sent**: setDirty(partial, nil) in KOReader is a full-screen refresh
-- (and gets upgraded to a flashing full refresh by count), which is a flash on e-ink; and "no region" means exactly
-- "this stroke has no ink to show yet" (the ink is already in canvas_bb and goes on screen with the next throttled refresh or the pen-up one
-- that carries a region), so skipping is equivalent and cheaper
-- Whole-stroke bounding region for semi-transparent strokes (for wipe-and-replay): single-pass compositing draws the whole stroke, so the wiped region must
-- cover the whole stroke as well - wiping only "this round's new segments" makes the old prefix stack alpha again on every flush (a rectangular staircase mosaic)
function M:_strokeRegion(s)
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(s.points) do
        if p.x < minx then minx = p.x end
        if p.x > maxx then maxx = p.x end
        if p.y < miny then miny = p.y end
        if p.y > maxy then maxy = p.y end
    end
    if minx == math.huge then
        return nil
    end
    return self:_dirtyRegion(minx, miny, maxx, maxy, (s.width or 1) + 2)
end

-- Pre-stroke canvas snapshot for semi-transparent strokes (v62v): pen-up uses "restore snapshot + single-pass composite of the whole stroke" instead of
-- a full-element _redrawRegion replay - the replay redraws every element in the region (including full-canvas background fills),
-- so pen-up stutters noticeably with many elements; after restoring the snapshot the canvas is in its pre-stroke state, and only this stroke needs compositing.
-- Cost = one full-canvas copy per stroke (milliseconds), far less than a large region replay
function M:_takeAlphaStrokeSnap()
    self:_freeAlphaStrokeSnap()
    local snap = Blitbuffer.new(self.canvas_w, self.canvas_h, self.canvas_bb:getType())
    snap:blitFullFrom(self.canvas_bb)
    self._alpha_stroke_snap = snap
end

function M:_freeAlphaStrokeSnap()
    if self._alpha_stroke_snap then
        self._alpha_stroke_snap:free()
        self._alpha_stroke_snap = nil
    end
end

function M:_flushStrokeRepaint()
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    self._stroke_repaint_pending = false
    if not self.canvas_bb then
        return -- callback still pending after close: just discard it, don't touch freed state
    end
    local reg = self._stroke_region
    self._stroke_region = nil
    if not reg then
        return
    end
    -- v62s: the opaque preview for live semi-transparent strokes needs no throttle callback intervention (drawn incrementally into the canvas like opaque strokes);
    -- on pen-up the whole-stroke region replay uniformly corrects it to semi-transparent
    -- Kobo fork: a live pen stroke uses the fastest waveform ("fast") and lets paintTo blit only this region (see stylus.lua)
    if self._live_refresh_mode then
        self._pen_clip_paint = self:_mergeRegions(self._pen_clip_paint, reg)
    end
    UIManager:setDirty(self, self._live_refresh_mode or "partial", reg)
end

-- Thinning: when the point count exceeds MAX_STROKE_POINTS, keep points evenly (keeping first and last).
-- Only affects very long strokes with almost no visual difference; caps per-stroke memory and later scan costs
function M:_thinPoints(points)
    local n = #points
    if n <= const.MAX_STROKE_POINTS then
        return points
    end
    local out = {}
    local step = (n - 1) / (const.MAX_STROKE_POINTS - 1)
    for i = 1, const.MAX_STROKE_POINTS do
        local idx = math.max(1, math.min(n, math.floor(1 + (i - 1) * step + 0.5)))
        out[i] = points[idx]
    end
    out[const.MAX_STROKE_POINTS] = points[n] -- ensure the last point is exact
    return out
end

function M:_finishStroke(x, y)
    local s = self._stroke
    self._stroke = nil
    if not s then
        return
    end
    local last_reg
    if x then
        local last = s.points[#s.points]
        if not last or last.x ~= x or last.y ~= y then
            table.insert(s.points, { x = x, y = y })
        end
    end
    -- Incrementally consume the remaining points + the closing half-segment (bending from the last midpoint to the last point, same as shapes.polyline).
    -- s is passed explicitly: _finishStroke's entry already set self._stroke to nil, so it can't be read inside
    local rx0, ry0, rx1, ry1 = self:_renderStrokeTail(s)
    local cx0, cy0, cx1, cy1 = self:_renderStrokeClose(s)
    if rx0 or cx0 then
        local minx = math.min(rx0 or cx0, cx0 or rx0)
        local miny = math.min(ry0 or cy0, cy0 or ry0)
        local maxx = math.max(rx1 or cx1, cx1 or rx1)
        local maxy = math.max(ry1 or cy1, cy1 or ry1)
        last_reg = self:_dirtyRegion(minx, miny, maxx, maxy, s.width + 2)
    end
    if #s.points > 0 then
        -- Evenly thin very long strokes (keeping first and last): limits per-stroke memory and later scan costs
        if #s.points > const.MAX_STROKE_POINTS then
            s.points = self:_thinPoints(s.points)
        end
        if self.tool == "fill" then
            -- Stroke fill: don't commit a path element; after the closed fill, clear the path ink (leaving only the filled area).
            -- All pen-ups go through here, eliminating branches like onPanRelease/onHold/two-finger that missed triggering the closed fill
            self:_commitFillPath(s)
            return
        end
        table.insert(self.elements, s)
        self:_cacheBBox(s)
        self:_pushUndo({ kind = "add", el = s })
        self:_clearRedo()
        self:_log("commit stroke", s.kind, #s.points, "points, gray", s.gray, "width", s.width)
    end
    -- Pen-up refresh: commit region = last segment ∪ throttle-accumulated region (covers the whole stroke).
    -- Incremental ink drawn straight into canvas_bb is always on top; when visible layers lie above the current layer,
    -- white-out + replay in layer order is required to restore occlusion; with the replay canvas ready, the screen refresh keeps the original throttle semantics
    local region = self:_mergeRegions(last_reg, self._stroke_region)
    -- v62q: during the live phase semi-transparent strokes weren't drawn into the canvas (single-pass compositing of the whole stroke), and the element is already in elements,
    -- so the region must be replayed unconditionally here (drawElement inside _redrawRegion intercepts and does single-pass compositing);
    -- the "replay only if upper layers have content" guard of _commitRegionReplay can't be used
    local t = self:_alphaBB(self.canvas_bb, s)
    local live_alpha = type(t) == "table" and t.__dp_alpha and t.__dp_alpha < 255 or false
    if live_alpha then
        -- The wiped region must likewise = the whole-stroke bounding box (region is only the tail ∪ new segments after the last flush,
        -- which doesn't cover the whole stroke; the old prefix would keep the composited result of the last flush)
        self._stroke_region = nil
        self._stroke_repaint_pending = false
        if self._stroke_repaint_fn then
            UIManager:unschedule(self._stroke_repaint_fn)
            self._stroke_repaint_fn = nil
        end
        local sreg = self:_strokeRegion(s)
        -- v62v fast path: restore the pre-stroke snapshot (one blit wipes the opaque live preview), then do a single-pass
        -- composite of the whole stroke (drawElement intercepts -> drawFilledAlpha). The old path went through
        -- _redrawRegion: white-out + replay every element in the region (including background fills), so pen-up stuttered noticeably with many elements.
        -- When visible layers lie above the current layer the fast path can't restore occlusion, so fall back to replay
        local replay = true
        local snap = self._alpha_stroke_snap
        self._alpha_stroke_snap = nil
        if snap then
            local active = self.active_layer or 2
            for li = active + 1, 3 do
                if self.layer_visible[li] and #self.layers[li] > 0 then
                    replay = false
                    break
                end
            end
        end
        if sreg then
            if replay then
                self:_redrawRegion(sreg)
            else
                self.canvas_bb:blitFrom(snap, sreg.x, sreg.y, sreg.x, sreg.y, sreg.w, sreg.h)
                shapes.drawElement(self:_alphaBB(self.canvas_bb, s), s, Blitbuffer.gray(s.gray))
                if self._invalidateVisCache then
                    self:_invalidateVisCache()
                end
            end
            UIManager:setDirty(self, "partial", sreg)
        end
        if snap then
            snap:free()
        end
        return
    end
    self:_commitRegionReplay(region)
    if self._stroke_repaint_pending then
        -- Throttle callback pending: keep the accumulated region for the callback to refresh (avoids a nil-region full-screen partial)
    else
        self._stroke_region = nil
        if region then
            UIManager:setDirty(self, "partial", region)
        end
    end
end

-- Layer-order correction after commit: in-progress ink is drawn straight into canvas_bb (always on top of existing ink),
-- so white-out + replay in layer order to restore occlusion is only needed when **visible layers with content lie above** the current layer.
-- With no visible content above, the new ink belongs on top anyway, so skip - otherwise every stroke/element commit
-- would replay the elements in the region (including full-canvas background fills), and refresh would slow noticeably with many elements.
-- When skipping, also invalidate the visibility cache (newer cores have the ping-pong cache, and incremental ink didn't go through _redrawRegion)
function M:_commitRegionReplay(region)
    if not region or not self.canvas_bb then
        return
    end
    local active = self.active_layer or 2
    for li = active + 1, 3 do
        if self.layer_visible[li] and #self.layers[li] > 0 then
            self:_redrawRegion(region)
            return
        end
    end
    if self._invalidateVisCache then
        self:_invalidateVisCache()
    end
end

-- Ink dot from a quick tap/light tap (single-point stroke, undoable; debounce doesn't block deliberate taps)
function M:_commitDot(x, y)
    local el = {
        kind = "freehand",
        points = { { x = x, y = y } },
        gray = self:_resolveGray(),
        alpha = self:_resolveAlpha(),
        blend = self.alpha_blend,
        width = self:_resolveWidth(),
        tip = self.tip,
    }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    shapes.tip(self:_alphaBB(self.canvas_bb, el), x, y, el.width, Blitbuffer.gray(el.gray), el.tip)
    self:_log("commit dot", x, y, "width", el.width)
    local region = self:_dirtyRegion(x, y, x, y, el.width + 2)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

-- ============================ Shape tools ============================

-- Shape tool drag: only record the anchor and current point, no per-frame preview refresh;
-- a preview is shown once only after the finger rests for SHAPE_PREVIEW_DELAY seconds (pen-up still confirms once with the last updated point)
function M:_trackShapeAnchor(ges)
    local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
    if not x then
        return
    end
    if not self._shape_start then
        -- Anchor is the touch-down point (canvas coordinates = screen coordinates); falls back to the current point when start_pos isn't on the canvas.
        -- Grey/width are taken once at pen-down and fixed: in random mode the preview matches the commit, and width doesn't change with resting
        local sx, sy = x, y
        if ges.start_pos then
            local sxv, syv = self:_toCanvas(ges.start_pos.x, ges.start_pos.y)
            if sxv then
                sx, sy = sxv, syv
            end
        end
        self._shape_start = {
            x = sx, y = sy,
            gray = self:_resolveGray(),
            width = self:_resolveWidth(),
            alpha = self:_resolveAlpha(),
            blend = self.alpha_blend,
        }
    end
    self:_scheduleShapePreview(x, y)
end

-- Reschedule the SHAPE_PREVIEW_DELAY-second preview timer. scheduleIn returns nil so there is no handle,
-- but unschedule cancels by closure reference: save the same closure used for scheduling, and on every pan cancel then reschedule,
-- so the timer fires only once after the finger "rests for the full delay", instead of piling up into bursts like the old version (on the device
-- 40+ "preview shown" log lines in the same second were once observed)
function M:_scheduleShapePreview(x, y)
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
    if self.preview then
        local old = self.preview
        self.preview = nil
        UIManager:setDirty(self, "partial", self:_elementRegion(old))
    end
    self._shape_pos = { x = x, y = y }
    local fn = function()
        self:_maybeShowShapePreview()
    end
    self._shape_preview_fn = fn
    UIManager:scheduleIn(const.SHAPE_PREVIEW_DELAY, fn)
end

-- Timer fired: the finger rested ≥SHAPE_PREVIEW_DELAY, show the shape preview (anchor -> current point)
function M:_maybeShowShapePreview()
    self._shape_preview_fn = nil
    if not self.canvas_bb then
        return -- callback still pending after close: just discard it, don't touch freed state
    end
    local start = self._shape_start
    local pos = self._shape_pos
    if not (start and pos) then
        return
    end
    self.preview = self:_buildShapeElement(self.tool, start.x, start.y, pos.x, pos.y, start.gray, start.width, start.alpha, start.blend)
    if self.preview and not self:_shapeIsEmpty(self.preview) then
        self._shape_preview_region = self:_elementRegion(self.preview)
        self:_log("preview shown", self.preview.kind)
        UIManager:setDirty(self, "partial", self._shape_preview_region)
    else
        self.preview = nil -- shapes that are too small get no preview (pen-down would discard them via debounce too)
    end
end

-- Cancel the preview timer and clear the preview element (keep _shape_preview_region for the pen-up refresh/erase)
function M:_cancelShapePreview()
    if self._shape_preview_fn then
        UIManager:unschedule(self._shape_preview_fn)
        self._shape_preview_fn = nil
    end
    self.preview = nil
end

function M:_buildShapeElement(tool, x0, y0, x1, y1, gray, width, alpha, blend)
    if type(x0) ~= "number" or type(y0) ~= "number" or type(x1) ~= "number" or type(y1) ~= "number" then
        self:_log("_buildShapeElement: invalid coords", tool, x0, y0, x1, y1)
        return nil
    end
    -- Grey/width/opacity: taken once and fixed at pen-down (_trackShapeAnchor), so the preview matches the commit;
    -- if not passed (old callers/fallback) take them once on the spot. Same for blend mode (recorded with the element)
    gray = gray or self:_resolveGray()
    width = width or self:_resolveWidth()
    alpha = alpha or self:_resolveAlpha()
    blend = blend or self.alpha_blend
    if tool == "line" then
        -- Line (the tool toggled by long-pressing the brush) carries the brush tip shape; rectangle/circle keep the round tip
        return { kind = "line", x0 = x0, y0 = y0, x1 = x1, y1 = y1, gray = gray, width = width, alpha = alpha, blend = blend, tip = self.tip }
    elseif tool == "rect" then
        return { kind = "rect", x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            gray = gray, width = width, alpha = alpha, blend = blend, filled = self.rect_filled }
    elseif tool == "circle" then
        local r = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        return { kind = "circle", cx = x0, cy = y0, rx = r, ry = r,
            gray = gray, width = width, alpha = alpha, blend = blend, filled = self.circle_filled }
    elseif tool == "eraser" then
        -- Rectangle box eraser: the preview draws a half-grey solid rectangle (visible); on commit _commitShape turns it into a white erase
        return { kind = "rect", x0 = x0, y0 = y0, x1 = x1, y1 = y1,
            gray = 0.5, width = 2, filled = true }
    end
    return nil
end

-- Pen-up: rebuild the final element from the release point and commit it; zero size (no drag) isn't committed
function M:_commitShape(x, y)
    local start = self._shape_start
    self._shape_start = nil
    self:_cancelShapePreview()
    -- The previously shown preview region must be refreshed too (erasing preview leftovers)
    local prev_region = self._shape_preview_region
    self._shape_preview_region = nil
    if not start then
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    local x1, y1 = x or start.x, y or start.y
    local el = self:_buildShapeElement(self.tool, start.x, start.y, x1, y1, start.gray, start.width, start.alpha, start.blend)
    if not el then
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    if self:_shapeIsEmpty(el) then
        self:_log("shape skipped (empty)", el.kind)
        if prev_region then
            UIManager:setDirty(self, "partial", prev_region)
        end
        return
    end
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    shapes.drawElement(self:_alphaBB(self.canvas_bb, el), el, Blitbuffer.gray(el.gray))
    self:_log("commit shape", el.kind, "at", start.x, start.y, "->", x1, y1)
    -- Refresh region: the element's actual extent (whole circle, no missing chunks) ∪ the previously shown preview extent;
    -- when visible layers lie above, replay to restore layer order (the new shape must not cover higher-layer ink)
    local region = self:_mergeRegions(self:_elementRegion(el), prev_region)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

-- Pen-down debounce: shapes smaller than the threshold are treated as accidental touches and discarded (zero size likewise).
-- The threshold depends only on the shape's own size (SHAPE_MIN_SIZE), decoupled from line width - with a width limit of 800,
-- scaling with brush width (width*2) could reach hundreds of px, discarding every normally sized hollow circle/rectangle
function M:_shapeIsEmpty(el)
    local min_size = const.SHAPE_MIN_SIZE
    if el.kind == "line" then
        return math.sqrt((el.x1 - el.x0) ^ 2 + (el.y1 - el.y0) ^ 2) < min_size
    elseif el.kind == "rect" then
        if el.x0 == el.x1 and el.y0 == el.y1 then
            return true
        end
        return math.max(math.abs(el.x1 - el.x0), math.abs(el.y1 - el.y0)) < min_size
    elseif el.kind == "circle" then
        return (el.rx or el.r) < min_size
    end
    return false
end

-- ============================ Eraser: delete objects ============================

-- Delete a batch of objects and record undo (removed from highest to lowest original index, keeping indices valid)
-- Only whites out and redraws the "union of the deleted elements' extents", so no full replay however large the canvas is
function M:_deleteElements(idxs, els)
    for j = #idxs, 1, -1 do
        table.remove(self.elements, idxs[j])
    end
    self:_pushUndo({ kind = "del", els = els, idxs = idxs })
    self:_clearRedo()
    self:_log("erase", #els, "objects")
    local region = nil
    for _, el in ipairs(els) do
        region = self:_mergeRegions(region, self:_elementRegion(el))
        if el == self._selected then
            self._selected = nil -- clear the selection when the deleted object is the selected one (its region is already merged into the redraw)
        end
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

-- Distance from the pick point to an element's "inked points" (actually drawn pixels); 0 = point is on the ink
function M:_inkDistance(el, px, py)
    if el.kind == "freehand" or el.kind == "eraser" then
        local pts = el.points
        local d = math.huge
        for i = 2, #pts do
            local a, b = pts[i - 1], pts[i]
            local s = const.pointSegDist(px, py, a.x, a.y, b.x, b.y)
            if s < d then d = s end
        end
        if #pts == 1 then
            d = math.sqrt((px - pts[1].x) ^ 2 + (py - pts[1].y) ^ 2)
        end
        -- Strokes have thickness: distance to the ink surface = distance to the centre line - radius
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "poly" then
        -- Closed polygon (rotated rectangle): distance to each edge (including the closing segment between last and first)
        local pts = el.points
        local n = #pts
        -- Solid: the interior is ink (even-odd rule point-in-polygon, v61k in sync with rendering)
        if el.filled then
            local inside = false
            for i = 1, n do
                local a, b = pts[i], pts[(i % n) + 1]
                if (a.y <= py and b.y > py) or (b.y <= py and a.y > py) then
                    local xin = a.x + (py - a.y) * (b.x - a.x) / (b.y - a.y)
                    if px < xin then inside = not inside end
                end
            end
            if inside then
                return 0
            end
        end
        local d = math.huge
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            local s = const.pointSegDist(px, py, a.x, a.y, b.x, b.y)
            if s < d then d = s end
        end
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "line" then
        local d = const.pointSegDist(px, py, el.x0, el.y0, el.x1, el.y1)
        return math.max(0, d - (el.width or 2) / 2)
    elseif el.kind == "rect" then
        -- Solid: the interior (geometric boundary ± width/2, decoupled from bounding-box semantics) is ink; hollow: only the four outline edges count
        local pr = (el.width or 2) / 2
        local xa, xb = math.min(el.x0, el.x1), math.max(el.x0, el.x1)
        local ya, yb = math.min(el.y0, el.y1), math.max(el.y0, el.y1)
        if el.filled and px >= xa - pr and px <= xb + pr and py >= ya - pr and py <= yb + pr then
            return 0
        end
        local d = math.huge
        d = math.min(d, const.pointSegDist(px, py, xa, ya, xb, ya))
        d = math.min(d, const.pointSegDist(px, py, xb, ya, xb, yb))
        d = math.min(d, const.pointSegDist(px, py, xb, yb, xa, yb))
        d = math.min(d, const.pointSegDist(px, py, xa, yb, xa, ya))
        return math.max(0, d - pr)
    elseif el.kind == "circle" then
        -- Circle/ellipse (including rotated): transform into the ellipse's local frame, approximate the ink distance by normalised distance
        local rx, ry = el.rx or el.r, el.ry or el.rx or el.r
        local dx, dy = px - el.cx, py - el.cy
        local rot = el.rot or 0
        if rot ~= 0 then
            local c, s = math.cos(-rot), math.sin(-rot)
            dx, dy = dx * c - dy * s, dx * s + dy * c
        end
        local dist_norm = math.sqrt((dx / rx) ^ 2 + (dy / ry) ^ 2)
        local min_r = math.min(rx, ry)
        if el.filled then
            -- Solid: ink extends to the outline's outer edge (r + width/2), the whole interior is 0 (picking at the edge of thick shapes doesn't miss)
            local outer = 1 + (el.width or 2) / 2 / min_r
            if dist_norm <= outer then
                return 0
            end
            return (dist_norm - outer) * min_r
        end
        -- Hollow: only the ellipse perimeter counts
        return math.max(0, math.abs(dist_norm - 1) * min_r - (el.width or 2) / 2)
    elseif el.kind == "text" then
        -- Text is approximated by its rendered bounding box; rotated text is first inverse-transformed into the unrotated local frame before measuring.
        -- Inverse rotation centre = left end of the baseline (same anchor as _drawTextTo/_elementBBox: baseline = el.y + 0.8*font size)
        local e = self:_textExtent(el)
        if not e then
            return math.huge
        end
        local ax = el.x or 0
        local ay = e.baseline
        local lx, ly = px, py
        local rot = el.rot or 0
        if rot ~= 0 then
            local c, sn = math.cos(-rot), math.sin(-rot)
            lx = ax + (px - ax) * c - (py - ay) * sn
            ly = ay + (px - ax) * sn + (py - ay) * c
        end
        local b = {
            x0 = ax - 1, y0 = e.baseline - e.yt - 1,
            x1 = ax + e.w + 1, y1 = e.baseline + e.yb + 1,
        }
        local dx = math.max(b.x0 - lx, 0, lx - b.x1)
        local dy = math.max(b.y0 - ly, 0, ly - b.y1)
        return math.sqrt(dx * dx + dy * dy)
    elseif el.kind == "fill" then
        -- Fill results are approximated by their bounding box (not pickable, fallback only)
        local b = self:_elementBBox(el)
        if not b then
            return math.huge
        end
        local dx = math.max(b.x0 - px, 0, px - b.x1)
        local dy = math.max(b.y0 - py, 0, py - b.y1)
        return math.sqrt(dx * dx + dy * dy)
    end
    return math.huge
end

-- Pick the "topmost visible" object at the tap point: iterate in reverse (draw order = bottom -> top, later drawn is on top),
-- if the tap point lands right on an object's ink (distance 0 = covered by it/visible there) return the topmost such object immediately;
-- if none is under the ink (the point is in a blank gap) fall back to the candidate with the "nearest ink distance" (pickable within tolerance).
-- Fill results (fill) are also pickable (move/copy/grey/scale; ink distance approximated by bbox)
function M:_pickElementAt(x, y, tolerance)
    tolerance = tolerance or const.PICK_TOLERANCE
    -- When the current layer is hidden all its elements are invisible, so tap-select/tap-delete must not hit them (exposed by v57 adversarial tests)
    if not self.layer_visible[self.active_layer] then
        return nil
    end
    local best_i, best_d = nil, math.huge
    for i = #self.elements, 1, -1 do
        local el = self.elements[i]
        local b = el._bbox or self:_elementBBox(el)
        if b and x >= b.x0 - tolerance and x <= b.x1 + tolerance
            and y >= b.y0 - tolerance and y <= b.y1 + tolerance then
            local d = self:_inkDistance(el, x, y)
            if d <= 0 then
                return el, i -- topmost visible object (covers the layers below at this point)
            end
            if d < best_d then
                best_d = d
                best_i = i
            end
        end
    end
    if best_i and best_d <= tolerance then
        return self.elements[best_i], best_i
    end
    return nil
end

-- Tap delete: delete the "topmost visible" object at the tap point (distance 0 first, topmost in reverse order;
-- in gaps use the nearest ink); if all ink is beyond the tolerance it counts as tapping blank space and nothing is deleted
function M:_eraseAt(x, y)
    local el, i = self:_pickElementAt(x, y)
    if el then
        self:_deleteElements({ i }, { el })
        return true
    end
    return false
end

-- Box select: delete objects intersecting the rectangle (intersection test uses the cached bbox)
function M:_eraseInRect(x0, y0, x1, y1)
    local xa, ya = math.min(x0, x1), math.min(y0, y1)
    local xb, yb = math.max(x0, x1), math.max(y0, y1)
    local idxs, els = {}, {}
    for i, el in ipairs(self.elements) do
        local b = el._bbox or self:_elementBBox(el)
        if b and b.x0 <= xb and b.x1 >= xa and b.y0 <= yb and b.y1 >= ya then
            table.insert(idxs, i)
            table.insert(els, el)
        end
    end
    if #els > 0 then
        self:_deleteElements(idxs, els)
    end
end

-- Brush erase: dragging collects path points (no drawing, no refresh, fast)
function M:_trackErasePath(ges)
    if not self._erase_path then
        self._erase_path = { points = {} }
    end
    local x, y = self:_toCanvas(ges.pos.x, ges.pos.y)
    if x then
        local pts = self._erase_path.points
        local last = pts[#pts]
        if not last or last.x ~= x or last.y ~= y then
            table.insert(pts, { x = x, y = y })
        end
    end
end

-- Brush erase pen-up: delete objects intersecting the path's bounding box
function M:_commitErasePath(x, y)
    local path = self._erase_path
    self._erase_path = nil
    if not path or #path.points == 0 then
        return
    end
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(path.points) do
        if p.x < minx then minx = p.x end
        if p.y < miny then miny = p.y end
        if p.x > maxx then maxx = p.x end
        if p.y > maxy then maxy = p.y end
    end
    local m = self.width + 4
    self:_eraseInRect(minx - m, miny - m, maxx + m, maxy + m)
end

-- Rectangle box erase pen-up: delete objects inside the box (the anchor and 0.5s grey box preview reuse the shape tool mechanism)
function M:_commitEraseRect(x, y)
    local start = self._shape_start
    self._shape_start = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    if not start then
        return
    end
    local x1, y1 = x or start.x, y or start.y
    self:_eraseInRect(start.x, start.y, x1, y1)
end

-- ============================ Fill tool ============================

-- Flood fill: from (sx,sy), fill the connected region (edge-aware, scanline algorithm).
-- Expanding to a neighbouring pixel requires: ① local difference from the neighbour ≤ FILL_EDGE_TOLERANCE (local edge detection -
-- light strokes differing from the white background by >8 become boundaries, independent of the seed colour, so 5%~9% and lighter strokes are recognised);
-- ② difference from the seed pixel ≤ FILL_TOLERANCE (overall consistency backstop, prevents creeping along gradual gradients).
-- Doesn't modify canvas pixels; returns a span list { {y, x0, x1}, ... } for replaying the fill element
function M:_floodFillSpans(bb, sx, sy, tol)
    local bw, bh = bb:getWidth(), bb:getHeight()
    if sx < 0 or sx >= bw or sy < 0 or sy >= bh then
        return nil
    end
    local p0 = bb:getPixel(sx, sy)
    if not p0 then
        return nil
    end
    local target = p0.a
    local edge_tol = const.FILL_EDGE_TOLERANCE
    local function pval(px, py)
        local p = bb:getPixel(px, py)
        return p and p.a or -1
    end
    local function fillable(px, py, ref)
        local a = pval(px, py)
        return a >= 0 and math.abs(a - ref) <= edge_tol and math.abs(a - target) <= tol
    end
    local spans = {}
    local seen = {} -- seen[y] = list of processed {x0,x1}
    local function overlaps(y, x0, x1)
        local list = seen[y]
        if not list then
            return false
        end
        for _, s in ipairs(list) do
            if x1 >= s[1] and x0 <= s[2] then
                return true
            end
        end
        return false
    end
    local stack = { { sy, sx, sx } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local y, x0, x1 = seg[1], seg[2], seg[3]
        local e0, e1 = x0, x1 -- expand the current row to both sides (compared with the neighbouring pixel)
        while e0 - 1 >= 0 and fillable(e0 - 1, y, pval(e0, y)) do e0 = e0 - 1 end
        while e1 + 1 < bw and fillable(e1 + 1, y, pval(e1, y)) do e1 = e1 + 1 end
        if not overlaps(y, e0, e1) then
            if not seen[y] then seen[y] = {} end
            table.insert(seen[y], { e0, e1 })
            table.insert(spans, { y, e0, e1 })
            for _, ny in ipairs({ y - 1, y + 1 }) do -- find new seed segments in the rows above/below (compared with the pixel directly above/below)
                if ny >= 0 and ny < bh then
                    local nx = e0
                    while nx <= e1 do
                        if fillable(nx, ny, pval(nx, y)) then
                            local s0, s1 = nx, nx
                            while s0 - 1 >= e0 and fillable(s0 - 1, ny, pval(s0, ny)) do s0 = s0 - 1 end
                            while s1 + 1 <= e1 and fillable(s1 + 1, ny, pval(s1, ny)) do s1 = s1 + 1 end
                            if not overlaps(ny, s0, s1) then
                                table.insert(stack, { ny, s0, s1 })
                            end
                            nx = s1 + 1
                        else
                            nx = nx + 1
                        end
                    end
                end
            end
        end
    end
    return spans
end

-- Tap fill: flood-fill the enclosed area at the tap point, stored as a fill element (undoable; region redraw replays the spans)
function M:_fillAt(x, y)
    if not self.canvas_bb then
        return
    end
    local spans = self:_floodFillSpans(self.canvas_bb,
        math.floor(x), math.floor(y), const.FILL_TOLERANCE)
    if not spans or #spans == 0 then
        return
    end
    local el = { kind = "fill", spans = spans, gray = self:_resolveGray(), alpha = self:_resolveAlpha(), blend = self.alpha_blend }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    local region = self:_elementRegion(el)
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
    self:_log("fill at", x, y, #spans, "spans")
end

-- Interior spans of a closed polygon (even-odd rule scanline fill): computed only from the path's own geometry, ignoring other ink on the canvas.
-- Per row, find the intersections of each edge with the scanline (half-open intervals prevent double-counting vertices), sort, and take intervals in pairs.
-- Returns a span list { {y, x0, x1}, ... } (self-intersecting paths such as a figure 8 are split into pieces by the even-odd rule)
function M:_polygonFillSpans(pts)
    local spans = {}
    local n = #pts
    if n < 3 then
        return spans
    end
    local y_min, y_max = math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p.y < y_min then y_min = p.y end
        if p.y > y_max then y_max = p.y end
    end
    for y = math.floor(y_min), math.ceil(y_max) do
        local xs = {}
        for i = 1, n do
            local a, b = pts[i], pts[(i % n) + 1]
            if (a.y <= y and b.y > y) or (b.y <= y and a.y > y) then
                table.insert(xs, a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
            end
        end
        table.sort(xs)
        local i = 1
        while i < #xs do
            local x0 = math.ceil(xs[i] - 0.5)
            local x1 = math.floor(xs[i + 1] + 0.5)
            if x1 >= x0 then
                table.insert(spans, { y, x0, x1 })
            end
            i = i + 2
        end
    end
    return spans
end

-- Smooth a closed path with Chaikin corner cutting (including the pen-down/pen-up points, wrapping around first and last).
-- Each iteration takes two new points at 1/4 and 3/4 along the line from each vertex to its neighbour;
-- new points always lie on the polyline -> naturally no overshoot, no spikes, no sharp corners (converges to a quadratic uniform B-spline, C1 smooth);
-- after rounds iterations the last point returns to the first to close. Doesn't assume first = last: first drop a last point coinciding with the first,
-- then loop over the unique point sequence (the closing segment continues the pen-up trend back to the start, naturally smooth).
-- Returns the closed smoothed point sequence (for scanning the fill boundary)
function M:_smoothClosedPath(pts, rounds)
    rounds = rounds or 2
    local n = #pts
    -- Drop a last point that coincides with the first (the user already closed it); if not closed (last≠first) keep all points, the loop closes it automatically
    local first = pts[1]
    local last_p = pts[n]
    if last_p and last_p.x == first.x and last_p.y == first.y then
        n = n - 1
    end
    if n < 3 then
        return pts -- not enough to form a closed region, return as is
    end
    local cur = {}
    for i = 1, n do
        cur[i] = { x = pts[i].x, y = pts[i].y }
    end
    local m = n
    for r = 1, rounds do
        local nxt = {}
        for i = 1, m do
            -- Segment P1→P2 yields the 3/4 point (near P1) and the 1/4 point (near P2), standard corner cutting
            local p1 = cur[i]
            local p2 = cur[(i % m) + 1]
            nxt[#nxt + 1] = {
                x = p1.x * 0.75 + p2.x * 0.25,
                y = p1.y * 0.75 + p2.y * 0.25,
            }
            nxt[#nxt + 1] = {
                x = p1.x * 0.25 + p2.x * 0.75,
                y = p1.y * 0.25 + p2.y * 0.75,
            }
        end
        cur = nxt
        m = #cur
    end
    -- Close: the last point returns to the first point of the smoothed sequence (after Chaikin cutting the first point = the first segment's 3/4 point, not the original start)
    local first = cur[1]
    local last = cur[#cur]
    if last and (last.x ~= first.x or last.y ~= first.y) then
        cur[#cur + 1] = { x = first.x, y = first.y }
    end
    return cur
end

-- Stroke fill pen-up: the path is visible while drawing (delimits the area); after pen-up only the filled area remains and the path ink is cleared.
-- The path isn't committed as an element; the interior is computed from its own geometry (even-odd rule), ignoring other strokes on the canvas;
-- when degenerate (too few points/collinear) the path ink is cleared and nothing is left.
function M:_commitFillPath(s)
    if not s or not s.points or #s.points < 3 then
        -- Degenerate path: white out the drawn path ink, leaving neither path nor fill
        if s then
            local region = self:_elementRegion(s)
            if region then
                self:_redrawRegion(region)
                UIManager:setDirty(self, "partial", region)
            end
        end
        return
    end
    -- Cancel the pending stroke throttle (prevents a zombie timer refreshing the old region once more after pen-up)
    if self._stroke_repaint_fn then
        UIManager:unschedule(self._stroke_repaint_fn)
        self._stroke_repaint_fn = nil
    end
    self._stroke_repaint_pending = false
    self._stroke_region = nil
    -- Path ink region while drawing (the last point is still the original pen-up point here, covering all drawn ink)
    local path_region = self:_elementRegion(s)
    local pts = s.points
    -- Don't snap the last point (keep the original pen-up point): closing is handled by _smoothClosedPath's wrap-around,
    -- the pen-up trend continues naturally to the start, with no spike from a "snapped straight segment" at the join
    local smooth = self:_smoothClosedPath(pts)
    local spans = self:_polygonFillSpans(smooth)
    if #spans == 0 then
        -- Collinear degenerate case: clear the path ink, no fill
        if path_region then
            self:_redrawRegion(path_region)
            UIManager:setDirty(self, "partial", path_region)
        end
        return
    end
    -- src_points stores the smoothed source vertices: later rotate/scale only transform the vertices and recompute spans,
    -- no longer rebuilding geometry from quantised spans, avoiding outward drift with each transform (thin lines poking through)
    local el = { kind = "fill", spans = spans, src_points = smooth,
        gray = s.gray or self:_resolveGray(), alpha = s.alpha or self:_resolveAlpha(),
        blend = s.blend or self.alpha_blend }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el }) -- a single undo record (one undo clears the fill)
    self:_clearRedo()
    -- White out path region ∪ fill region and redraw: the fill element is redrawn, the path isn't an element so it isn't -> the path ink disappears
    local region = self:_mergeRegions(path_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "partial", region)
    self:_log("fill closed path", #spans, "spans")
end

return M
