--[[--
drawingpad.menus - toolbar/status bar/centred popups/text insertion/palette/save folder selection (DrawingCanvas mixin module).
--]]

-- Self-locate: add this file's directory to package.path so require("shapes") works regardless of directory
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- Both same-directory short names (shapes/const) and the parent-directory drawingpad.* prefix resolve, regardless of where drawingpad lives
    package.path = __self_dir .. "/?.lua;" .. package.path
end
local shapes = require("shapes")
local components = require("drawingpad.components")

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local RenderText = require("ui/rendertext")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local ButtonTable = require("ui/widget/buttontable")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")
local T = require("ffi/util").template
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")

local M = {}

-- ============================ Toolbar / category menus ============================

-- v59b top-level bottom bar turned into icons (modelled on the reader's TouchMenu bottom bar): 7 entries using Button{icon},
-- 7 equal-width cells; active state = the top rule breaks below the entry whose panel is currently open (same as TouchMenu).
-- Icon names are in const.TOOLBAR_ICONS (tools/properties/functions/refresh/save/hide/close);
-- self._open_cat records the currently open category panel (nil = none, rule unbroken).
-- Second-level panel items are flattened: no long-press, all former long-press secondary functions are separate items (see TOGGLE_BUTTONS);
-- background rule: active tool items (including the filled-rect/copy/path-fill/box-erase variants) are light grey, everything else white.
function M:_buildToolbar()
    local Screen_w = Screen:getWidth()
    local n = #const.TOOLBAR_ICONS
    local cell_w = math.floor(Screen_w / n)
    local icon_px = Screen:scaleBySize(const.TOOLBAR_ICON_PX)
    local row_h = icon_px + 2 * Size.padding.default
    -- The plugin's bundled icons (resource files shipped in <plugin dir>/drawingpad/icons/) are installed in two places:
    -- ① the user icons directory (newer IconWidget checks it first); ② the official resources/icons/mdlight
    -- (older IconWidget has no user-directory lookup, so mdlight is the only directory guaranteed to be searched;
    --  relative path based on the koreader process CWD). Overwritten when content differs from the installed copy.
    -- v61n: must run before this function constructs the buttons - if IconWidget can't find a new icon at construction it
    -- caches ICON_NOT_FOUND in ICONS_PATH (permanently for the process); installed too late, the real device shows an exclamation mark
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        -- This module = <koplugin>/drawingpad/menus.lua -> icon resources are in the sibling icons/
        local src_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") .. "/icons"
        local targets = {
            DataStorage:getDataDir() .. "/icons",
            "resources/icons/mdlight",
        }
        if lfs.attributes(src_dir, "mode") ~= "directory" then
            return
        end
        for name in lfs.dir(src_dir) do
            if name:match("%.svg$") then
                local f = io.open(src_dir .. "/" .. name, "r")
                local content = f and f:read("*a")
                if f then
                    f:close()
                end
                if content then
                    for _, icons_dir in ipairs(targets) do
                        local installed = io.open(icons_dir .. "/" .. name, "r")
                        local existing = installed and installed:read("*a")
                        if installed then
                            installed:close()
                        end
                        if existing ~= content then
                            if lfs.attributes(icons_dir, "mode") ~= "directory" then
                                lfs.mkdir(icons_dir)
                            end
                            local w = io.open(icons_dir .. "/" .. name, "w")
                            if w then
                                w:write(content)
                                w:close()
                            end
                        end
                    end
                end
            end
        end
    end)
    -- One row of icon buttons (6 equal-width cells, centred); v61k: icon background feedback removed (category highlight grey/refresh flash
    -- both removed), the active indicator is just the gap in the top rule
    local cells = {}
    for i, d in ipairs(const.TOOLBAR_ICONS) do
        -- Gotcha: with local btn = Button:new{ callback referencing btn }, the constructor table is evaluated before the local takes effect,
        -- so btn inside the closure is the global (nil) - the declaration must be split
        local btn
        btn = Button:new{
            id = d.id,
            icon = d.icon,
            icon_rotation_angle = d.icon_rotation_angle or 0,
            icon_width = icon_px,
            icon_height = icon_px,
            bordersize = 0,
            callback = function()
                -- v62g: top-level icon centre x (popup horizontal anchoring)
                self._anchor_x = self:_anchorX(btn)
                if d.id == "cat_tool" then
                    self:_showCategoryMenu("tool")
                elseif d.id == "cat_prop" then
                    self:_showCategoryMenu("prop")
                elseif d.id == "cat_func" then
                    self:_showCategoryMenu("func")
                elseif d.id == "cat_layer" then
                    self:_showCategoryMenu("layer")
                elseif d.id == "refresh_btn" then
                    self:_refreshCanvas()
                elseif d.id == "hide_btn" then
                    self:_toggleMinimize()
                end
            end,
        }
        cells[i] = self:_toolbarCell(btn, cell_w, row_h)
        -- v62g: record icon buttons (for popup horizontal anchoring); on tap, note the icon centre x
        self._toolbar_btns = self._toolbar_btns or {}
        self._toolbar_btns[d.id] = btn
    end
    -- Top rule: leave a gap below the entry of the currently open panel (same active indicator as TouchMenu)
    local line_h = math.max(1, Screen:scaleBySize(1))
    local function line(w)
        return LineWidget:new{
            dimen = Geom:new{ w = w, h = line_h },
            background = Blitbuffer.COLOR_BLACK,
            style = "solid",
        }
    end
    local segs = {}
    local active_i
    local CAT_BY_ID = { cat_tool = "tool", cat_prop = "prop", cat_layer = "layer", cat_func = "func" }
    for i, d in ipairs(const.TOOLBAR_ICONS) do
        if CAT_BY_ID[d.id] and CAT_BY_ID[d.id] == self._open_cat then
            active_i = i
        end
    end
    if active_i then
        local gap_w = icon_px + Screen:scaleBySize(8)
        local gc = (active_i - 1) * cell_w + math.floor(cell_w / 2)
        local gl = math.max(0, gc - math.floor(gap_w / 2))
        local gr = math.min(Screen_w, gc + math.floor(gap_w / 2))
        if gl > 0 then
            segs[#segs + 1] = line(gl)
        end
        segs[#segs + 1] = HorizontalSpan:new{ width = gr - gl }
        if gr < Screen_w then
            segs[#segs + 1] = line(Screen_w - gr)
        end
    else
        segs[#segs + 1] = line(Screen_w)
    end
    self.toolbar = VerticalGroup:new{
        HorizontalGroup:new{ unpack(segs) },
        HorizontalGroup:new{ unpack(cells) },
    }
    local ok, size = pcall(function() return self.toolbar:getSize() end)
    self.toolbar_h = (ok and size and size.h) or Screen:scaleBySize(52)
    self.status_h = Screen:scaleBySize(28)
end

-- Top-level control centre x (popup horizontal anchor): buttons only have dimen after paint; returns nil without info (popup centres itself)
function M:_anchorX(btn)
    local d = btn and btn.dimen
    if d and d.x and d.w then
        return d.x + d.w / 2
    end
    return nil
end

-- Single bottom-bar cell: icon button centred in an equal-width cell (fixed-size CenterContainer cell)
function M:_toolbarCell(btn, cell_w, row_h)
    local CenterContainer = require("ui/widget/container/centercontainer")
    return CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = row_h },
        btn,
    }
end

-- Minimise/restore (overrides the core's same-named method; takes effect through the merge order of this file):
-- the core's _setMinimized ends with a full-screen `setDirty(self, "full")` - on e-ink that's a
-- visible flash, while the only pixels that actually change are the strip at the bottom (toolbar + status bar: when minimising the canvas is uncovered,
-- when restoring the toolbar is redrawn; the floating "Menu" restore key is also in that strip). Here we only absorb the core's full-screen refresh
-- (other canvas refreshes still pass through, e.g. the region refresh from deselecting) and use a "ui" region refresh of the bottom strip instead.
function M:_toggleMinimize()
    local want = not self._minimized
    if self._minimized == want then
        return
    end
    local real_setDirty = UIManager.setDirty
    UIManager.setDirty = function(uim, widget, mode, region, dither)
        if widget == self and mode == "full" then
            return
        end
        return real_setDirty(uim, widget, mode, region, dither)
    end
    local ok, err = pcall(self._setMinimized, self, want)
    UIManager.setDirty = real_setDirty
    if not ok then
        self:_log("_toggleMinimize error:", tostring(err))
    end
    local h = self.toolbar_h + self.status_h
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = 0, y = Screen:getHeight() - h,
            w = Screen:getWidth(), h = h,
        }
    end)
end

-- Rebuild the toolbar after a category panel opens/closes (gap position changes) + "ui" refresh of the bottom region
function M:_refreshToolbar()
    if self._minimized then
        return
    end
    local old_h = self.toolbar_h
    self:_buildToolbar()
    if self[1] ~= self.restore_btn then
        self[1] = self.toolbar
    end
    local h = math.max(old_h, self.toolbar_h)
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = 0, y = Screen:getHeight() - h - self.status_h,
            w = Screen:getWidth(), h = h + self.status_h,
        }
    end)
