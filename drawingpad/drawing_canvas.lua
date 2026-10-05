--[[--
drawingpad.drawing_canvas - the drawing board's full-screen canvas widget (DrawingCanvas).
This file is the core and assembly: class definition/init/layout and painting/logging/crash protection;
methods from the feature modules are mixed in below:
- const.lua      constants and utility functions
- geometry.lua   geometry calculations and transforms (bounding box/region/scale/rotate/translate/clone)
- tools.lua      tool state and switching
- gestures.lua   gesture entry points (tap/pan/swipe/hold)
- strokes.lua    brush/eraser/shape tools and refresh throttling
- select.lua     object selection (move/copy) and transforms (scale/rotate handles)
- layers.lua     layers
- menus.lua      toolbar/status bar/centred popups/text/palette/save folder
- actions.lua    undo/redo/clear/refresh/save/close
- stylus.lua     Kobo stylus: pen strokes, pressure, palm rejection, rotation mapping (Kobo fork)

Usage (same mounting approach as tools/wbuilder.lua):
    local DrawingCanvas = require("drawingpad.drawing_canvas")
    local canvas = DrawingCanvas:new{ on_close = function() end }
    UIManager:show(canvas)
--]]

-- Self-locate: add this file's directory to package.path so require("shapes") works regardless of directory
-- (loads whether placed in the plugin directory or in frontend/)
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- Both same-directory short names (shapes/const) and the parent-directory drawingpad.* prefix resolve, regardless of where drawingpad lives
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local RenderText = require("ui/rendertext")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local logger = require("logger")
local const = require("drawingpad.const")

local DrawingCanvas = InputContainer:extend{
    name = "DrawingCanvas",
    on_close = nil,      -- close callback (used by the plugin; wbuilder tests can pass an empty function)
    log_path = nil,      -- debug log file (plugin passes the plugin directory path; nil = console only)
    tool = "brush",      -- current tool
    gray = 1.0,          -- fixed-mode current grey 0 (white)..1 (black)
    width = 4,           -- fixed-mode current line width
    -- Random grey levels (long-press the grey key to toggle fixed/random): random mode picks a grey per stroke from
    -- gray_levels evenly spaced levels in [gray_min,gray_max] ("2" = random between min/max only)
    gray_min = 0.1,
    gray_max = 0.9,
    gray_levels = 8,
    gray_random = false,
    -- Random width levels (long-press the width key to toggle fixed/random)
    width_min = 2,
    width_max = 32,
    width_levels = 8,
    width_random = false,
    -- Random opacity levels (0-1, 1=opaque) (long-press the opacity key to toggle fixed/random):
    -- random mode picks per stroke from alpha_levels evenly spaced levels in [alpha_min,alpha_max]
    alpha = 1.0,
    alpha_min = 0.3,
    alpha_max = 1.0,
    alpha_levels = 8,
    alpha_random = false,
    -- Opacity blend mode (normal=normal/multiply=multiply/dodge=linear dodge):
    -- applies only to "new elements" (recorded into el.blend at creation; redrawing old elements is unaffected);
    -- toggled in the opacity settings popup
    alpha_blend = "normal",
    tip = "circle",      -- brush tip shape (brush/line only): circle/square/triangle/triangle_inv/diamond/slash/backslash
    save_folder = "",    -- save subfolder (relative to the drawingboard/ root, "" = root)
    -- Layers: 3 independent element lists and undo/redo stacks; self.elements/undo/redo reference the current layer
    -- v61r: default layer changed to the middle layer (2) - top reserved for overlay annotations, bottom for the underdrawing, new content goes to middle by default
    active_layer = 2,
    font = nil,          -- text font (font filename in the fonts directory, default taken at init)
    font_size = 24,      -- text font size (continuously adjustable)
    _minimized = false,  -- whether the toolbar is minimised
    preview = nil,       -- preview element shown after a shape tool rests for 1s (cleared on pen-up/move)
    rect_filled = false,   -- rectangle filled/outline (long-press rectangle to toggle)
    circle_filled = false, -- circle filled/outline (long-press circle to toggle)
    eraser_mode = "brush", -- eraser: brush=stroke erase (along the path) / rect=box erase (marquee) (long-press eraser to toggle)
    fill_mode = "tap",  -- fill: tap=tap-fill an enclosed area / path=brush outline, closes start to end and fills the interior (long-press to toggle)
    select_mode = "move",  -- select tool: move=move / copy=copy (long-press the select button to toggle)
    -- Kobo fork (stylus.lua), persisted via const.SETTING_KEYS:
    pressure_sensitive = true, -- pen pressure -> stroke width
    finger_draw = "auto",      -- "auto" (off after the first pen event of the session) / "on" / "off"
    export_folder = "",        -- PNG export folder ("" = DataStorage:getDataDir() .. "/drawingboard")
    -- Modal: unregistered gestures (swipe/hold etc.) don't pass through to the window below
    stop_events_propagation = true,
}

