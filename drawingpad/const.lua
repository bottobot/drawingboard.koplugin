--[[--
drawingpad.const - drawing board constants and pure utility functions (no UI dependencies).
Feature modules require this file for constants; pointSegDist is used for ink distance calculations.
--]]

-- Master switch for debug logging: true during development; false for release (zero IO, saves power)
local LOG_ENABLED = false

-- Delay (seconds) a finger must rest before shape tools show a preview
local SHAPE_PREVIEW_DELAY = 0.12

-- Select tool move/copy/rotate drag: once the finger rests for this delay, show the drop/transform preview at the current position
-- (debounces the stop position; 0.2s keeps feedback responsive while still filtering continuous drags; since v61r text objects also use 0.2s)
local MOVE_PREVIEW_DELAY = 0.2

-- Throttle interval (px/second) for drag-preview follow refreshes: once the preview appears, each pan updates the preview element,
-- and the screen refreshes merged regions per window (same order as stroke throttling; e-ink waveforms have a rate limit, prevents queueing stutter;
-- one extra refresh immediately on pen-up). Skipping redraws on tiny moves is guaranteed by _updateDragPreview's bbox dedup
local DRAG_PREVIEW_REFRESH_INTERVAL = 0.06

-- Rotation preview rebuild throttle angle (radians): while the preview follows, every finger move fully re-rasterises the selected object
-- (rotating a fill of hundreds of span rows takes milliseconds to hundreds of milliseconds); angle changes below this threshold skip the rebuild
-- and only update the drop position - re-rasterisation frequency drops to the same order as the repaint throttle, so drag-rotate no longer stutters
local DRAG_ROTATE_RECALC_ANGLE = 0.03

-- Stroke refresh throttle interval (seconds): e-ink waveform updates are rate-limited, refreshing on every pan event queues up and lags (stutter);
-- only one redraw is queued per window with merged refresh regions, plus one refresh immediately on pen-up
-- Thick strokes (line width ≥ THICK_WIDTH) have large refresh regions and high load, so the throttle interval is relaxed further to cut waveform refreshes
local STROKE_REFRESH_INTERVAL = 0.06
local THICK_WIDTH = 32
local THICK_REFRESH_INTERVAL = 0.1

-- Eraser tap tolerance (px): a tap farther than this from the nearest ink counts as tapping blank space, nothing is deleted
local PICK_TOLERANCE = 20

-- Fill tool: flood-fill colour tolerance (0-255 pixel value difference). The tolerance must be small enough that light strokes
-- (grey ≥0.08, pixel value ≤229) differing from the white background by >20 are recognised as boundaries, otherwise the fill leaks through light strokes
local FILL_TOLERANCE = 20
-- Fill edge-detection tolerance: when expanding to a neighbouring pixel, a local difference > this value between the two pixels counts as a boundary.
-- Independent of the "difference from seed colour" - light strokes (grey 5%~9%, pixel value 232~242) differ from the white background by >8
-- and become boundaries, fully removing the ceiling where a fixed tolerance missed even lighter strokes
local FILL_EDGE_TOLERANCE = 8

-- Transform handles: hit radius (px). Handles look small (scale square 12px / rotate dot 10px) so they don't obscure the picture;
-- a hit radius of 48 is much larger than the visual, making them easy to hit with a finger; tapping the selected object again toggles between corner scale/corner rotate
local HANDLE_HIT_RADIUS = 48

-- Text handle hit radius (px): text selection boxes are small and harder to hit, so the hit range is larger
local TEXT_HANDLE_HIT_RADIUS = 64

-- Pen-down dead zone tuning (v56): KOReader's gesture detector requires moving PAN_THRESHOLD (scaleByDPI(35),
-- about 44px on PW3 / about 33px in the emulator) after touch-down before sending the first pan event - arc information at the start of the stroke
-- is lost at the source inside the dead zone (the plugin receives no intermediate points); this is the main cause of "can't start a stroke with a curve".
-- While the board is open, the gesture detector instance's PAN_THRESHOLD is dynamically lowered to scaleByDPI(this value),
-- and restored on close: KOReader source is untouched, gesture behaviour outside the board is unaffected.
-- Smaller values make pen-down more responsive; too small (<8) makes slight drift during a tap register as a pan (tap becomes drag)
local GESTURE_PAN_THRESHOLD_DP = 10

-- Pen-down hold delay tuning (v56b): while the board is open, scale down the gesture detector's hold timer interval proportionally.
-- KOReader default HOLD_INTERVAL_MS=500: hold fires only after the finger stays still that long (only then does a resting pen-down show
-- a dot, and hold_pan follows the finger afterwards); slow pen-downs have to wait it out. Cutting it to 300ms makes slow pen-downs ink sooner.
-- Implemented as a ratio (new value/500), independent of the time module and units; a user-set interval shrinks by the same ratio.
-- Side effect: toolbar long-press toggles become more sensitive - taps slower than this interval from down to up are treated as long-presses,
-- triggering secondary functions (switching to [Redo]/[Clear] modes etc.); if mis-triggers are frequent, set it back to 350~400
local GESTURE_HOLD_INTERVAL_MS = 300