end

-- Category panel item table (v59b flattening: long-press removed, all former long-press secondary functions split into separate items).
-- Each item: id/cat/label (+ optional text_fn for dynamic text)/active_fn (sole source of the light-grey background for tool items)/on_tap.
-- Tool variant items (filled rect/copy/path fill/box erase) set the state directly (not a toggle); active check = tool + mode;
-- close_on_tap defaults to closing the panel after tapping non-function items (function items stay open so undo/redo/clear can be tapped repeatedly).
local function toolSet(tool, fields)
    return function(s)
        s:_setTool(tool)
        if fields then
            for k, v in pairs(fields) do
                s[k] = v
            end
            s:_syncToolLabels()
            s:_updateStatus()
        end
    end
end

local TOGGLE_BUTTONS = {
    -- Tool items: variants merged into the main item (name carries a checkbox; tapping again when already active = toggle the check)
    -- v62n: English is the source language (this fork is English-only; L.t/L.x return their argument)
    { id = "brush_btn",  cat = "tool", label = "Brush",
      active_fn = function(s) return s.tool == "brush" end,
      on_tap = toolSet("brush") },
    { id = "line_btn",   cat = "tool", label = "Line",
      active_fn = function(s) return s.tool == "line" end,
      on_tap = toolSet("line") },
    { id = "rect_btn",   cat = "tool",
      -- v59e: tap = switch to the rectangle tool, long-press = toggle ☑Fill
      text_fn = function(s)
          return L.t("Rect(") .. (s.rect_filled and "☑" or "☐") .. L.t(" fill)")
      end,
      active_fn = function(s) return s.tool == "rect" end,
      on_tap = toolSet("rect"),
      on_hold = function(s) s:_setTool("rect"); s:_toggleFilled("rect") end },
    { id = "circle_btn", cat = "tool",
      text_fn = function(s)
          return L.t("Ellipse(") .. (s.circle_filled and "☑" or "☐") .. L.t(" fill)")
      end,
      active_fn = function(s) return s.tool == "circle" end,
      on_tap = toolSet("circle"),
      on_hold = function(s) s:_setTool("circle"); s:_toggleFilled("circle") end },
    { id = "text_btn",   cat = "tool", label = "Text",
      active_fn = function(s) return s.tool == "text" end,
      on_tap = toolSet("text") },
    { id = "select_btn", cat = "tool",
      -- v59g: select + copy merged (☑Copy); tap = switch to the select tool, long-press = toggle ☑Copy
      text_fn = function(s)
          return L.t("Select(") .. (s.select_mode == "copy" and "☑" or "☐") .. L.t(" copy)")
      end,
      active_fn = function(s) return s.tool == "select" end,
      on_tap = toolSet("select"),
      on_hold = function(s) s:_setTool("select"); s:_toggleSelectMode() end },
    { id = "fill_btn",   cat = "tool",
      -- v59g: tap fill + path fill merged (☑Path); tap = switch to the fill tool (tap fill), long-press = toggle ☑Path (stroke fill)
      text_fn = function(s)
          return L.t("Fill(") .. (s.fill_mode == "path" and "☑" or "☐") .. L.t(" path)")
      end,
      active_fn = function(s) return s.tool == "fill" end,
      on_tap = toolSet("fill"),
      on_hold = function(s) s:_setTool("fill"); s:_toggleFillMode() end },
    { id = "eraser_btn", cat = "tool",
      -- v59f: renamed Erase (☑Box); tap = switch to the eraser tool, long-press = toggle stroke erase/box erase
      text_fn = function(s)
          return L.t("Erase(") .. (s.eraser_mode == "rect" and L.t("☑box") or L.t("☐box")) .. ")"
      end,
      active_fn = function(s) return s.tool == "eraser" end,
      on_tap = toolSet("eraser"),
      on_hold = function(s) s:_setTool("eraser"); s:_toggleEraserMode() end },
    -- Property settings (the random check is a status display; toggled via the "Random" row in the settings popup)
    { id = "gray_btn",  cat = "prop",
      -- v59e: tap = open grey settings, long-press = toggle ☑Random
      text_fn = function(s)
          return L.t("Gray(") .. (s.gray_random and "☑" or "☐") .. L.t(" random)")
      end,
      on_tap = function(s)
          -- With a selected object, keep the selection and use element-level grey (dispatched inside _pickGray);
          -- v61o: without a selection open the global settings directly, no longer switching to the brush - property settings shouldn't change the current tool
          s:_pickGray()
      end,
      on_hold = function(s) s:_toggleGrayRandom() end },
    { id = "width_btn", cat = "prop",
      text_fn = function(s)
          return L.t("Width(") .. (s.width_random and "☑" or "☐") .. L.t(" random)")
      end,
      on_tap = function(s)
          -- Same as grey: keep the selection when an object is selected (text/fill notify that they have no line width, other objects adjust per element);
          -- v61o: no longer switches to the brush, keeps the current tool
          s:_pickWidth()
      end,
      on_hold = function(s) s:_toggleWidthRandom() end },
    { id = "alpha_btn", cat = "prop",
      -- v62: tap = open opacity settings, long-press = toggle ☑Random (same approach as grey/width); v62h: swapped with brush tip, placed after width
      text_fn = function(s)
          return L.t("Opacity(") .. (s.alpha_random and "☑" or "☐") .. L.t(" random)")
      end,
      on_tap = function(s)
          -- Same as grey: keep the selection and adjust per element when an object is selected; without a selection open global settings, current tool unchanged
          s:_pickAlpha()
      end,
      on_hold = function(s) s:_toggleAlphaRandom() end },
    { id = "tip_btn",   cat = "prop", label = "Tip",
      on_tap = function(s) s:_showTipMenu() end },
    -- Kobo fork (stylus.lua): pen settings; the two toggles keep the panel open so the new state is visible
    { id = "pressure_btn", cat = "prop", close_on_tap = false,
      text_fn = function(s)
          return L.t("Pressure sensitivity ") .. ((s.pressure_sensitive ~= false) and "☑" or "☐")
      end,
      on_tap = function(s) s:_toggleStylusPressure() end },
    { id = "finger_btn", cat = "prop", close_on_tap = false,
      text_fn = function(s) return s:_fingerDrawLabel() end,
      on_tap = function(s) s:_cycleFingerDraw() end },
    { id = "export_folder_btn", cat = "prop", label = "Export folder", close_on_tap = true,
      on_tap = function(s) s:_pickExportFolder() end },
    -- Layer items (v59f: one item per layer - ●current layer + ☐/☑hidden; tap = switch to and select the layer, long-press = toggle hidden)
    { id = "layer3_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 3 and "●" or "○")
          local vis = (s.layer_visible[3] and "☐" or "☑")
          return mark .. L.t("Top(") .. vis .. L.t("hide)")
      end,
      active_fn = function(s) return s.active_layer == 3 end,
      on_tap = function(s) s:_switchLayer(3) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(3) end },
    { id = "layer2_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 2 and "●" or "○")
          local vis = (s.layer_visible[2] and "☐" or "☑")
          return mark .. L.t("Mid(") .. vis .. L.t("hide)")
      end,
      active_fn = function(s) return s.active_layer == 2 end,
      on_tap = function(s) s:_switchLayer(2) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(2) end },
    { id = "layer1_btn", cat = "layer", close_on_tap = false,
      text_fn = function(s)
          local mark = (s.active_layer == 1 and "●" or "○")
          local vis = (s.layer_visible[1] and "☐" or "☑")
          return mark .. L.t("Bottom(") .. vis .. L.t("hide)")
      end,
      active_fn = function(s) return s.active_layer == 1 end,
      on_tap = function(s) s:_switchLayer(1) end,
      on_hold = function(s) s:_toggleLayerVisibleOf(1) end },
    { id = "layer_alpha_btn", cat = "layer", close_on_tap = true,
      -- v62: overall opacity of the current layer (fade a draft layer as a whole); text includes the current value
      text_fn = function(s)
          local v = (s.layer_alpha and s.layer_alpha[s.active_layer]) or 1
          return L.t("Layer opacity ") .. math.floor(v * 100 + 0.5) .. "%"
      end,
      on_tap = function(s) s:_pickLayerAlpha() end },
    -- Function items (the panel stays open after tapping so undo/redo/clear can be tapped repeatedly; exit/about merged in v59d)
    { id = "undo_btn",  cat = "func", label = "Undo",
      on_tap = function(s) s:_undo() end },
    { id = "redo_btn",  cat = "func", label = "Redo",
      on_tap = function(s) s:_redo() end },
    { id = "clear_btn", cat = "func", label = "Clear",
      on_tap = function(s) s:_clearAll() end },
    -- v62d: Save = project file (.drawing, can be reopened to keep editing); Export = export PNG
    -- v62e order (left -> right, top -> bottom): Undo Redo / Clear Open / Export Save / About Exit
    { id = "open_proj_btn", cat = "func", label = "Open", close_on_tap = true,
      on_tap = function(s) s:_openProject() end },
    { id = "save_btn",  cat = "func", label = "Export", close_on_tap = true,
      on_tap = function(s) s:_save() end },
    { id = "save_proj_btn", cat = "func", label = "Save", close_on_tap = true,
      on_tap = function(s) s:_saveProject() end },
    { id = "about_btn", cat = "func", label = "About",
      on_tap = function(s)
          -- Close the function panel before showing About, so the panel isn't left open underneath (popups/panels are mutually exclusive)
          if s._category_popup then
              UIManager:close(s._category_popup, "full")
          end
          s:_showAbout()
      end },
    { id = "exit_btn",  cat = "func", label = "Exit",
      on_tap = function(s) s:_onClose() end },
}
M._toggle_buttons = TOGGLE_BUTTONS

