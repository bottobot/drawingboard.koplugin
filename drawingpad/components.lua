--[[--
drawingpad.components - popup component library (Modal / Dialog / Toast base library).
The business layer (menus/actions) doesn't hand-write InputContainer/FrameContainer popup skeletons;
everything goes through this library: full-screen Modal skeleton / rounded draggable Dialog / value picker popup / Toast / instant-response buttons.

Key conventions (baked into the components, the business layer no longer has to care):
- Full-screen Modals don't set covers_fullscreen: UIManager:_repaint skips a canvas covered by a full-screen widget,
  so when a slider changes grey/width live the selected object wouldn't redraw until the popup closed.
- With stop_events_propagation=true, onGesture unconditionally consumes all gestures, so ges_events must be registered,
  otherwise the popup swallows all input (can't close/can't tap; this once locked up the board).
- KOReader gesture events are dispatched via Event:new(name, args, ev); args takes a slot even when nil,
  so handlers must have the signature (_, ges), otherwise ges receives nil and crashes.
- Refreshes always use the deferred-function form ("ui"/"fast" + region), so they aren't merged into a full-screen partial and downgraded, leaving ghosting.
- All event entry points are wrapped in pcall (logged via opts.log); any Lua error is only logged and never blows up KOReader.
--]]

-- Self-locate: add this file's directory to package.path so require("drawingpad.components") works regardless of directory
local __source = debug.getinfo(1, "S").source
local __self_dir = __source:match("^@(.*)[/\\][^/\\]*$") or "."
if not package.path:find(__self_dir, 1, true) then
    -- Both same-directory short names (shapes/const) and the parent-directory drawingpad.* prefix resolve, regardless of where drawingpad lives
    package.path = __self_dir .. "/?.lua;" .. __self_dir .. "/../?.lua;" .. package.path
end
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local ButtonTable = require("ui/widget/buttontable")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Size = require("ui/size")
local _ = require("gettext")

local M = {}

-- Logging: opts.log is optional; silent by default
local function log(opts, ...)
    if opts and opts.log then
        opts.log(...)
    end
end

-- ============================ Utilities ============================

-- Instant button response: remove Button's default flash_ui inversion + yieldToEPDC blocking
-- (on the real device each tap froze ~200-300ms, and with the EPD refresh backlog it felt like "you have to tap several times").
-- Applied to all buttons in popup ButtonTables / dialog button_tables.
-- Gotcha: ButtonTable.buttons is the raw button definition table (no Button methods); the real Button instances
-- are in buttons_layout (array per row); button_by_id only holds buttons with an id, so it's incomplete.
function M.instantButtons(bt)
    local rows = bt and (bt.buttons_layout or bt.buttons)
    if not rows then
        return
    end
    for _, row in ipairs(rows) do
        for _, b in ipairs(row) do
            if b and b.onTapSelectButton then
                b.onTapSelectButton = function(self)
                    if self.enabled or self.allow_tap_when_disabled then
                        if self.callback then
                            self.callback()
                        end
                    end
                    return true
                end
            end
        end
    end
end

-- ============================ Modal base class ============================

-- Full-screen modal popup base class: shared skeleton/gesture registration rules/tap-outside-to-close/crash protection.
-- opts: { name, tap_close (default true), log }
-- Returns popup (an InputContainer instance); the business layer puts content in popup[1].
-- Not shown here: the concrete component (Dialog/ValuePicker) is responsible for that.
function M.newModal(opts)
    opts = opts or {}
    local popup = InputContainer:extend{
        name = opts.name or "DrawingModal",
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        stop_events_propagation = true,
    }:new{}
    if opts.tap_close ~= false then
        -- Tap outside to close. Gestures must be registered: stop_events_propagation=true makes
        -- onGesture unconditionally consume all gestures; without ges_events the popup swallows all input
        popup.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = popup.dimen },
            },
        }
        popup.onTapSelect = function()
            UIManager:close(popup, "full")
            return true
        end
    end
    -- Crash protection: all event entry points (including child component/button callbacks) wrapped in pcall; errors are logged and the event consumed
    local orig_handle = popup.handleEvent
    function popup:handleEvent(ev)
        local ok, res = pcall(orig_handle, self, ev)
        if not ok then
            log(opts, "modal handleEvent error:", tostring(res))
            return true
        end
        return res
    end
    return popup