-- Pen-down debounce is split into two stages (v56, pen-down curve optimisation):
-- ① STROKE_EARLY_TRIGGER_DIST: once moved beyond this distance after touch-down, the stroke formally starts (becomes an in-progress stroke).
-- Smaller values start earlier, so small arcs at the start enter Catmull-Rom rendering sooner and keep their curvature;
-- 0 = start as soon as the first pan point arrives (most responsive, but a quick light tap starts a stroke).
-- ② STROKE_DEBOUNCE_DIST: micro-trace recording threshold (px). Tiny moves within the threshold are still recorded in the micro-trace,
-- and rendered as the complete starting path when the stroke starts; releasing during debounce with a micro-trace commits a short stroke along the full arc.
-- The two are separate: the micro-trace records early (keeps arc information), the stroke start triggers on its own threshold (tolerates pen-down jitter)
local STROKE_EARLY_TRIGGER_DIST = 1
local STROKE_DEBOUNCE_DIST = 1

-- Debounce: minimum shape size (px). Line length/rectangle longest side/circle radius below this is treated as an accidental touch and discarded
-- (scales with brush width: thick-brush accidental touches have a larger size threshold)
local SHAPE_MIN_SIZE = 8

-- Undo stack limit: beyond it the oldest records are dropped, preventing unbounded memory growth in long drawing sessions
local UNDO_LIMIT = 100

-- Per-stroke point limit: beyond it the stroke is evenly thinned on pen-up (keeping first and last). Slow strokes/long continuous drawing produce many
-- dense points within 1px; after capping, per-stroke memory and eraser/save scan costs are bounded, so long sessions no longer scale linearly
local MAX_STROKE_POINTS = 4096

-- Tool settings persistence keys: written to the plugin directory (drawingpad_settings.lua) on exit, read automatically on next open.
-- Only "drawing parameter" settings are persisted (grey/width/brush tip/font/font size/save folder):
-- menu/button state settings (filled/outline, eraser mode, select move/copy, undo/redo, refresh/clear)
-- are not persisted; each launch restores defaults = the toolbar's primary-function state (black text on white).
-- The "last_text" (last text content) field has an underscore and is handled separately when actions.lua loads/saves settings
local SETTING_KEYS = {
    "gray", "gray_min", "gray_max", "gray_levels", "gray_random",
    "width", "width_min", "width_max", "width_levels", "width_random",
    "alpha", "alpha_min", "alpha_max", "alpha_levels", "alpha_random",
    "alpha_blend",
    "tip", "save_folder",
    "font", "font_size",
}

-- v62n: UI name tables use English as the single source (the UI is English-only)
local TOOL_NAMES = {
    brush = "Brush",
    eraser = "Eraser",
    line = "Line",
    rect = "Rect",
    circle = "Ellipse",
    text = "Text",
    select = "Select",
    fill = "Fill",
}