-- Build a single panel item definition: id/text/tap (no panel-closing logic; _showCategoryMenu wraps that uniformly).
-- v59e: items with on_hold get a hold_callback (long-press toggles the check: filled rect/filled circle/box erase/random grey/random width)
function M:_toggleDef(t)
    local def = {
        id = t.id,
        -- v62h: English menus (L.x dictionary lookup; compound strings in text_fn already use L.t internally)
        text = L.x(t.text_fn and t.text_fn(self) or t.label),
        callback = function()
            t.on_tap(self)
        end,
    }
    if t.enabled_fn then
        -- v59f: dynamic availability (e.g. "Font" is tappable only when a text object is selected); Button enabled=false greys it out automatically
        def.enabled = t.enabled_fn(self)
    end
    if t.on_hold then
        def.hold_callback = function()
            -- Long-press check toggle: for items whose tap already switched to the checked tool, long-press toggles once more into the checked state
            t.on_hold(self)
            -- The panel stays open, so when the check text changes the EPD must be refreshed explicitly:
            -- Button:setText only changes the in-memory widget; on the real device the e-ink doesn't refresh and it looks "unresponsive"
            if self._panel_bt then
                UIManager:setDirty(self._panel_bt, "partial")
            end
        end
    end
    return def
end

-- Build a category's ButtonTable (not shown; shared by _showCategoryMenu and tests).
-- Two items per row (compact panel; 13 tool items in a single column would overflow the screen); background rule: active tool items light grey, everything else white.
function M:_categoryBt(cat)
    local defs = {}
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            defs[#defs + 1] = self:_toggleDef(t)
        end
    end
    local rows = {}
    -- v59h: one per row for the layer category (3 buttons aligned vertically in a column, uniform width); other categories two per row, compact
    local step = (cat == "layer") and 1 or 2
    for i = 1, #defs, step do
        if step == 1 then
            rows[#rows + 1] = { defs[i] }
        else
            rows[#rows + 1] = { defs[i], defs[i + 1] } -- the last row may have only 1
        end
    end
    local bt = ButtonTable:new{
        width = math.floor(Screen:getWidth() * const.UI_WIDTH_MEDIUM),
        buttons = rows,
    }
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            local b = bt.button_by_id[t.id]
            if b and b[1] then
                local active = (cat == "tool" or cat == "layer")
                    and t.active_fn and t.active_fn(self)
                b[1].background = active and Blitbuffer.COLOR_LIGHT_GRAY
                    or Blitbuffer.COLOR_WHITE
            end
        end
    end
    return bt
end

local CATEGORY_TITLES = { tool = "Tool", prop = "Options", layer = "Layer", func = "Menu" }

-- Show a category panel (centred, rounded, draggable, tap outside to close).
-- v59: record _open_cat for the bottom-bar gap indicator; tapping another category closes the old panel first; restore the rule on close
function M:_showCategoryMenu(cat)
    local popup
    local bt
    bt = self:_categoryBt(cat)
    -- Item tap callbacks get this panel via get_popup and close it as needed
    for _, t in ipairs(TOGGLE_BUTTONS) do
        if t.cat == cat then
            local b = bt.button_by_id[t.id]
            if b then
                local orig = b.callback
                local close = t.close_on_tap
                if close == nil then
                    -- Function/layer items stay open (repeated taps/single-choice check state visible immediately)
                    close = (t.cat ~= "func" and t.cat ~= "layer")
                end
                b.callback = function()
                    -- v62g: panel items are top-level controls too; on tap, note their centre x (for second-level popup anchoring)
                    self._anchor_x = self:_anchorX(b) or self._anchor_x
                    orig()
                    if close and popup then
                        UIManager:close(popup, "full")
                    end
                end
            end
        end
    end
    self._panel_bt = bt
    -- Panel mutual exclusion: when switching categories, close the old panel first (its onCloseWidget clears _open_cat)
    if self._category_popup then
        UIManager:close(self._category_popup, "full")
        self._category_popup = nil
    end
    self._open_cat = cat
    self:_refreshToolbar()
    popup = components.showCenteredDialog{
        name = "DrawingCategoryMenu",
        title = L.x(CATEGORY_TITLES[cat] or cat),
        anchor_x = self._anchor_x,
        content = bt,
        log = function(...) self:_log(...) end,
    }
    self._category_popup = popup
    local canvas = self
    local orig_close = popup.onCloseWidget
    function popup:onCloseWidget()
        if canvas._open_cat == cat then
            canvas._open_cat = nil
            canvas._category_popup = nil
            canvas:_refreshToolbar()
        end
        if orig_close then
            orig_close(self)
        end
    end
    self:_log("category menu shown:", cat)
end

-- The floating "Menu" restore button in the top-left when minimised:
-- width = width of the toolbar's first cell (the hide button's cell; hide moved to the far left in v59c), aligned
function M:_buildRestoreButton()
    -- Same style as the bottom bar: outline up-arrow icon button (pairs with the hide key's down arrow), one cell wide, floating top-left
    local icon_px = Screen:scaleBySize(const.TOOLBAR_ICON_PX)
    local row_h = icon_px + 2 * Size.padding.default
    local btn = Button:new{
        icon = "dw.chevron.up",
        icon_width = icon_px,
        icon_height = icon_px,
        bordersize = 0,
        callback = function() self:_toggleMinimize() end,
    }
    self.restore_btn = self:_toolbarCell(btn, math.floor(Screen:getWidth() / #const.TOOLBAR_ICONS), row_h)
end

-- Dynamic panel state (v59b): text_fn items refresh their text; since v61f the background also refreshes live with active_fn
-- (highlight in an open panel follows layer/tool switches, using the same rules as _categoryBt construction)
function M:_syncToolLabels()
    local bt = self._panel_bt
    if not bt or not bt.button_by_id then
        return
    end
    for _, t in ipairs(self._toggle_buttons or {}) do
        local b = bt.button_by_id[t.id]
        if b then
            if t.text_fn and b.setText then
                b:setText(t.text_fn(self), b.width)
            end
            if b[1] then
                local active = (t.cat == "tool" or t.cat == "layer")
                    and t.active_fn and t.active_fn(self)
                b[1].background = active and Blitbuffer.COLOR_LIGHT_GRAY
                    or Blitbuffer.COLOR_WHITE
            end
        end
    end
end

-- ============================ Status bar ============================

-- Default font: taken from the fonts directory, preferring ones with CJK (friendly to Chinese input); falls back to cfont if none found
function M:_defaultFont()
    local ok, list = pcall(function()
        local FontList = require("fontlist")
        return FontList:getFontList()
    end)
    if ok and list and #list > 0 then
        for _, path in ipairs(list) do
            local base = path:match("[^/\\]+$") or ""
            if base:lower():match("cjk") then
                return base
            end
        end
        return (list[1]:match("[^/\\]+$"))
    end
    return "cfont"
end

-- Status bar text: shows the "next stroke" state - tool/mode + grey (random or not) + width (random or not) + current layer
function M:_statusText()
    local t = self.tool
    local gray_txt
    if self.gray_random then
        gray_txt = string.format(L.t("G:rand(%d-%d,%d)"),
            math.floor(self.gray_min * 100 + 0.5), math.floor(self.gray_max * 100 + 0.5), self.gray_levels)
    else
        gray_txt = string.format(L.t("G:%d%%"), math.floor(self.gray * 100 + 0.5))
    end
    local width_txt
    if self.width_random then
        width_txt = string.format(L.t("W:rand(%d-%d,%d)"), self.width_min, self.width_max, self.width_levels)
    else
        width_txt = string.format(L.t("W:%d"), self.width)
    end
    local layer_txt = L.x(const.LAYER_NAMES[self.active_layer])
        .. (self.layer_visible[self.active_layer] and "" or L.t("(hide)"))
    -- Opacity (next stroke): shown only when random or not fully opaque, saving status bar width;
    -- a marker is appended when the blend mode is not normal (* = multiply, + = linear dodge)
    if self.alpha_blend == "multiply" then
        layer_txt = layer_txt .. L.t("*")
    elseif self.alpha_blend == "dodge" then
        layer_txt = layer_txt .. L.t("+")
    end
    if self.alpha_random then
        layer_txt = layer_txt .. string.format(L.t(" O:rand(%d-%d)"),
            math.floor((self.alpha_min or 0.3) * 100 + 0.5), math.floor((self.alpha_max or 1) * 100 + 0.5))
    elseif (self.alpha or 1) < 0.999 then
        layer_txt = layer_txt .. string.format(L.t(" O:%d%%"), math.floor(self.alpha * 100 + 0.5))
    end
    local base
    if t == "text" then
        -- Text: grey value/font size/font name/layer
        local fname = (self.font or "?"):gsub("%.[^.]+$", "")
        base = string.format("%s %s %s:%d %s %s", L.x(const.TOOL_NAMES[t]), gray_txt, L.t("size"), self.font_size, fname, layer_txt)
    elseif t == "eraser" then
        local mode = (self.eraser_mode == "rect") and L.t("box") or L.t("tap")
        base = string.format("%s(%s) %s %s", L.x(const.TOOL_NAMES[t]), mode, width_txt, layer_txt)
    elseif t == "fill" then
        local mode = (self.fill_mode == "path") and L.t("path") or L.t("tap")
        base = string.format("%s(%s) %s %s", L.x(const.TOOL_NAMES[t]), mode, gray_txt, layer_txt)
    elseif t == "select" then
        local mode = (self.select_mode == "copy") and L.t("copy") or L.t("move")
        base = string.format(L.t("Select(%s)") .. " %s", mode, layer_txt)
    elseif t == "rect" or t == "circle" then
        local filled = ((t == "rect" and self.rect_filled) or (t == "circle" and self.circle_filled))
            and L.t("fill") or L.t("line")
        base = string.format("%s(%s) %s %s %s", L.x(const.TOOL_NAMES[t]), filled, gray_txt, width_txt, layer_txt)
    else
        -- Brush/line show the brush tip shape (part of the next-stroke state)
        local tip_txt = (t == "brush" or t == "line") and (" " .. L.t("tip:") .. (L.x(const.TIP_NAMES[self.tip]) or L.x("O"))) or ""
        base = string.format("%s %s %s%s %s", L.x(const.TOOL_NAMES[t]) or t, gray_txt, width_txt, tip_txt, layer_txt)
    end
    return base
end

function M:_updateStatus()
    self._status = self:_statusText()
    UIManager:setDirty(self, "partial")
end

-- ============================ Centred button popups ============================

-- Centred button popup (shared by the layer menu/grey settings/width settings).
-- KOReader's Menu items are left-aligned and can't be centred, so this uses a ButtonTable (button text is naturally centred)
-- wrapped in a full-screen modal container, tap outside to close. Returns bt (labels changeable via button_by_id), popup
function M:_showCenteredButtons(title, buttons, width_factor)
    -- Everything goes through components.showCenteredDialog (bottom-anchored rounded draggable panel + tap outside to close);
    -- returns bt (labels changeable via button_by_id), popup
    local bt = ButtonTable:new{
        width = math.floor(Screen:getWidth() * (width_factor or const.UI_WIDTH_MEDIUM)),
        buttons = buttons,
    }
    local popup = components.showCenteredDialog{
        name = "DrawingCenterMenu",
        title = title,
        anchor_x = self._anchor_x,
        content = bt,
        log = function(...) self:_log(...) end,
    }
    return bt, popup
end

-- Brush tip selection popup (centred, with shape previews): 7 brush tips; tapping sets self.tip and closes.
-- wbuilder/WSL font sets differ from Kindle: Font:getFace("infont",20) may return nil,
-- and a nil face in a TextWidget silently crashes with a nil dereference on the first paintTo/getSize (pitfall 14c).
-- This function is defensive throughout: nil-font fallback + pcall around each row's Blitbuffer/ImageWidget construction + a whole-function pcall as a backstop.
function M:_showTipMenu()
    -- Outer pcall: guards against first-paint exceptions; on failure give visible feedback instead of silently doing nothing.
    -- Style matches the layer/grey popups (rounded draggable panel, showCenteredDialog),
    -- text uses _defaultFont() (same source as the status bar) rather than hardcoding infont.
    local ok, err = pcall(M._showTipMenu_core, self)
    if not ok then
        local ok2, msg = pcall(tostring, err)
        self:_log("tip menu error:", ok2 and msg or "(unprintable error object)")
        components.showToast("Tip menu failed to open", 2)
    end
end

function M._showTipMenu_core(self)
    -- Layout: each row = ImageWidget (brush tip shape preview) + native Button (text label), centred in a VerticalGroup.
    -- All touch handling goes to the native Button's built-in gestures (same as toolbar/layer menu, verified in wbuilder),
    -- no custom tapRow/GestureRange; previews use an ImageWidget on a bare Blitbuffer
    -- (Button.icon only accepts icon names, not BBs, and the text branch takes precedence and ignores icon, so it goes outside).
    local Button = require("ui/widget/button")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local icon_px = Screen:scaleBySize(28)
    local row_h = Screen:scaleBySize(40)
    -- Icon and text sit tight together (button text left-aligned, so a fixed-width button doesn't push the text away leaving a big gap)
    local gap_w = Screen:scaleBySize(4)
    local btn_w = math.floor(Screen:getWidth() * const.UI_WIDTH_NARROW)
    -- Thin separator lines between rows (light grey, more refined than the default button border)
    local sep_w = icon_px + gap_w + btn_w
    local function separator()
        return VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Screen:scaleBySize(5) },
            LineWidget:new{
                dimen = Geom:new{ w = sep_w, h = math.max(1, Screen:scaleBySize(1)) },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(5) },
        }
    end
    local popup
    local function closePopup()
        if popup then UIManager:close(popup, "full") end
    end
    local rows = {}
    for _, t in ipairs(const.TIPS) do
        local tip_name, tip_label = t[1], t[2]
        -- Preview: draw the brush tip shape on a small canvas -> Blitbuffer (ImageWidget takes ownership, no more :free);
        -- a failed preview for one row only drops that row's graphic, without affecting the text or tapping.
        local img_widget
        pcall(function()
            local pv = Blitbuffer.new(icon_px, icon_px, Blitbuffer.TYPE_BB8)
            pv:paintRect(0, 0, icon_px, icon_px, Blitbuffer.COLOR_WHITE)
            shapes.tip(pv, math.floor(icon_px / 2), math.floor(icon_px / 2),
                math.floor(icon_px * 0.55), Blitbuffer.gray(1.0), tip_name)
            img_widget = ImageWidget:new{ image = pv, width = icon_px, height = icon_px }
        end)
        local btn = Button:new{
            text = L.x(tip_label),
            width = btn_w,
            bordersize = 0,
            align = "left",
            callback = function()
                self.tip = tip_name
                self:_updateStatus()
                self:_log("tip ->", tip_name)
                closePopup()
            end,
        }
        local row_content
        if img_widget then
            row_content = HorizontalGroup:new{
                FrameContainer:new{
                    dimen = Geom:new{ w = icon_px, h = row_h },
                    bordersize = 0, padding = 0, margin = 0,
                    img_widget,
                },
                HorizontalSpan:new{ width = gap_w },
                FrameContainer:new{
                    dimen = Geom:new{ w = btn_w, h = row_h },
                    bordersize = 0, padding = 0, margin = 0,
                    btn,
                },
            }
        else
            row_content = btn
        end
        -- Thin separator between rows: none before the first row, one before each other row
        if #rows > 0 then
            rows[#rows + 1] = separator()
        end
        rows[#rows + 1] = row_content
    end
    -- v62t: close button removed (tap outside to close, consistent with other popups)
    popup = components.showCenteredDialog{
        name = "DrawingTipMenu",
        anchor_x = self._anchor_x,
        content = VerticalGroup:new{ align = "center", unpack(rows) },
        log = function(...)
            local parts = {}
            for _, v in ipairs({...}) do
                local ok2, r = pcall(tostring, v)
                parts[#parts + 1] = ok2 and r or "(unprintable)"
            end
            local msg = table.concat(parts, " ")
            self:_log(msg)
            if msg:find("error") then
                pcall(function()
                    local f = io.open("/tmp/drawingpad_tip_he_error.txt", "a")
                    if f then f:write(msg .. "\n"); f:close() end
                end)
            end
        end,
    }
    -- paintTo crash protection (pitfall 14c), covering subsequent repaints
    if popup and popup.paintTo then
        local orig_paintTo = popup.paintTo
        function popup:paintTo(...)
            local ok, res = pcall(orig_paintTo, self, ...)
            if not ok then
                local msg = "tip menu paintTo error: " .. tostring(res)
                self:_log(msg)
                components.showToast("Tip menu render failed", 2)
            end
            return res
        end
    end
    self:_log("tip menu shown")
end

-- ============================ Text insertion ============================

-- Text insert/edit dialog.
-- el present = edit an existing text element (select text -> tap the "Text" tool -> edit properties: content/font/size),
-- prefilled with the current content and font info; on confirm _updateTextElement updates the element (undoable);
-- el nil = insert new text; the input box is auto-filled with the last input, and font/size are restored to the last committed values
function M:_showTextDialog(x, y, el)
    local self_widget = self
    local is_edit = el ~= nil
    local dlg
    if is_edit then
        -- Edit mode: font/size switch to the object's current values (buttons show/modify the object's properties);
        -- snapshot the original properties: during editing font/size are applied live to the element (no_undo),
        -- and on close (update/cancel) a single transform undo is written from the snapshot
        self.font = el.font
        self.font_size = el.size
        self._text_edit_orig = self:_cloneElement(el)
    elseif self._last_font then
        -- Insert mode: automatically restore the font info used for the last input
        self.font = self._last_font
        self.font_size = self._last_font_size
        self._text_edit_orig = nil
    end
    -- Font/size buttons: update the button labels in the popup live after selection
    local function fontLabel()
        return L.t("Font: ") .. ((self.font or "?"):gsub("%.[^.]+$", ""))
    end
    local function updateFontLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["font_btn"]
        if btn and btn.setText then
            btn:setText(fontLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    local function updateSizeLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["size_btn"]
        if btn and btn.setText then
            btn:setText(L.t("Size: ") .. self.font_size, btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = L.x(is_edit and "Edit text" or "Insert text"),
        input = (is_edit and el.text) or (self._last_text or ""),
        input_hint = is_edit and L.t("Edit text (font/size via buttons below)")
            or L.t("Enter text to insert"),
        buttons = {
            {
                -- Font/size integrated into the text popup
                { id = "font_btn", text = fontLabel(),
                  callback = function() self_widget:_pickFont(updateFontLabel) end },
                { id = "size_btn", text = L.t("Size: ") .. self.font_size,
                  callback = function() self_widget:_pickFontSize(updateSizeLabel) end },
            },
            {
                {
                    text = L.x(_("Cancel")),
                    id = "close",
                    callback = function()
                        UIManager:close(dlg)
                    end,
                },
                {
                    text = L.x(is_edit and "Update" or "Insert"),
                    is_enter_default = true,
                    callback = function()
                        local text = dlg:getInputText()
                        -- Apply first, then close: live property changes during editing already landed on the element,
                        -- and _updateTextElement writes the undo from the _text_edit_orig snapshot;
                        -- closing first would let onCloseWidget see the snapshot first, causing a duplicate undo
                        if is_edit then
                            self_widget:_updateTextElement(el, text)
                        else
                            self_widget:_commitText(x, y, text)
                        end
                        UIManager:close(dlg)
                    end,
                },
            },
        },
    }
    -- Instant dialog button response (drop the blocking flash_ui, shared component)
    components.instantButtons(dlg.button_table)
    -- When closed without tapping "Update" (cancel/Back key/tap outside): if text properties were changed live during editing -> write the undo
    local orig_dlg_close = dlg.onCloseWidget
    function dlg:onCloseWidget()
        if self_widget._text_edit_orig then
            local sel = self_widget._selected
            if sel and sel.kind == "text" then
                local orig = self_widget._text_edit_orig
                local final = self_widget:_cloneElement(sel)
                if orig.text ~= final.text or orig.font ~= final.font or orig.size ~= final.size then
                    self_widget:_pushUndo({ kind = "transform", el = sel, orig = orig, final = final })
                    self_widget:_clearRedo()
                    self_widget:_log("text edit closed w/o update, undo recorded")
                end
            end
            self_widget._text_edit_orig = nil
        end
        if orig_dlg_close then
            orig_dlg_close(self)
        end
    end
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Modify an existing text element (content/font/size, undoable, redraw the old ∪ new region).
-- During editing font/size are already applied live to the element (no_undo); _text_edit_orig is the snapshot taken when the popup opened,
-- and the undo goes from the snapshot to the final value (covering all the live changes)
function M:_updateTextElement(el, text)
    if not el or el.kind ~= "text" then
        return
    end
    text = text or ""
    if text == "" then
        self:_log("text edit empty, skipped")
        return
    end
    local orig = self._text_edit_orig or self:_cloneElement(el)
    local old_region = self:_elementRegion(el)
    el.text = text
    el.font = self.font
    el.size = self.font_size
    self:_cacheBBox(el)
    local final = self:_cloneElement(el)
    self._text_edit_orig = nil
    if orig.text == final.text and orig.font == final.font and orig.size == final.size then
        return -- no change (including live changes reverted to the original value)
    end
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "ui", region)
    self:_pushUndo({ kind = "transform", el = el, orig = orig, final = final })
    self:_clearRedo()
    self:_log("update text", string.format("%q", text), "font", self.font, self.font_size)
end

-- While editing text: apply font/size live to the selected text element (called per tick, no undo written;
-- the undo is written once by _updateTextElement/onCloseWidget from the _text_edit_orig snapshot)
function M:_applySelectedTextStyle()
    local el = self._selected
    if not el or el.kind ~= "text" then
        return
    end
    if el.font == self.font and el.size == self.font_size then
        return
    end
    local old_region = self:_elementRegion(el)
    el.font = self.font
    el.size = self.font_size
    self:_cacheBBox(el)
    local region = self:_mergeRegions(old_region, self:_elementRegion(el))
    self:_redrawRegion(region)
    UIManager:setDirty(self, "ui", region)
    self:_log("text style live ->", self.font, self.font_size)
end

-- Selected text object -> entry to the property edit menu (triggered by tapping the "Text" tool, see _setTool)
function M:_editSelectedText()
    local el = self._selected
    if not el or el.kind ~= "text" then
        return
    end
    self:_showTextDialog(el.x or 0, el.y or 0, el)
end

function M:_commitText(x, y, text)
    if not text or text == "" then
        self:_log("text empty, skipped")
        return
    end
    -- Pure whitespace (spaces/tabs/newlines) counts as cancel: invisible when rendered but takes up an element/bbox, just confusing
    if not text:find("%S") then
        self:_log("text whitespace-only, skipped")
        return
    end
    -- Remember this input's content and font info: auto-filled the next time the text tool is tapped
    self._last_text = text
    self._last_font = self.font
    self._last_font_size = self.font_size
    local el = {
        kind = "text",
        x = x, y = y,
        text = text,
        font = self.font,
        size = self.font_size,
        gray = self:_resolveGray(),
        alpha = self:_resolveAlpha(),
        blend = self.alpha_blend,
    }
    table.insert(self.elements, el)
    self:_cacheBBox(el)
    self:_pushUndo({ kind = "add", el = el })
    self:_clearRedo()
    self:_drawTextTo(self.canvas_bb, el)
    self:_log("commit text", string.format("%q", text), "at", x, y,
        "font", self.font, self.font_size, "gray", self.gray)
    -- Replay the committed region when visible layers lie above: text drawn straight into canvas_bb must not cover higher-layer ink
    local region = self:_elementRegion(el)
    self:_commitRegionReplay(region)
    UIManager:setDirty(self, "partial", region)
end

function M:_drawTextTo(bb, el, layer_idx)
    if not el or not el.text or el.text == "" or not el.font or not el.size then
        return
    end
    local face = Font:getFace(el.font, el.size)
    if not face then
        -- getFace returns nil when the font file is missing: skip drawing, no longer passing a nil face to
        -- renderUtf8Text (the old version threw a Lua error that bubbled up and quit the whole program)
        self:_log("draw text skipped: no face for", el.font, el.size)
        return
    end
    local rot = el.rot or 0
    local sx = el.sx or 1
    local sy = el.sy or 1
    -- Effective opacity = element × its layer (defaults to the current layer); when <1 take the temp-BB per-pixel blending path
    local alpha = (el.alpha or 1)
        * ((self.layer_alpha and self.layer_alpha[layer_idx or self.active_layer]) or 1)
    -- Baseline is about 0.8 font size below the insertion point, so the body of the text lands near the tap point
    local baseline = (el.y or 0) + math.floor(el.size * 0.8)
    if rot == 0 and sx == 1 and sy == 1 and alpha >= 0.999 then
        RenderText:renderUtf8Text(bb, el.x or 0, baseline,
            face, el.text,
            false, false, Blitbuffer.gray(el.gray))
        return
    end
    -- Stretch/rotate: render to a temp BB -> scale by (sx,sy) -> per-pixel inverse-transform sampling about the anchor (left end of the baseline)
    local s = RenderText:sizeUtf8Text(0, nil, face, el.text, false, false)
    if not (s and s.x and s.y_top and s.y_bottom) then
        return
    end
    local w, h = s.x, s.y_top + s.y_bottom
    local temp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    temp:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
    -- Semi-transparent: render the temp BB in pure black (ink amount m=(255-pixel)/255 can be inverted exactly), blend by alpha when writing back;
    -- opaque: render with the element's grey as usual, writing back gives normal text
    RenderText:renderUtf8Text(temp, 0, s.y_top, face, el.text, false, false,
        (alpha < 0.999) and Blitbuffer.gray(1.0) or Blitbuffer.gray(el.gray))
    -- Scaled size and the anchor's (left end of the baseline) position in the scaled local frame
    local dw = math.max(1, math.floor(w * sx + 0.5))
    local dh = math.max(1, math.floor(h * sy + 0.5))
    -- Anchor = left end of the baseline (same semantics as _textExtent/_frameCorners: baseline = el.y + 0.8*font size).
    -- The old version used el.y directly as the baseline, so rotated/stretched text sat 0.8*font size too high, misaligned with the selection box
    local ax = el.x or 0
    local ay = (el.y or 0) + math.floor(el.size * 0.8)
    local ayl = math.floor(s.y_top * sy + 0.5)
    -- Enclosing extent of the scaled rectangle after rotation about the anchor
    local c, sn = math.cos(rot), math.sin(rot)
    local x0, y0 = 0, -ayl
    local x1, y1 = dw, dh - ayl
    local hw = math.max(math.abs(x0 * c - y0 * sn), math.abs(x1 * c - y0 * sn),
        math.abs(x1 * c - y1 * sn), math.abs(x0 * c - y1 * sn))
    local hh = math.max(math.abs(x0 * sn + y0 * c), math.abs(x1 * sn + y0 * c),
        math.abs(x1 * sn + y1 * c), math.abs(x0 * sn + y1 * c))
    local x_min, x_max = math.max(0, math.floor(ax - hw)), math.min(bb:getWidth() - 1, math.ceil(ax + hw))
    local y_min, y_max = math.max(0, math.floor(ay - hh)), math.min(bb:getHeight() - 1, math.ceil(ay + hh))
    -- Blend mode is per element (recorded at creation); multiply/dodge need to read dest, so only enabled on a BB8 canvas
    -- (the drag preview's bb is the screen framebuffer, ColorRGB32 in the emulator; reading .a crashes -> fall back to normal)
    local mode = el.blend or "normal"
    local okt, ttype = pcall(bb.getType, bb)
    local read_dest = okt and ttype == Blitbuffer.TYPE_BB8
        and (mode == "multiply" or mode == "dodge")
    local ink8 = math.floor(255 * (1 - (el.gray or 1)) + 0.5)
    for py = y_min, y_max do
        for px = x_min, x_max do
            -- Inverse-rotate into the scaled local frame, then inverse-scale into the natural frame
            local lx = (px - ax) * c + (py - ay) * sn
            local ly = -(px - ax) * sn + (py - ay) * c + ayl
            local xi = math.floor(lx / sx + 0.5)
            local yi = math.floor(ly / sy + 0.5)
            if xi >= 0 and xi < w and yi >= 0 and yi < h then
                local pv = temp:getPixel(xi, yi)
                local a8 = pv and pv.a
                if a8 and a8 < 255 then
                    if alpha < 0.999 then
                        -- Ink amount m=(255−a8)/255; composite the ink colour into dest at "m·α opacity"
                        -- (out = dest·(1−mα) + ink·mα). normal uses the native setPixelBlend:
                        -- it doesn't read dest pixels and is correct for every type, BB8/RGB32 alike
                        local coverage = math.floor((255 - a8) * alpha + 0.5)
                        if coverage > 0 then
                            if read_dest then
                                shapes.blendModePixel(bb, px, py, ink8, coverage, mode)
                            else
                                bb:setPixelBlend(px, py, Blitbuffer.Color8A(ink8, coverage))
                            end
                        end
                    else
                        bb:setPixel(px, py, Blitbuffer.Color8(a8))
                    end
                end
            end
        end
    end
    temp:free()
end

-- ============================ Palette / width / font / font size ============================

-- Value adjustment popup (slider + preset steps, replacing SpinWidget's virtual-keyboard number input - awkward on a touchscreen).
-- Structure: title + large current value + slider that can be dragged/tapped to position (with ticks) + one-tap preset steps + close.
-- Drag throttling follows KOReader's brightness adjustment (FrontLightWidget): rate-limited apply and refresh while dragging, pan_release fills in the final state.
-- opts: { title, value, min, max, unit, presets, onchange(v), onclose(v) }
-- onchange is called when the value changes (applied live; callers handle it with no_undo semantics); onclose is called on close (writes undo etc.)
-- Implementation moved into components.showValuePicker (maintained centrally in the component library)
function M:_showValuePicker(opts)
    opts = opts or {}
    opts.log = function(...) self:_log(...) end
    opts.anchor_x = opts.anchor_x or self._anchor_x -- second-level popup anchors to the top-level item
    return components.showValuePicker(opts)
end

-- Shared generator for the grey/width settings popups (merged in v59; same structure/copy/layout, only value range/units/wording differ).
-- Random mode is toggled only by long-pressing the property panel items (Grey (☑Random)/Width (☑Random)); the popup has no random key or hint.
-- opts: { title, ids={4 button ids}, labels={max,min}, get/set={max,min,levels,fixed},
--         spin={max={title,min,max},...}, disp(v)→display string }
function M:_showSettingDialog(o)
    local popup
    local function labels()
        local l = {
            string.format("%s:%s", L.x(o.labels.max), o.disp(o.get.max(self))),
            string.format("%s:%s", L.x(o.labels.min), o.disp(o.get.min(self))),
            string.format(L.t("Levels:%d"), o.get.levels(self)),
            string.format(L.t("Fixed:%s"), o.disp(o.get.fixed(self))),
        }
        if o.mode then
            l[5] = o.mode.label(self)
        end
        return l
    end
    local bt
    local function refreshLabels()
        if not bt or not bt.button_by_id then
            return
        end
        local l = labels()
        for i, id in ipairs(o.ids) do
            local b = bt.button_by_id[id]
            if b and b.setText then
                b:setText(l[i], b.width)
            end
        end
        if popup then
            -- v62z: refresh only the panel rectangle (a region-less partial = full-screen refresh, 1-2s on the real device, the culprit behind slow popups)
            if popup[1] and popup[1].dimen then
                UIManager:setDirty(popup, "ui", popup[1].dimen)
            else
                UIManager:setDirty(popup, "partial")
            end
        end
    end
    local function spinval(key)
        -- Slider initial value: the internal value is mapped to the display value via spin_val (grey 0-1 -> 0-100); default = internal value
        local f = o.spin_val and o.spin_val[key]
        return f and f(self) or o.get[key](self)
    end
    local function spin(spec, onchange)
        self:_showValuePicker{
            title = L.x(spec[1]),
            value = spec[4],
            min = spec[2],
            max = spec[3],
            onchange = function(v)
                onchange(v)
                refreshLabels()
            end,
        }
    end
    local btns = {
        {
            { id = o.ids[1], text = L.x(o.labels.max),
              callback = function()
                  local s = o.spin.max
                  spin({ s[1], s[2], s[3], spinval("max") }, function(v) o.set.max(self, v) end)
              end },
            { id = o.ids[2], text = L.x(o.labels.min),
              callback = function()
                  local s = o.spin.min
                  spin({ s[1], s[2], s[3], spinval("min") }, function(v) o.set.min(self, v) end)
              end },
        },
        {
            { id = o.ids[3], text = L.x("Levels"),
              callback = function()
                  local s = o.spin.levels
                  spin({ s[1], s[2], s[3], spinval("levels") }, function(v) o.set.levels(self, v) end)
              end },
            { id = o.ids[4], text = L.x("Fixed"),
              callback = function()
                  local s = o.spin.fixed
                  spin({ s[1], s[2], s[3], spinval("fixed") }, function(v) o.set.fixed(self, v) end)
              end },
        },
    }
    -- Optional extra row (opacity popup only): blend mode, single key cycling normal -> multiply -> linear dodge
    if o.mode then
        table.insert(btns, {
            { id = o.ids[5], text = o.mode.label(self),
              callback = function()
                  o.mode.cycle(self)
                  refreshLabels()
              end },
        })
    end
    bt, popup = self:_showCenteredButtons(o.title, btns, const.UI_WIDTH_MEDIUM)
    refreshLabels()
end

-- Grey settings popup: max/min/number of levels (2-64)/fixed grey (internally 0-1, displayed and entered as 0-100%)
function M:_pickGray()
    if self.tool == "select" and self._selected then
        return self:_pickElementGray()
    end
    local function pct(v) return math.floor(v * 100 + 0.5) end
    self:_showSettingDialog{
        title = "Gray",
        ids = { "gray_max_btn", "gray_min_btn", "gray_levels_btn", "gray_fixed_btn" },
        labels = { max = "Max", min = "Min" },
        get = {
            max = function(s) return s.gray_max end,
            min = function(s) return s.gray_min end,
            levels = function(s) return s.gray_levels end,
            fixed = function(s) return s.gray end,
        },
        set = {
            max = function(s, v) s.gray_max = v / 100 end,
            min = function(s, v) s.gray_min = v / 100 end,
            levels = function(s, v) s.gray_levels = v end,
            fixed = function(s, v) s.gray = v / 100 end,
        },
        spin = {
            max = { "Max gray(0%=white 100%=black)", 0, 100 },
            min = { "Min gray(0%=white 100%=black)", 0, 100 },
            levels = { "Random levels(2-64)", 2, 64 },
            fixed = { "Fixed gray(0%=white 100%=black)", 0, 100 },
        },
        disp = function(v) return string.format("%d%%", pct(v)) end,
        spin_val = {
            max = function(s) return pct(s.gray_max) end,
            min = function(s) return pct(s.gray_min) end,
            fixed = function(s) return pct(s.gray) end,
        },
    }
    self:_log("gray dialog", self.gray_random and "random" or "fixed")
end

-- Selected-object grey adjustment (tap "Grey" with the select tool and a selected object): slider + preset steps, no intermediate confirmation.
-- Applied live per tick (no_undo, no undo written); a single undo record is written on close
function M:_pickElementGray()
    local el = self._selected
    if not el then
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = "Selected gray(0%=white 100%=black)",
        value = math.floor((el.gray or 1) * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedGray(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el
                and math.abs((pending_orig.gray or 1) - (el.gray or 1)) > 0.001 then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected gray", el.kind)
            end
        end,
    }
end

-- Selected-object line width adjustment (text/fills have no line width; notify and skip)
function M:_pickElementWidth()
    local el = self._selected
    if not el then
        return
    end
    if el.kind == "text" or el.kind == "fill" then
        components.showToast("This object has no line width.", 2)
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = "Selected width(px)",
        value = el.width or 2,
        min = 1,
        max = 800,
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedWidth(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el and pending_orig.width ~= el.width then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected width", el.kind)
            end
        end,
    }
end

-- Width settings popup: thickest/thinnest/number of levels (2-64)/fixed width (px)
function M:_pickWidth()
    if self.tool == "select" and self._selected then
        return self:_pickElementWidth()
    end
    self:_showSettingDialog{
        title = "Width",
        ids = { "width_max_btn", "width_min_btn", "width_levels_btn", "width_fixed_btn" },
        labels = { max = "Thick", min = "Thin" },
        get = {
            max = function(s) return s.width_max end,
            min = function(s) return s.width_min end,
            levels = function(s) return s.width_levels end,
            fixed = function(s) return s.width end,
        },
        set = {
            max = function(s, v) s.width_max = v end,
            min = function(s, v) s.width_min = v end,
            levels = function(s, v) s.width_levels = v end,
            fixed = function(s, v) s.width = v end,
        },
        spin = {
            max = { "Thickest(px)", 1, 800 },
            min = { "Thinnest(px)", 1, 800 },
            levels = { "Random levels(2-64)", 2, 64 },
            fixed = { "Fixed width(px)", 1, 800 },
        },
        disp = function(v) return string.format("%d", v) end,
    }
    self:_log("width dialog", self.width_random and "random" or "fixed")
end

-- Opacity settings popup: strongest/faintest/number of levels (2-64)/fixed opacity (internally 0-1, displayed and entered as 0-100%, 100%=opaque)
function M:_pickAlpha()
    if self.tool == "select" and self._selected then
        return self:_pickElementAlpha()
    end
    local function pct(v) return math.floor(v * 100 + 0.5) end
    self:_showSettingDialog{
        title = "Opacity",
        ids = { "alpha_max_btn", "alpha_min_btn", "alpha_levels_btn", "alpha_fixed_btn", "alpha_blend_btn" },
        -- Blend mode (only affects how the opacity of newly drawn elements composites; tap to cycle)
        mode = {
            label = function(s)
                local m = s.alpha_blend or "normal"
                if m == "multiply" then
                    return L.t("Blend:Multiply")
                elseif m == "dodge" then
                    return L.t("Blend:Dodge")
                end
                return L.t("Blend:Normal")
            end,
            cycle = function(s)
                local m = s.alpha_blend or "normal"
                if m == "normal" then
                    s.alpha_blend = "multiply"
                elseif m == "multiply" then
                    s.alpha_blend = "dodge"
                else
                    s.alpha_blend = "normal"
                end
                s:_log("alpha blend ->", s.alpha_blend)
            end,
        },
        labels = { max = "Max", min = "Min" },
        get = {
            max = function(s) return s.alpha_max end,
            min = function(s) return s.alpha_min end,
            levels = function(s) return s.alpha_levels end,
            fixed = function(s) return s.alpha end,
        },
        set = {
            max = function(s, v) s.alpha_max = v / 100 end,
            min = function(s, v) s.alpha_min = v / 100 end,
            levels = function(s, v) s.alpha_levels = v end,
            fixed = function(s, v) s.alpha = v / 100 end,
        },
        spin = {
            max = { "Max opacity(100%=opaque)", 0, 100 },
            min = { "Min opacity(100%=opaque)", 0, 100 },
            levels = { "Random levels(2-64)", 2, 64 },
            fixed = { "Fixed opacity(100%=opaque)", 0, 100 },
        },
        disp = function(v) return string.format("%d%%", pct(v)) end,
        spin_val = {
            max = function(s) return pct(s.alpha_max) end,
            min = function(s) return pct(s.alpha_min) end,
            fixed = function(s) return pct(s.alpha) end,
        },
    }
    self:_log("alpha dialog", self.alpha_random and "random" or "fixed")
end

-- Selected-object opacity adjustment (tap "Opacity" with the select tool and a selected object): slider + preset steps, no intermediate confirmation.
-- Applied live per tick (no_undo, no undo written); a single undo record is written on close
function M:_pickElementAlpha()
    local el = self._selected
    if not el then
        return
    end
    local pending_orig = nil
    self:_showValuePicker{
        title = "Selected opacity(100%=opaque)",
        value = math.floor((el.alpha or 1) * 100 + 0.5),
        min = 0,
        max = 100,
        unit = "%",
        onchange = function(v)
            if self._selected ~= el then
                return
            end
            if not pending_orig then
                pending_orig = self:_cloneElement(el)
            end
            self:_applySelectedAlpha(v, true)
        end,
        onclose = function()
            if pending_orig and self._selected == el
                and math.abs((pending_orig.alpha or 1) - (el.alpha or 1)) > 0.001 then
                self:_pushUndo({ kind = "transform", el = el, orig = pending_orig, final = self:_cloneElement(el) })
                self:_clearRedo()
                self:_log("set selected alpha", el.kind)
            end
        end,
    }
end

-- Font selection: lists the fonts actually scanned in KOReader's fonts directory (FontList, scrollable Menu)
-- @param on_change callback after a font is selected (the text insertion popup uses it to refresh button labels)
function M:_pickFont(on_change)
    local FontList = require("fontlist")
    local Menu = require("ui/widget/menu")
    local list = FontList:getFontList()
    local menu -- declared first so item callbacks can close the menu directly (close on select, independent of Menu's internal paths)
    local items = {}
    for _, path in ipairs(list) do
        local fname = path:match("[^/\\]+$")
        if fname then
            local display = FontList:getLocalizedFontName(path, 0)
                or (fname:gsub("%.[^.]+$", ""))
            table.insert(items, {
                text = display,
                callback = function()
                    self.font = fname
                    self:_applySelectedTextStyle() -- while editing text: change the selected text element's font live
                    self:_log("font ->", fname)
                    self:_updateStatus()
                    if on_change then
                        on_change()
                    end
                    if menu then
                        UIManager:close(menu) -- close automatically after a font is selected
                    end
                end,
            })
        end
    end
    if #items == 0 then
        components.showToast("No usable font found (fonts folder).", 2)
        return
    end
    menu = Menu:new{
        title = T(L.t("Choose font (%1 total)"), #items),
        item_table = items,
        width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * const.UI_WIDTH_WIDE),
        height = math.floor(Screen:getHeight() * 0.9),
        -- Fallback: Menu's own close_callback path
        close_callback = function()
            if menu then
                UIManager:close(menu)
            end
        end,
    }
    UIManager:show(menu)
end

-- Font size: slider + preset steps (replaces SpinWidget's numeric keypad; max 800, presets cover common sizes)
-- @param on_change callback after the font size is confirmed (the text insertion popup uses it to refresh button labels)
function M:_pickFontSize(on_change)
    self:_showValuePicker{
        title = "Size(free)",
        value = self.font_size,
        min = 8,
        max = 800,
        onchange = function(v)
            self.font_size = v
            self:_applySelectedTextStyle() -- while editing text: change the selected text element's font size live
            self:_log("font_size ->", self.font_size)
            self:_updateStatus()
            if on_change then
                on_change()
            end
        end,
    }
end

-- Folder selection: Menu lists the drawingboard/ root and its subfolders (close on select)
-- Note: lfs.dir returns two values (iter, dir_obj); iteration must pass dir_obj along,
-- otherwise the subfolder list is always empty (only ever shows "No subfolders yet")
-- Choose save folder: browser for any absolute path (structure copied from memobook's list popup).
-- ButtonDialog large button rows: top control row [Up][Select this folder][Close], below it one row per
-- folder (with "/", tap = enter)/PNG file (tap = commit folder + callback with the filename). Entering a folder
-- closes the current popup and builds a new one (same approach as memobook switching lists); can go up to any absolute path.
-- When the root = drawingboard, save_folder stores "" to keep the default
-- file_ext (optional, default "%.png$") = extension pattern for listed files (opening a project passes "%.drawing$");
-- title_prefix (optional) = popup title prefix (default "Choose save folder: ")
function M:_pickSaveFolder(on_change, on_pick_file, file_ext, title_prefix)
    file_ext = file_ext or "%.png$"
    title_prefix = title_prefix or L.t("Choose save folder: ")
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog = nil
    local cur = base
    local function parentOf(p)
        if p == "/" then
            return nil
        end
        local head = p:match("^(.*)/[^/]*$")
        if not head or head == "" then
            return "/"
        end
        return head
    end
    local function titleOf(p)
        return (p == base) and L.t("root folder") or p
    end
    local function commit(path)
        self.save_folder = (path == base) and "" or path
        self:_log("save_folder ->", self.save_folder)
        if on_change then on_change() end
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local function commitFile(name)
        self.save_folder = (cur == base) and "" or cur
        self:_log("save_folder ->", self.save_folder, "pick file", name)
        if on_pick_file then
            on_pick_file(name:gsub(file_ext, "")) -- strip the extension; the save flow appends it automatically
        end
        if on_change then on_change() end
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local function show()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
        local rows = {}
        -- Top control row (same as the file browser): Home jumps back to the drawingboard root / Up / Select this folder / Close
        local parent = parentOf(cur)
        table.insert(rows, {
            {
                text = L.x("Home"),
                callback = function()
                    if cur ~= base then
                        cur = base
                        show()
                    end
                end,
            },
            {
                text = L.x("Up"),
                enabled = parent ~= nil,
                callback = function()
                    if parent then
                        cur = parent
                        show()
                    end
                end,
            },
            {
                text = L.x("Use this folder"),
                callback = function() commit(cur) end,
            },
            {
                text = L.x("Close"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                        dialog = nil
                    end
                end,
            },
        })
        -- Content rows: subfolders (enter)/existing PNG files (pick a file to fill in the name)
        local subs, files = {}, {}
        local ok, iter, dir_obj = pcall(lfs.dir, cur)
        if ok and iter then
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then
                    local mode = lfs.attributes(cur .. "/" .. name, "mode")
                    if mode == "directory" then
                        table.insert(subs, name)
                    elseif name:lower():match(file_ext) then
                        table.insert(files, name)
                    end
                end
            end
        end
        table.sort(subs)
        table.sort(files)
        for _, name in ipairs(subs) do
            table.insert(rows, {
                {
                    text = name .. "/",
                    callback = function()
                        cur = cur .. "/" .. name
                        show()
                    end,
                },
            })
        end
        for _, name in ipairs(files) do
            table.insert(rows, {
                {
                    text = name,
                    callback = function() commitFile(name) end,
                },
            })
        end
        dialog = ButtonDialog:new{
            title = title_prefix .. titleOf(cur),
            buttons = rows,
            width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * const.UI_WIDTH_WIDE),
            shrink_unneeded_width = false,
        }
        UIManager:show(dialog)
    end
    show()
end

-- About popup: unified centred popup (components.showCenteredDialog, same structure as the brush tip popup).
-- Content is split into separate single-line TextWidgets - on the device a multi-line TextWidget may not show at all on the first frame.
function M:_showAbout()
    local face = Font:getFace(self:_defaultFont(), 18)
    local function line(text)
        return TextWidget:new{ text = text, face = face }
    end
    -- v62t: close button removed (tap outside to close)
    local content = VerticalGroup:new{
        align = "center",
        line(L.t("drawingboard")),
        line(L.t("Version:") .. const.PLUGIN_VERSION),
        line(L.t("Author:") .. const.PLUGIN_AUTHOR),
        line("GitHub: https://github.com/eznas"),
        line(L.t("Export to: ") .. (self._exportFolder and self:_exportFolder() or "koreader/drawingboard/")),
        line(L.t("Kobo fork: stylus support, English-only UI (2026-10)")),
    }
    self._about_popup = components.showCenteredDialog{
        name = "DrawingAbout",
        title = _("About"),
        anchor_x = self._anchor_x,
        content = content,
        log = function(...) self:_log(...) end,
    }
    return self._about_popup
end


return M