end

-- ============================ Dialog (rounded draggable panel) ============================

-- Bottom-anchored rounded white draggable panel popup (initially just above the toolbar, draggable):
-- BottomContainer -> MovableContainer -> FrameContainer{radius, white background} -> content;
-- covers_fullscreen is not set: the canvas underneath can redraw while dragging; when MovableContainer moves it does
-- setDirty("all") + a "ui" refresh of the old ∪ new region -> no ghosting while dragging.
-- opts: { name, title, content, log }; returns popup.
function M.showCenteredDialog(opts)
    opts = opts or {}
    local popup = M.newModal{ name = opts.name or "DrawingDialog", log = opts.log }
    local content = opts.content
    if opts.title then
        content = VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = L.x(opts.title), face = Font:getFace("infont", 20) },
            VerticalSpan:new{ width = Size.span.vertical_default },
            content,
        }
    end
    local mc = MovableContainer:new{
        FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.default,
            radius = Size.radius.window,
            background = Blitbuffer.COLOR_WHITE,
            content,
        },
    }
    popup.movable = mc -- same convention as InputDialog's self.movable
    -- Bottom anchoring (v62f): the panel starts just above the bottom toolbar (5px gap), not covering the centre of the picture;
    -- still draggable (MovableContainer). bottom_clear = bottom height to avoid (toolbar + status bar),
    -- defaults to an estimate from the board's fixed bar heights 52+28.
    -- Horizontal anchoring (v62g): opts.anchor_x = centre x of the top-level icon/item; the panel centre aligns to it where possible
    -- (clamped left/right to stay on screen); centred horizontally by default. After construction, the panel size is precomputed before positioning.
    local bottom_clear = opts.bottom_clear
    if bottom_clear == nil then
        bottom_clear = Screen:scaleBySize(52) + Screen:scaleBySize(28)
    end
    local margin = Screen:scaleBySize(5)
    local ok_size, msize = pcall(function() return mc:getSize() end)
    local pw = ok_size and msize and msize.w or 0
    local ph = ok_size and msize and msize.h or 0
    -- v62z: refresh region covers only the panel rectangle (a full-screen ui refresh takes 1-2s on the real device, the root cause of slow top-level menus);
    -- falls back to full screen if the size estimate fails, to guarantee visibility
    local refresh_region
    if pw > 0 and ph > 0 then
        local px = opts.anchor_x
            and math.floor(opts.anchor_x - pw / 2)
            or math.floor((popup.dimen.w - pw) / 2)
        px = math.max(margin, math.min(popup.dimen.w - pw - margin, px))
        local py = popup.dimen.h - bottom_clear - margin - ph
        popup[1] = WidgetContainer:new{
            dimen = Geom:new{ x = px, y = py, w = pw, h = ph },
            mc,
        }
        refresh_region = Geom:new{ x = px, y = py, w = pw, h = ph }
    else
        -- Size precompute failed: fall back to bottom-centred (BottomContainer), at least guaranteeing it's fully visible
        popup[1] = BottomContainer:new{
            dimen = Geom:new{
                x = 0, y = 0,
                w = popup.dimen.w,
                h = popup.dimen.h - bottom_clear - margin,
            },
            mc,
        }
    end
    -- Pass the refresh type + region explicitly: this tree's UIManager._refresh drops nil modes outright (avoids pointless full-screen refreshes);
    -- without it the popup only reaches the framebuffer and the hardware never refreshes -> "popup invisible until dragged".
    -- "ui" = non-flashing refresh; region is the modal's full-screen dimen (consistent with the full-screen canvas redraw on close).
    UIManager:show(popup, "ui", refresh_region or popup.dimen)
    return popup, mc
end

-- Custom tap row (auto-registers TapSelect, eliminating the "custom row doesn't register gestures, swallows input and locks up" pitfall):
-- opts: { dimen, onSelect, content }; returns an InputContainer row (row[1] = content).
function M.tapRow(opts)
    local row = InputContainer:extend{
        dimen = opts.dimen,
        onTapSelect = function()
            if opts.onSelect then
                opts.onSelect()
            end
            return true
        end,
    }:new{}
    -- Gestures must be registered to receive taps (custom rows, unlike Button, don't come with gestures);
    -- range references row.dimen: centred layout updates x/y at paint time, matching uses screen coordinates
    row.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = row.dimen },
        },
    }
    row[1] = opts.content
    return row
