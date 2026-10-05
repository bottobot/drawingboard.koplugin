--[[--
drawingpad.layers - layer methods (3 layers, each independent) (DrawingCanvas mixin module).

v62d: module-side visibility ping-pong cache (core file untouched - the real device runs a rolled-back core that must not be changed).
This module defines _applyVisibilityToggle/_visibleMask/_invalidateVisCache (the rolled-back core on the device lacks them;
the newer core in the dev tree has same-named methods with identical logic; modules merge after the core -> this module's version wins on both).
Cache invalidation when canvas content changes is called directly by the core's _redrawRegion/_renderAll
(already added to the patched device core; the dev-tree core always had it); this module only provides the cache itself.
This restores v61x speed for visibility toggles (alternating toggles redraw nothing from the 2nd time on, at the cost of holding one extra full-canvas BB,
about 1.5MB on PW3, freed when the board closes; if device memory is tight, delete the "ping-pong cache" section of this file to fall back to the replay path).
--]]

local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")

local M = {}

-- Switch to the given layer (1..3): rebind element/undo/redo references, clear in-progress state and selection.
function M:_switchLayer(n)
    n = ((n - 1) % 3) + 1
    if n == self.active_layer then
        return
    end
    self.active_layer = n
    self.elements = self.layers[n]
    self.undo = self.layers_undo[n]
    self.redo = self.layers_redo[n]
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
    self:_syncToolLabels()
    self:_log("layer ->", n)
    self:_updateStatus()
    UIManager:setDirty(self, "full")
end

-- Long-press layer: toggle the current layer shown/hidden (hidden layers are not rendered and not exported to PNG)
function M:_toggleLayerVisible()
    self.layer_visible[self.active_layer] = not self.layer_visible[self.active_layer]
    self:_log("layer visible", self.active_layer, self.layer_visible[self.active_layer])
    self:_syncToolLabels() -- corner mark ▾/▴ flips with visibility
    self:_updateStatus()
    -- Ping-pong cache: if the target state has a cached image, swap the whole buffer (zero redraw); otherwise replay once and cache the old state
    self:_refreshAfterVisibilityToggle()
end

-- Layer panel (v59d): toggle visibility of any layer (current layer goes through _toggleLayerVisible; other layers just flip the flag)
function M:_toggleLayerVisibleOf(n)
    if self.active_layer == n then
        return self:_toggleLayerVisible()
    end
    self.layer_visible[n] = not self.layer_visible[n]
    self:_log("layer visible", n, self.layer_visible[n])
    self:_syncToolLabels()
    self:_refreshAfterVisibilityToggle()
end

-- Visibility change screen refresh. The ping-pong cache (since v61w) is only a "whole-buffer swap" speedup, not the feature itself -
-- the real device once had its core file rolled back to an old cache-less version (missing _applyVisibilityToggle) while these two call sites
-- remained, so long-press layer broke entirely (the error was swallowed by wrapHandler, leaving only one log line).
-- So probe by capability here: this module provides _applyVisibilityToggle (see file header), so both core versions work
function M:_refreshAfterVisibilityToggle()
    if self._applyVisibilityToggle then
        self:_applyVisibilityToggle()
    else
        self:_renderAll()
    end
end

-- ============================ Visibility ping-pong cache (module side, v62d) ============================

-- Visible-layer mask (1=bottom, 2=middle, 4=top)
function M:_visibleMask()
    local mask = 0
    for li = 1, 3 do
        if self.layer_visible[li] then
            mask = mask + 2 ^ (li - 1)
        end
    end
    return mask
end

-- Invalidate the visibility ping-pong cache (called on element content changes/board close; nil-safe, old cores can call it freely)
function M:_invalidateVisCache()
    if self._vis_cache then
        if self._vis_cache.bb and self._vis_cache.bb.free then
            self._vis_cache.bb:free()
        end
        self._vis_cache = nil
    end
end

-- Layer visibility toggle: if the target state has a cached image, swap the whole buffer (zero redraw); otherwise replay once
-- and keep the old-state canvas as cache - alternating toggles (comparing layers) all hit from the 2nd time on.
-- Falls back to one plain replay when the canvas size mismatches (in theory only after a screen change/rebuild) or there is no cache
function M:_applyVisibilityToggle()
    local new_mask = self:_visibleMask()
    local old_mask = self._canvas_mask or new_mask
    local cw, ch = self.canvas_w, self.canvas_h
    local cache = self._vis_cache
    if cache and cache.mask == new_mask and cache.w == cw and cache.h == ch then
        self._vis_cache.bb, self.canvas_bb = self.canvas_bb, cache.bb
        self._vis_cache.mask = old_mask
    else
        local old_canvas = self.canvas_bb
        local spare = cache and cache.w == cw and cache.h == ch and cache.bb or nil
        self._vis_cache = nil
        if not spare then
            spare = Blitbuffer.new(cw, ch, Blitbuffer.TYPE_BB8)
        end
        spare:paintRect(0, 0, cw, ch, Blitbuffer.COLOR_WHITE)
        self.canvas_bb = spare
        self:_drawAllLayers()
        self._vis_cache = { mask = old_mask, bb = old_canvas, w = cw, h = ch }
    end
    self._canvas_mask = new_mask
    UIManager:setDirty(self, "full")
end

-- ============================ Layer panel: current-layer opacity ============================

-- Layer panel "current layer opacity" (0-100%, 100=opaque): slider + preset steps.
-- showValuePicker does not fire onchange while dragging (applies only on release/preset/tap); each apply does a full replay
-- (the layer factor affects every element in the layer, so use _renderAll rather than the visibility ping-pong - the cached image has the old opacity and must be invalidated)
function M:_pickLayerAlpha()
    local n = self.active_layer
    local cur = (self.layer_alpha and self.layer_alpha[n]) or 1
    self:_showValuePicker{
        title = "Layer opacity(100%=opaque)",
        value = math.floor(cur * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            self.layer_alpha[n] = v / 100
            self:_renderAll()
            -- Whole-layer grey values changed; partial would leave ghosting, so add one full-screen "ui" refresh to even it out
            UIManager:setDirty(self, "ui")
        end,
        onclose = function()
            self:_syncToolLabels() -- panel item text includes the current value; refresh right after the change
            self:_log("layer alpha", n, self.layer_alpha[n])
        end,
    }
end

return M