-- Layer count: since v57 changed from hardcoded 3 to a constant, to ease future extension (named slots/locking etc.).
-- After changing LAYER_COUNT, also check the `((n-1) % 3) + 1` modulo formula in layers.lua and the array length of drawing_canvas's
-- layers={} initialisation (this constant isn't used directly there, but downstream can read it as the single source of truth).
local LAYER_COUNT = 3

-- Plugin version and author (About popup; version kept equal to or higher than GitHub eznas/drawingboard.koplugin)
local PLUGIN_VERSION = "v63"
local PLUGIN_AUTHOR = "eznas"

-- Layer names: index 1=bottom layer (drawn first, lowest) 2=middle layer 3=top layer (drawn last, highest);
-- occlusion follows the names: top covers middle, middle covers bottom
local LAYER_NAMES = { [1] = "bottom", [2] = "middle", [3] = "top" }

-- Brush tip shapes (brush/line only): internal name -> status bar abbreviation
local TIP_NAMES = {
    circle = "O",
    square = "S",
    triangle = "T",
    triangle_inv = "V",
    diamond = "D",
    slash = "/",
    backslash = "\\",
}
-- Brush tip menu items (internal name, display name)
local TIPS = {
    { "circle", "Ellipse" },
    { "square", "Square" },
    { "triangle", "Triangle" },
    { "triangle_inv", "Inv tri" },
    { "diamond", "Diamond" },
    { "slash", "Slash" },
    { "backslash", "Backslash" },
}

-- ============================ Unified UI constants (v59) ============================

-- Three UI grey levels (unified e-ink greyscale, avoiding magic numbers everywhere):
-- BAR = status bar background; HIGHLIGHT = highlight grey shared by the canvas selection box/transform handles;
-- the active panel background uses Blitbuffer.COLOR_LIGHT_GRAY (standard light grey, not defined here)
local UI_GRAY_BAR = 0.5
local UI_GRAY_HIGHLIGHT = 0.25

-- Popup width tiers (fraction of screen width): narrow = single-column menus (layer/brush tip rows), medium = category panels and two-column settings popups,
-- wide = sliders/folder browser/font list
local UI_WIDTH_NARROW = 0.3
local UI_WIDTH_MEDIUM = 0.5
local UI_WIDTH_WIDE = 0.85

-- Bottom-bar top-level entry icons (mdlight icon set names, resolved by name by IconWidget).
-- v59b: with long-press removed, refresh was promoted from the function panel to a top-level entry;
-- v59c: hide (minimise) moved to the far left, top-level save removed (the function panel already has it);
-- v59d: exit merged into the function panel, new top-level layer entry added, function panel fixed at far right
-- v59e: whole set unified to mdlight outline style (48 grid, stroke 1.8); v61i: bundled icons changed to
--   resource files under drawingpad/icons/ (menus.lua installs them into the user icons directory on first run),
--   which include those missing from mdlight (layers/up-down arrows) and from older device builds (appbar.menu/cre.render.reload)
-- Bottom-bar/restore button icon size (base pixels before scaleBySize; 40 was too big, 34 is about 15% smaller)
local TOOLBAR_ICON_PX = 34

local TOOLBAR_ICONS = {
    { id = "hide_btn",    icon = "dw.chevron.down" },
    -- v61m: the tool uses dw.edit (the bundled edit scaled down 10%; the original full-bleed solid looked too big; global edit isn't overridden)
    { id = "cat_tool",    icon = "dw.edit" },
    { id = "cat_prop",    icon = "appbar.settings" },
    { id = "cat_layer",   icon = "layers" },
    { id = "refresh_btn", icon = "cre.render.reload" },
    { id = "cat_func",    icon = "appbar.menu" },
}

-- Shortest distance from a point to a line segment
local function pointSegDist(px, py, x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len2 = dx * dx + dy * dy
    if len2 < 0.001 then
        return math.sqrt((px - x0) ^ 2 + (py - y0) ^ 2)
    end
    local t = ((px - x0) * dx + (py - y0) * dy) / len2
    t = math.max(0, math.min(1, t))
    local cx, cy = x0 + dx * t, y0 + dy * t
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

return {
    LOG_ENABLED = LOG_ENABLED,
    SHAPE_PREVIEW_DELAY = SHAPE_PREVIEW_DELAY,
    MOVE_PREVIEW_DELAY = MOVE_PREVIEW_DELAY,
    DRAG_PREVIEW_REFRESH_INTERVAL = DRAG_PREVIEW_REFRESH_INTERVAL,
    DRAG_ROTATE_RECALC_ANGLE = DRAG_ROTATE_RECALC_ANGLE,
    STROKE_REFRESH_INTERVAL = STROKE_REFRESH_INTERVAL,
    THICK_WIDTH = THICK_WIDTH,
    THICK_REFRESH_INTERVAL = THICK_REFRESH_INTERVAL,
    PICK_TOLERANCE = PICK_TOLERANCE,
    FILL_TOLERANCE = FILL_TOLERANCE,
    FILL_EDGE_TOLERANCE = FILL_EDGE_TOLERANCE,
    HANDLE_HIT_RADIUS = HANDLE_HIT_RADIUS,
    TEXT_HANDLE_HIT_RADIUS = TEXT_HANDLE_HIT_RADIUS,
    STROKE_EARLY_TRIGGER_DIST = STROKE_EARLY_TRIGGER_DIST,
    STROKE_DEBOUNCE_DIST = STROKE_DEBOUNCE_DIST,
    GESTURE_PAN_THRESHOLD_DP = GESTURE_PAN_THRESHOLD_DP,
    GESTURE_HOLD_INTERVAL_MS = GESTURE_HOLD_INTERVAL_MS,
    SHAPE_MIN_SIZE = SHAPE_MIN_SIZE,
    UNDO_LIMIT = UNDO_LIMIT,
    MAX_STROKE_POINTS = MAX_STROKE_POINTS,
    LAYER_COUNT = LAYER_COUNT,
    PLUGIN_VERSION = PLUGIN_VERSION,
    PLUGIN_AUTHOR = PLUGIN_AUTHOR,
    SETTING_KEYS = SETTING_KEYS,
    TOOL_NAMES = TOOL_NAMES,
    LAYER_NAMES = LAYER_NAMES,
    TIP_NAMES = TIP_NAMES,
    TIPS = TIPS,
    UI_GRAY_BAR = UI_GRAY_BAR,
    UI_GRAY_HIGHLIGHT = UI_GRAY_HIGHLIGHT,
    UI_WIDTH_NARROW = UI_WIDTH_NARROW,
    UI_WIDTH_MEDIUM = UI_WIDTH_MEDIUM,
    UI_WIDTH_WIDE = UI_WIDTH_WIDE,
    TOOLBAR_ICONS = TOOLBAR_ICONS,
    TOOLBAR_ICON_PX = TOOLBAR_ICON_PX,
    pointSegDist = pointSegDist,
}