function DrawingCanvas:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true -- UIManager repaint hint
    -- Random grey/width use math.random; KOReader's frontend/random.lua isn't guaranteed to be loaded,
    -- so seed once here to get a different random sequence each time the board opens
    math.randomseed(os.time())
    -- Layers: 3 independent element lists and undo/redo stacks; self.elements/undo/redo are references to the current layer,
    -- rebound on layer switch, so existing element read/write and undo/redo code needn't be layer-aware
    self.layers = { {}, {}, {} }
    self.layers_undo = { {}, {}, {} }
    self.layers_redo = { {}, {}, {} }
    self.active_layer = 2 -- v61r: default middle layer (top reserved for annotations, bottom for the underdrawing)
    self.elements = self.layers[2]   -- current layer elements (draw order)
    self.undo = self.layers_undo[2]  -- undo stack (operation records: {kind="add",el} / {kind="del",els,idxs} / {kind="move",el,dx,dy} / {kind="transform",el,orig,final})
    self.redo = self.layers_redo[2]  -- redo stack (operation records)
    self.layer_visible = { true, true, true } -- per-layer shown/hidden (long-press the layer key to toggle; hidden = not rendered, not exported)
    self.layer_alpha = { 1.0, 1.0, 1.0 } -- per-layer overall opacity (layer panel "current layer opacity"; 1=opaque, per session)
    -- Visibility-toggle ping-pong cache: _vis_cache = {mask=visible-layer mask, bb=the full image for that state}.
    -- Invalidated on any element change; when toggling back and forth (comparing layers), from the 2nd time on the whole buffer is swapped, zero redraw
    self._vis_cache = nil
    self._canvas_mask = nil -- visible-layer mask matching canvas_bb's current content
    self._stroke = nil   -- brush/eraser stroke in progress
    self._shape_start = nil -- shape tool anchor point
    self._stroke_region = nil -- refresh region accumulated during stroke throttling
    self._stroke_repaint_pending = false -- whether a throttled redraw is already queued
    -- UIManager:scheduleIn returns nil so there is no task handle, but unschedule cancels by "closure reference",
    -- so store the same closure used for scheduling; only then can close/tool switch actually cancel pending tasks
    self._stroke_repaint_fn = nil -- stroke throttled redraw scheduled-task closure
    self._shape_preview_fn = nil  -- shape preview scheduled-task closure
    self._stroke_pending = nil -- brush pen-down debounce: touch-down point (becomes a real stroke once movement reaches the threshold)
    self._selected = nil   -- select tool: currently selected element
    self._handle_mode = "scale" -- select tool: corner handle mode scale=scale squares / rotate=rotate dots (tap again to toggle)
    self._select_drag = nil -- select tool: drag start point (canvas coordinates)
    self._transform = nil  -- select tool: transform in progress (handle drag: {handle,x0,y0,bbox,old_region,orig})
    self._drag_preview = nil -- select tool drag (move/rotate/scale) preview element (drawn on the screen BB, doesn't pollute the canvas)
    self._drag_preview_fn = nil -- scheduled-task closure for the first preview display (shown only after resting 0.5s = stop-position debounce)
    self._drag_preview_region = nil -- accumulated preview refresh region (refreshed/erased on pen-up/move)
    self._drag_preview_pos = nil -- latest finger position recorded by the preview timer
    self._drag_preview_repaint_pending = false -- preview follow refresh throttle: only one redraw queued per window
    self._drag_preview_repaint_fn = nil -- preview follow refresh throttle scheduled-task closure

    self:_loadSettings() -- load the last saved tool settings (plugin directory; skipped when there is none)

    self:_log("init", Screen:getWidth(), "x", Screen:getHeight())
    -- Don't override a font already restored from settings (otherwise the font saved by _loadSettings is replaced by the default); only take the default on first run
    self.font = self.font or self:_defaultFont()
    self:_buildToolbar()
    self:_buildRestoreButton()
    self:_buildStatus()

    self:_updateHeader()
    self:_recreateCanvas()
    self._status = self:_statusText()

    -- Pen-down dead zone tuning: lower the gesture PAN_THRESHOLD while the board is open (pen-down curve optimisation), restored in onCloseWidget on close
    self:_applyGestureTuning()

    -- Gesture registration (same pattern as ImageViewer): the canvas area receives tap/pan/pan_release
    local range = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = range } },
        Pan = { GestureRange:new{ ges = "pan", range = range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        -- A brief rest before pen-up is classified as a hold-family gesture (hold_pan/hold_release) rather than pan/pan_release;
        -- not handling it means the previous stroke isn't committed and the next stroke wrongly joins it
        Hold = { GestureRange:new{ ges = "hold", range = range } },
        HoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
        -- Fast drags are classified as swipe rather than pan; must be registered, otherwise fast drawing does nothing
        Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        -- When a flick changes direction, a fast drag is classified as multiswipe rather than swipe;
        -- unregistered, it is swallowed by stop_events_propagation, and in-progress stroke-fill/brush strokes never get their finishing event and linger
        MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
        TwoFingerPan = { GestureRange:new{ ges = "two_finger_pan", range = range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = range } },
    }
    -- Header widget goes in self[1] (events reach child widgets first; when minimised it becomes the "Menu" restore button)
    self[1] = self.toolbar

    -- Devices with hardware keys such as Kindle: Back = close the board (same unsaved-changes confirmation)
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

-- ============================ Layout and painting ============================

-- Bottom occluded height: normal = toolbar + status bar (the occluded strip at the bottom of the canvas, not drawable);
-- minimised = 0 (toolbar hidden, canvas fills the whole screen)
function DrawingCanvas:_updateHeader()
    if self._minimized then
        self.header_h = 0
    else
        self.header_h = self.toolbar_h + self.status_h
    end
end

-- Canvas is always full-screen size (coordinates = screen coordinates, no shift when toggling minimise); redrawn from the element stack
function DrawingCanvas:_recreateCanvas()
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    if self.canvas_bb and self.canvas_bb.free then
        self.canvas_bb:free()
    end
    -- Canvas size may change: release the ping-pong cache as well
    self:_invalidateVisCache()
    self.canvas_w, self.canvas_h = w, h
    self.canvas_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    self.canvas_bb:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    self:_drawAllLayers()
    self._canvas_mask = self:_visibleMask()
end

-- Replay elements from all layers onto the canvas (layer order = draw order: bottom -> middle -> top, upper covers lower;
-- insertion order within a layer; hidden layers skipped)
function DrawingCanvas:_drawAllLayers()
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                if el.kind == "text" then
                    self:_drawTextTo(self.canvas_bb, el, li)
                else
                    shapes.drawElement(self:_alphaBB(self.canvas_bb, el, li), el, Blitbuffer.gray(el.gray))
                end
            end
        end
    end
end

-- Element draw target: returns a blending proxy bb (shapes.alphaProxy) when the element/its layer has opacity, otherwise the original bb.
-- Effective opacity = element alpha × layer alpha; layer_idx defaults to the current layer
-- (live strokes/direct commits all land on the current layer; _drawAllLayers/_redrawRegion pass the layer number explicitly).
-- Screen previews are drawn on the Screen BB (type varies by device, e.g. BB4): blending is disabled when it isn't BB8,
-- and the preview falls back to opaque (preview only; after commit the canvas still blends correctly)
function DrawingCanvas:_alphaBB(bb, el, layer_idx)
    local eff = ((el and el.alpha) or 1)
        * ((self.layer_alpha and self.layer_alpha[layer_idx or self.active_layer]) or 1)
    if eff >= 0.999 then
        return bb
    end
    local ok, t = pcall(bb.getType, bb)
    if ok and t ~= Blitbuffer.TYPE_BB8 then
        return bb
    end
    -- Blend mode is per element (recorded at creation); old elements/live strokes without a blend field = normal
    return shapes.alphaProxy(bb, eff, el and el.blend)
end

-- Layer visibility toggle: if the target state has a cached image, swap the whole buffer (zero redraw); otherwise replay once
-- and keep the old-state canvas as cache - alternating toggles (comparing layers) all hit from the 2nd time on.
-- Any element change (_redrawRegion/_renderAll) invalidates the cache, falling back to one plain replay
function DrawingCanvas:_applyVisibilityToggle()
    local new_mask = self:_visibleMask()
    local old_mask = self._canvas_mask or new_mask
    if self._vis_cache and self._vis_cache.mask == new_mask then
        self._vis_cache.bb, self.canvas_bb = self.canvas_bb, self._vis_cache.bb
        self._vis_cache.mask = old_mask
    else
        local old_canvas = self.canvas_bb
        local spare = self._vis_cache and self._vis_cache.bb
        self._vis_cache = nil
        if not spare then
            spare = Blitbuffer.new(self.canvas_w, self.canvas_h, Blitbuffer.TYPE_BB8)
        end
        self.canvas_bb = spare
        spare:paintRect(0, 0, self.canvas_w, self.canvas_h, Blitbuffer.COLOR_WHITE)
        self:_drawAllLayers()
        self._vis_cache = { mask = old_mask, bb = old_canvas }
    end
    self._canvas_mask = new_mask
    UIManager:setDirty(self, "full")
end

-- Visible-layer mask (1=bottom, 2=middle, 4=top)
function DrawingCanvas:_visibleMask()
    local mask = 0
    for li = 1, 3 do
        if self.layer_visible[li] then
            mask = mask + 2 ^ (li - 1)
        end
    end
    return mask
end

-- Element content changed: invalidate cached images for non-current states (region replay maintains only the canvas's current state)
function DrawingCanvas:_invalidateVisCache()
    if self._vis_cache then
        if self._vis_cache.bb and self._vis_cache.bb.free then
            self._vis_cache.bb:free()
        end
        self._vis_cache = nil
    end
end

-- Minimise/restore toolbar: canvas fills the whole screen, a "Menu" button remains in the top-left to restore
function DrawingCanvas:_toggleMinimize()
    self:_setMinimized(not self._minimized)
end

function DrawingCanvas:_setMinimized(min)
    if self._minimized == min then
        return
    end
    self._minimized = min
    self:_invalidateTasks()
    self._stroke = nil
    self._stroke_pending = nil
    self._shape_start = nil
    self._erase_path = nil
    self:_cancelShapePreview()
    self._shape_preview_region = nil
    self._shape_pos = nil
    self._select_drag = nil
    self._transform = nil
    self:_setSelected(nil)
    self:_updateHeader()
    -- The always-full-screen canvas isn't rebuilt: coordinates are screen-anchored, content stays put after toggling (only the header covers/uncovers)
    -- Header widget switch: when minimised only the "Menu" button remains, so the hidden toolbar can't swallow taps
    self[1] = min and self.restore_btn or self.toolbar
    self:_log(min and "minimized" or "restored")
    UIManager:setDirty(self, "full")
end

function DrawingCanvas:_buildStatus()
    self._status = self:_statusText()
end

-- InputContainer:paintTo only paints self[1]; here we take over fully: canvas + bottom toolbar/status bar + previews
function DrawingCanvas:paintTo(bb, x, y)
    if self.dimen then
        self.dimen.x = x
        self.dimen.y = y
    end
    -- Kobo fork: live pen stroke frames only re-blit the dirty rectangle (stylus.lua; falls through when not applicable)
    if self._pen_clip_paint and self._stylusClipPaint and self:_stylusClipPaint(bb, x, y) then
        return
    end
    -- Canvas shown full-screen (coordinates = screen coordinates, top content visible; bottom covered by toolbar/status bar)
    bb:blitFrom(self.canvas_bb, x, y, 0, 0, self.canvas_w, self.canvas_h)
    if not self._minimized then
        -- Status bar: very bottom of the screen (text centred); background 50% grey (formerly near-black), black text for contrast
        local status_y = y + self.canvas_h - self.status_h
        bb:paintRect(x, status_y, self.canvas_w, self.status_h, Blitbuffer.COLOR_LIGHT_GRAY)
        local status_text = self._status or ""
        local st_face = Font:getFace("smallinfofont", 15)
        -- v57 overflow truncation: when text exceeds 95% of the canvas, cut the tail (tool name comes first and is kept; trailing mode hints
        -- such as [Redo]/[Clear] have the lowest priority and go first), ending with an ellipsis. Backs off per UTF-8 character, triggered only on overflow
        local st_size = RenderText:sizeUtf8Text(0, nil, st_face, status_text, false, false)
        local st_w = (st_size and st_size.x) or 0
        local max_w = math.floor(self.canvas_w * 0.95)
        if st_w > max_w and #status_text > 0 then
            local function trimLastChar(s)
                local i = #s
                while i > 1 do
                    local b = s:byte(i)
                    if b < 128 or b >= 192 then break end -- UTF-8 lead byte
                    i = i - 1
                end
                return s:sub(1, math.max(0, i - 1))
            end
            while #status_text > 0
                and RenderText:sizeUtf8Text(0, nil, st_face, status_text .. "…", false, false).x > max_w do
                status_text = trimLastChar(status_text)
            end
            status_text = status_text .. "…"
            st_w = RenderText:sizeUtf8Text(0, nil, st_face, status_text, false, false).x
        end
        local st_x = x + math.floor(math.max(0, (self.canvas_w - st_w) / 2))
        RenderText:renderUtf8Text(bb, st_x, status_y + math.floor(self.status_h * 0.75),
            st_face, status_text, false, false, Blitbuffer.gray(1))
        -- Toolbar: above the status bar
        self.toolbar:paintTo(bb, x, y + self.canvas_h - self.toolbar_h - self.status_h)
    end
    if self._minimized then
        -- After minimising, the "Menu" restore button is fixed in the bottom-left corner, not covering content at the top of the canvas
        local restore_h = Screen:scaleBySize(48)
        local ok, size = pcall(function() return self.restore_btn:getSize() end)
        if ok and size and size.h then
            restore_h = size.h
        end
        self.restore_btn:paintTo(bb, x, y + self.canvas_h - restore_h)
    end
    -- Preview shown after a shape tool rests for 1s (drawn on the screen BB, doesn't pollute the canvas)
    -- v62s: semi-transparent shape previews are drawn **opaque** (same policy as stroke previews, chosen by the user): the real device's screen BB
    -- is BB8, and going through the _alphaBB proxy blends per pixel over the whole shape area on every redraw, so dragging large shapes stutters noticeably;
    -- an opaque preview takes the native fast path, and after pen-up commit the canvas replay gives the correct semi-transparency
    if self.preview then
        shapes.drawElement(bb, self.preview, Blitbuffer.gray(self.preview.gray), x, y)
    end
    -- Preview after resting during a select-tool drag (move/rotate) (drawn on the screen BB, doesn't pollute the canvas)
    -- v61s: text previews must go through _drawTextTo - shapes.drawElement doesn't recognise text (text rendering
    -- lives in the menus module); the old code drew nothing for text previews = root cause of "no preview when moving/copying text"
    if self._drag_preview then
        local pv = self._drag_preview
        if pv.kind == "text" then
            local tmp = {}
            for k, v in pairs(pv) do
                tmp[k] = v
            end
            tmp.x = (pv.x or 0) + x
            tmp.y = (pv.y or 0) + y
            self:_drawTextTo(bb, tmp)
        else
            -- v62s: drag previews are also made opaque (speed first; the canvas replay restores semi-transparency after release)
            shapes.drawElement(bb, pv, Blitbuffer.gray(pv.gray), x, y)
        end
    end
    -- Selected-object highlight box (drawn on the screen BB, doesn't pollute the canvas).
    -- Tilted ellipses/rotated rectangles (poly) get a closed thin frame along the OBB (hugging the boundary); everything else gets an axis-aligned box
    if self._selected then
        local el = self._selected
        local pts = self:_frameCorners(el)
        if pts then
            local hc = Blitbuffer.gray(const.UI_GRAY_HIGHLIGHT)
            local rotated = (el.kind == "circle" and (el.rot or 0) ~= 0) or el.kind == "poly"
            if rotated then
                for i = 1, #pts do
                    local p1, p2 = pts[i], pts[(i % #pts) + 1]
                    shapes.thickLine(bb, math.floor(p1.x), math.floor(p1.y),
                        math.floor(p2.x), math.floor(p2.y), 2, hc, "circle")
                end
            else
                local b = el._bbox or self:_elementBBox(el)
                if b then
                    local pad = 3
                    local hx0 = math.max(0, math.floor(b.x0) - pad)
                    local hy0 = math.max(0, math.floor(b.y0) - pad)
                    local hx1 = math.min(self.canvas_w, math.ceil(b.x1) + pad)
                    local hy1 = math.min(self.canvas_h, math.ceil(b.y1) + pad)
                    if hx1 > hx0 and hy1 > hy0 then
                        bb:paintRect(hx0, hy0, hx1 - hx0, 1, hc)
                        bb:paintRect(hx0, hy1 - 1, hx1 - hx0, 1, hc)
                        bb:paintRect(hx0, hy0, 1, hy1 - hy0, hc)
                        bb:paintRect(hx1 - 1, hy0, 1, hy1 - hy0, hc)
                    end
                end
            end
        end
    end
    -- Transform handles (select tool + a selected object): four corner handles, positioned by _frameCorners (tilted objects anchor on OBB corners).
    -- Scale mode = solid squares; tap again to switch to rotate mode = small solid dots; text doesn't toggle (always squares)
    if self.tool == "select" and self._selected then
        local pts = self:_frameCorners(self._selected)
        if pts then
            local hs = Screen:scaleBySize(6) -- half-width of the scale handle square (12px, small so it doesn't obscure; hit radius 48/text 64)
            local hc = Blitbuffer.gray(const.UI_GRAY_HIGHLIGHT) -- same highlight grey as the selection box (unified UI)
            local rotate = self._handle_mode == "rotate"
            local function cornerAt(px, py)
                if rotate then
                    -- Rotate handle: small solid dot (radius about 5px; hits still use the four corner centres ±HANDLE_HIT_RADIUS)
                    local r = Screen:scaleBySize(5)
                    bb:paintCircle(math.floor(px), math.floor(py), r, hc, r)
                else
                    bb:paintRect(math.floor(px) - hs, math.floor(py) - hs, hs * 2, hs * 2, hc)
                end
            end
            for _, p in ipairs(pts) do
                cornerAt(p.x, p.y)
            end
        end
    end
end

-- Partial redraw: ① replay the current layer's cached region (element add/remove/transform only happens on the current layer);
-- ② canvas region = each visible layer's cached region composited in order. Elements are drawn into a "region-sized temp BB" first and then written back -
-- can't draw directly: replaying large elements (e.g. large fills) overruns the region, painting pixels outside the region that were "covered by higher-layer elements"
-- back with lower-layer ink (large grey fill below + white fill above = grey over white). The temp BB guarantees pixels outside the region
-- are untouched and pixels inside match a full replay exactly.
function DrawingCanvas:_redrawRegion(region)
    if not self.canvas_bb or not region then
        return
    end
    local rx0, ry0 = math.floor(region.x), math.floor(region.y)
    local rx1 = math.min(self.canvas_w, math.ceil(region.x + region.w))
    local ry1 = math.min(self.canvas_h, math.ceil(region.y + region.h))
    if rx1 <= rx0 or ry1 <= ry0 then
        return
    end
    local rw, rh = rx1 - rx0, ry1 - ry0
    -- Element content changed: invalidate the visibility-toggle cached image
    self:_invalidateVisCache()
    -- Intersecting elements are drawn in layer order into a "region-sized temp BB" and then written back - can't draw straight into canvas_bb:
    -- replaying large elements (e.g. large fills) overruns the region, painting pixels outside the region that were "covered by higher-layer elements"
    -- back with lower-layer ink (large grey fill below + white fill above = grey over white). The temp BB guarantees pixels outside the region
    -- are untouched and pixels inside match a full replay exactly.
    local tmp = Blitbuffer.new(rw, rh, Blitbuffer.TYPE_BB8)
    tmp:paintRect(0, 0, rw, rh, Blitbuffer.COLOR_WHITE)
    for li = 1, 3 do
        if self.layer_visible[li] then
            for _, el in ipairs(self.layers[li]) do
                local b = el._bbox or self:_elementBBox(el)
                if b and b.x0 <= rx1 and b.x1 >= rx0 and b.y0 <= ry1 and b.y1 >= ry0 then
                    local ok, err = pcall(function()
                        if el.kind == "text" then
                            -- _drawTextTo has no offset parameter: shallow-copy and translate into the temp BB's coordinate system
                            local t = {}
                            for k, v in pairs(el) do
                                t[k] = v
                            end
                            t.x = (el.x or 0) - rx0
                            t.y = (el.y or 0) - ry0
                            self:_drawTextTo(tmp, t, li)
                        else
                            -- drawElement self-clips to the BB size; negative offsets automatically discard ink outside the region
                            shapes.drawElement(self:_alphaBB(tmp, el, li), el, Blitbuffer.gray(el.gray), -rx0, -ry0)
                        end
                    end)
                    if not ok then
                        self:_log("_redrawRegion: element render error:", tostring(err))
                    end
                end
            end
        end
    end
    self.canvas_bb:blitFrom(tmp, rx0, ry0, 0, 0, rw, rh)
    tmp:free()
end

-- Redraw the whole canvas from the element stack (used on clear/init; dispatches text and shapes)
function DrawingCanvas:_renderAll()
    if not self.canvas_bb then
        self:_log("_renderAll: canvas_bb is nil, skipping")
        return
    end
    self:_invalidateVisCache()
    self.canvas_bb:paintRect(0, 0, self.canvas_w, self.canvas_h, Blitbuffer.COLOR_WHITE)
    self:_drawAllLayers()
    self._canvas_mask = self:_visibleMask()
    UIManager:setDirty(self, "partial")
end

-- ============================ Debug logging ============================

function DrawingCanvas:_log(...)
    if not const.LOG_ENABLED then
        return
    end
    local parts = { os.date("%x %X") }
    for i = 1, select("#", ...) do
        table.insert(parts, tostring(select(i, ...)))
    end
    local line = table.concat(parts, " ")
    logger.info("drawingpad: " .. line)
    if self.log_path then
        local ok, f = pcall(io.open, self.log_path, "a")
        if ok and f then
            f:write(line .. "\n")
            f:close()
        end
    end
end

-- ============================ Module mixing and stability hardening ============================

-- Merge the method tables of all feature modules (all attached to DrawingCanvas; cross-module calls go through self:)
for _, mod in ipairs({
    require("drawingpad.geometry"),
    require("drawingpad.tools"),
    require("drawingpad.gestures"),
    require("drawingpad.strokes"),
    require("drawingpad.select"),
    require("drawingpad.layers"),
    require("drawingpad.menus"),
    require("drawingpad.actions"),
    require("drawingpad.stylus"),
}) do
    for name, fn in pairs(mod) do
        DrawingCanvas[name] = fn
    end
end

-- Kobo fork: palm rejection filter around the canvas gesture handlers (inside the pcall wrappers below)
require("drawingpad.stylus").installFingerFilter(DrawingCanvas)

-- Neither KOReader's event callbacks nor scheduleIn tasks are pcall-protected: any Lua error
-- bubbles straight up and crashes the whole program (crash.log records the traceback). Wrap every entry-point callback in a pcall;
-- errors are only written to the debug log and the event is consumed as usual, so the program no longer blows up.
local function wrapHandler(orig)
    return function(self, ...)
        local ok, err = pcall(orig, self, ...)
        if not ok then
            self:_log("handler error:", tostring(err))
        end
        return true
    end
end
for _, name in ipairs({
    "onTap", "onPan", "onPanRelease", "onSwipe", "onMultiSwipe",
    "onHold", "onHoldPan", "onHoldRelease",
    "onTwoFingerPan", "onPinch",
    "_maybeShowShapePreview", "_flushStrokeRepaint",
    "onClose", "onCloseWidget",
    "_undo", "_redo", "_clearAll", "_save", "_onClose",
    "_toggleMinimize", "_toggleFilled", "_toggleEraserMode",
    "_setTool", "_pickGray", "_pickWidth", "_pickAlpha",
    "_pickFont", "_pickFontSize", "_commitText",
    "_commitDot", "_toggleSelectMode",
    "_toggleGrayRandom", "_toggleWidthRandom", "_toggleAlphaRandom",
    "_switchLayer", "_toggleLayerVisible", "_showTipMenu", "_showAbout",
    "_showCategoryMenu", "_refreshToolbar", "_showSettingDialog",
    "_refreshCanvas", "_pickSaveFolder", "_doSaveFlow", "_finishTransform",
    "_pickLayerAlpha",
    "_toggleStylusPressure", "_cycleFingerDraw", "_pickExportFolder",
}) do
    if DrawingCanvas[name] then
        DrawingCanvas[name] = wrapHandler(DrawingCanvas[name])
    end
end

return DrawingCanvas