end

-- ============================ Toast ============================

-- Unified Toast (InfoMessage wrapper). timeout defaults to persistent (tap to close); pass seconds to auto-close when it expires
function M.showToast(text, timeout)
    local o = { text = L.x(text) }
    if timeout then
        o.timeout = timeout
    end
    UIManager:show(InfoMessage:new(o))
end

-- ============================ ValuePicker (value adjustment popup) ============================

-- Value adjustment popup (selected object grey/width, global settings, font size): slider + preset steps + stepper row.
-- opts: { title, value, min, max, unit, presets, onchange(v), onclose(v), log }
-- onchange is called when the value changes (tap/preset/stepper/drag release = force; not called mid-drag, to avoid rendering intermediate states);
-- onclose is called on close (writes undo etc.).
-- Drag semantics: starting on the slider = adjust value; anywhere else = drag the panel (so it doesn't cover the object being adjusted on the canvas).
function M.showValuePicker(opts)
    local vmin, vmax = opts.min, opts.max
    local value = math.max(vmin, math.min(vmax, opts.value))
    local function clamp(v)
        return math.max(vmin, math.min(vmax, v))
    end
    local unit = opts.unit or ""

    -- Consistent with centred/brush-tip popups: the panel is carried by a MovableContainer (follows the finger, no ghosting).
    -- popup/mc are created by showCenteredDialog at the end of the function; forward-declared here for closures to reference
    -- (Lua locals must be declared before being referenced; they are assigned before any event fires)
    local popup, mc
    local popupPanelRect -- current panel region (for deferred refresh), assigned at the end

    local panel_w = math.floor(Screen:getWidth() * const.UI_WIDTH_WIDE)
    local pbar_w = panel_w - 2 * Size.padding.large -- slider width (leaving it undefined crashes paint)
    -- Slider slightly narrower than the buttons: subtract the panel FrameContainer's padding+border so the bar sits fully
    -- inside the panel content area, never touching/overrunning the edges at any DPI (after DPI scaling on the real device the slider once overlapped the buttons below)
    local slider_w = pbar_w - 2 * (Size.padding.default + Size.border.default)
    -- Stepper row step_bt is defined later; forward-declared here so refreshValue can capture it
    local step_bt
    local function refreshValue()
        if step_bt and step_bt.button_by_id then
            local vb = step_bt.button_by_id["value_btn"]
            if vb and vb.setText then
                vb:setText(tostring(math.floor(value + 0.5)) .. unit, vb.width)
            end
        end
    end

    -- Slider (with ticks) and the preset numbers below are laid out uniformly as "percentages of the max value" -
    -- min value + max*1/8..max*8/8 (floored, e.g. max=100 -> 1,12,25,...,100)
    local preset_values = {}
    local seen = {}
    local function addPreset(v)
        v = math.floor(v)
        if not seen[v] then
            seen[v] = true
            table.insert(preset_values, v)
        end
    end
    addPreset(vmin)
    for i = 1, 8 do
        addPreset(vmax * i / 8)
    end
    table.sort(preset_values)
    local ticks = {}
    for i, v in ipairs(preset_values) do
        ticks[i] = v
    end
    local progress = ProgressWidget:new{
        width = slider_w*0.97,
        height = Screen:scaleBySize(32), -- more compact than the default (scaleBySize(40)): shorter bar, doesn't visually stick to the buttons above/below
        ticks = ticks,
        last = vmax,
        percentage = (value - vmin) / math.max(1, vmax - vmin),
    }
    local progress_frame = FrameContainer:new{
        dimen = Geom:new{ w = slider_w, h = progress.height },
        progress,
    }
    local function setProgressPct()
        progress:setPercentage((value - vmin) / math.max(1, vmax - vmin))
    end
    -- Slider hit region (with touch margin); while dragging the finger may slide off the slider, and slider_wrap enlarges the range.
    -- Horizontal ±20 makes the end values easy to hit; vertically downward it extends only to the gap boundary with the preset keys (same expression
    -- as the layout's 3*vertical_large, exactly flush with the key area without overlap) - the old version expanded 30 on every side,
    -- spilling downward into the preset number keys' touch area, and since events reach child widgets in order, the slider layer got them first
    -- (slider_wrap comes before preset_bt), so the keys lost their touches (user found them hard to hit);
    -- 2px upward margin: the stepper row sits right above the slider, and stepper keys are earlier children with priority within their own area
    local function sliderHitRect()
        local d = progress.dimen
        if not d then
            return nil
        end
        local hit_w = Screen:scaleBySize(20)
        local hit_up = Screen:scaleBySize(2)
        local hit_down = 3 * Size.span.vertical_large
        return Geom:new{ x = d.x - hit_w, y = d.y - hit_up, w = d.w + 2 * hit_w, h = d.h + hit_up + hit_down }
    end
    -- Touch position -> value (within the slider hit region)
    local function posToValue(px, py)
        local r = sliderHitRect()
        if not r then
            return nil
        end
        if px < r.x or px > r.x + r.w or py < r.y or py > r.y + r.h then
            return nil
        end
        local pct = progress:getPercentageFromPosition(Geom:new{ x = px, y = py })
        if not pct then
            return nil
        end
        return clamp(vmin + math.floor(pct * (vmax - vmin) + 0.5))
    end

    -- Apply value: tap/preset/stepper/drag release (force) = apply to the canvas + "ui" refresh;
    -- mid-drag (not force) = only update the slider thumb/value label, don't call onchange or render the object on the canvas.
    -- Rendering the object's intermediate grey/width every tick builds up a refresh backlog on e-ink that leaves a "drag trail" of ghosting
    -- (the user explicitly doesn't want the path rendered while dragging); on release, force fills in the final state in one go;
    -- mid-drag uses the cheap "fast" refresh, no backlog and no ghosting
    local last_apply = 0
    local APPLY_INTERVAL = 0.06
    local function applyValue(v, force)
        value = clamp(v)
        refreshValue()
        setProgressPct()
        local now = UIManager:getTime()
        if not force and now - last_apply < APPLY_INTERVAL then
            return
        end
        last_apply = now
        if force then
            if opts.onchange then
                opts.onchange(value)
            end
            -- "ui" refresh of the panel region (deferred function: when merged with the object region's "ui" refresh it isn't downgraded;
            -- partial has higher priority, so sending a full-screen partial directly would downgrade the object region and leave ghosting)
            UIManager:setDirty(popup, function()
                local r = popupPanelRect()
                if r then return "ui", r end
                return "ui"
            end)
        else
            UIManager:setDirty(popup, function()
                local r = popupPanelRect()
                if r then return "fast", r end
                return "fast"
            end)
        end
    end

    -- Slider gesture wrapper: consumes tap/pan/hold on the slider (stops MovableContainer from dragging the panel away);
    -- while _dragging, the hit range expands to full screen (keeps adjusting even if the finger slides off the slider);
    -- release falls back to full screen and is only consumed while this layer is dragging, otherwise handed back to MovableContainer (panel drag).
    -- Note: KOReader gesture events are dispatched via Event:new(name, args, ev); the handler signature must be
    -- (_, ges) - args (gsseq.args) takes a slot even when nil, otherwise ges receives nil and crashes
    local slider_wrap
    slider_wrap = InputContainer:extend{
        dimen = Geom:new{ w = slider_w, h = progress.height },
        ges_events = {
            TapProgress = { GestureRange:new{ ges = "tap", range = function() return sliderHitRect() end } },
            PanProgress = { GestureRange:new{ ges = "pan", range = function()
                if slider_wrap._dragging then return popup.dimen end
                return sliderHitRect()
            end } },
            PanReleaseProgress = { GestureRange:new{ ges = "pan_release", range = function() return popup.dimen end } },
            HoldProgress = { GestureRange:new{ ges = "hold", range = function() return sliderHitRect() end } },
            HoldPanProgress = { GestureRange:new{ ges = "hold_pan", range = function()
                if slider_wrap._dragging then return popup.dimen end
                return sliderHitRect()
            end } },
            HoldReleaseProgress = { GestureRange:new{ ges = "hold_release", range = function() return popup.dimen end } },
        },
    }:new{}
    slider_wrap._dragging = false
    slider_wrap.hitRect = sliderHitRect -- exposed for tests: assert the touch area doesn't cover any keys
    function slider_wrap:onTapProgress(_, ges)
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, true)
        end
        return true -- consume when hitting the slider region (tap doesn't close the popup)
    end
    function slider_wrap:onPanProgress(_, ges)
        slider_wrap._dragging = true
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, false)
        end
        return true
    end
    function slider_wrap:onPanReleaseProgress(_, ges)
        if slider_wrap._dragging then
            applyValue(value, true) -- drag ended, fill in the final state
            slider_wrap._dragging = false
            return true
        end
        return false -- not a slider drag, hand over to MovableContainer
    end
    function slider_wrap:onHoldProgress(_, ges)
        return true -- holding the slider: consume, so MovableContainer doesn't drag the panel away
    end
    function slider_wrap:onHoldPanProgress(_, ges)
        slider_wrap._dragging = true
        local v = posToValue(ges.pos.x, ges.pos.y)
        if v then
            applyValue(v, false)
        end
        return true
    end
    function slider_wrap:onHoldReleaseProgress(_, ges)
        return slider_wrap:onPanReleaseProgress(_, ges)
    end
    slider_wrap[1] = progress_frame

    -- Preset steps (5 per row, values already generated as percentages of the max)
    local preset_rows = {}
    for i = 1, #preset_values, 5 do
        local row = {}
        for j = i, math.min(i + 4, #preset_values) do
            local pv = preset_values[j]
            table.insert(row, {
                text = tostring(pv) .. unit,
                callback = function()
                    applyValue(pv, true)
                end,
            })
        end
        table.insert(preset_rows, row)
    end
    local preset_bt = ButtonTable:new{
        width = pbar_w,
        buttons = preset_rows,
        zero_sep = true,
        show_parent = popup,
    }
    -- v62t: close button removed (tap outside to close)

    -- Stepper row (above the slider): -10/-1/[value]/+1/+10; the middle value is shown in black and updates live (no action)
    step_bt = ButtonTable:new{
        width = pbar_w,
        zero_sep = true,
        buttons = {{
            { text = "-10", callback = function() applyValue(value - 10, true) end },
            { text = "-1", callback = function() applyValue(value - 1, true) end },
            { id = "value_btn", text = tostring(math.floor(value + 0.5)) .. unit, enabled = true, callback = function() end },
            { text = "+1", callback = function() applyValue(value + 1, true) end },
            { text = "+10", callback = function() applyValue(value + 10, true) end },
        }},
        show_parent = popup,
    }

    -- Instant popup button response (same as the text popup, shared component)
    M.instantButtons(step_bt)
    M.instantButtons(preset_bt)

    -- Panel + unified shell: exactly the same as the centred/brush-tip popups (CenterContainer -> MovableContainer ->
    -- FrameContainer rounded white). Panel dragging is built into MovableContainer (follows the finger,
    -- setDirty("all") + old ∪ new "ui" refresh, no ghosting, no outline); slider dragging is consumed by slider_wrap.
    -- Note: ButtonTable gets no show_parent (the flash path was replaced by instantButtons, no effect)
    -- Title goes through showCenteredDialog's title mechanism (size 20, consistent with all popups)
    popup, mc = M.showCenteredDialog{
        name = "DrawingValuePicker",
        title = opts.title,
        anchor_x = opts.anchor_x, -- pass through top-level control horizontal anchoring
        content = VerticalGroup:new{
            align = "center",
            step_bt,
            -- VerticalSpan:new{ width = Size.span.vertical_large }, -- separate slider and stepper row, prevents sticking after DPI scaling on the real device
            slider_wrap,
            VerticalSpan:new{ width = 3*Size.span.vertical_large }, -- separate slider and preset buttons, prevents overlap/overrun
            preset_bt,
        },
        log = opts.log,
    }
    popup.min = vmin -- exposed to tests/callers to assert the value range
    popup.max = vmax
    -- Current panel region (for deferred refresh): MovableContainer dimen is updated at paint time
    popupPanelRect = function()
        local d = mc.dimen
        if not d then
            return nil
        end
        return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    end
    -- Callback on close (writes undo etc.)
    local orig_close_widget = popup.onCloseWidget
    function popup:onCloseWidget()
        if opts.onclose then
            opts.onclose(value)
        end
        if orig_close_widget then
            orig_close_widget(self)
        end
    end
    log(opts, "value picker shown", opts.title or "")
end

return M
