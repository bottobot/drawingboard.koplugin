--[[--
drawingpad.tools - tool state and switching methods (DrawingCanvas mixin module).
--]]

local M = {}

-- Switch tool: clear in-progress state/selection/pending tasks, sync button labels and status bar.
-- Tapping the "Text" tool while a text object is selected with the select tool -> open the property menu (content/font/size) instead of switching tools
function M:_setTool(tool)
    if tool == "text" and self._selected and self._selected.kind == "text" then
        self:_editSelectedText()
        return
    end
    self.tool = tool
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
    self:_log("tool ->", tool)
    self:_updateStatus()
end

-- v61p cleanup: the old "long-press brush to toggle line" (_toggleBrushLine) has no entry point; since v59b brush/line are separate items

-- Long-press rectangle/circle: toggle filled/outline
function M:_toggleFilled(shape)
    if shape == "rect" then
        self.rect_filled = not self.rect_filled
    else
        self.circle_filled = not self.circle_filled
    end
    self:_log("filled", shape, self.rect_filled, self.circle_filled)
    self:_syncToolLabels() -- corner mark ▾/▴ flips with the mode
    self:_updateStatus()
end

-- Long-press eraser: toggle stroke erase (along the path) / box erase (marquee)
function M:_toggleEraserMode()
    self.eraser_mode = (self.eraser_mode == "rect") and "brush" or "rect"
    self:_log("eraser_mode ->", self.eraser_mode)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- Long-press fill: toggle tap fill (solid fill of the tapped enclosed area) / stroke fill (brush outline, closes start to end and fills the interior)
function M:_toggleFillMode()
    self.fill_mode = (self.fill_mode == "path") and "tap" or "path"
    self:_log("fill_mode ->", self.fill_mode)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- Long-press grey: toggle fixed/random mode (random: each stroke picks randomly from N evenly spaced levels in [min,max])
function M:_toggleGrayRandom()
    self.gray_random = not self.gray_random
    self:_log("gray_random ->", self.gray_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- Long-press width: toggle fixed/random mode
function M:_toggleWidthRandom()
    self.width_random = not self.width_random
    self:_log("width_random ->", self.width_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- Pick a random value from levels evenly spaced steps in [vmin,vmax] (levels=2 gives only the endpoints; vmax<=vmin degenerates to vmin)
function M:_randomLeveled(vmin, vmax, levels)
    levels = math.max(2, math.floor(levels or 8))
    if vmax <= vmin then
        return vmin
    end
    local i = math.random(levels)
    return vmin + (vmax - vmin) * (i - 1) / (levels - 1)
end

-- Resolve grey for the next stroke: fixed mode returns the current value, random mode picks a random level
function M:_resolveGray()
    if not self.gray_random then
        return self.gray
    end
    return self:_randomLeveled(self.gray_min, self.gray_max, self.gray_levels)
end

-- Resolve width for the next stroke: fixed mode returns the current value, random mode picks a random level
function M:_resolveWidth()
    if not self.width_random then
        return self.width
    end
    return self:_randomLeveled(self.width_min, self.width_max, self.width_levels)
end

-- Long-press opacity: toggle fixed/random mode (random: each stroke picks randomly from N evenly spaced levels in [min,max])
function M:_toggleAlphaRandom()
    self.alpha_random = not self.alpha_random
    self:_log("alpha_random ->", self.alpha_random)
    self:_syncToolLabels()
    self:_updateStatus()
end

-- Resolve opacity for the next stroke (0-1, 1=opaque): fixed mode returns the current value, random mode picks a random level
function M:_resolveAlpha()
    if not self.alpha_random then
        return self.alpha
    end
    return self:_randomLeveled(self.alpha_min, self.alpha_max, self.alpha_levels)
end

return M
