--[[--
drawingpad.actions - undo/redo/clear/refresh/save/close methods (DrawingCanvas mixin module).
--]]

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local components = require("drawingpad.components")
local const = require("drawingpad.const")
local L = require("drawingpad.i18n")
local _ = require("gettext")

local M = {}

-- v61p cleanup: after the v59b flattening, the old combined-button family (_doUndoRedo/_toggleUndoMode/
-- _doRefreshClear/_toggleClearMode) and the undo_mode/clear_mode fields have no UI entry point; all removed

-- Full-screen refresh (top-level bottom-bar refresh key): send a single full waveform to clear EPD ghosting, no longer replaying all elements.
-- v62d: the old version ran _renderAll first to rebuild the canvas, to fix "old partial redraws overrunning and corrupting the canvas" - since v61w
-- region redraws use an isolated temp BB and commits always replay in layer order, so incremental canvas state stays correct and the replay became pure overhead
-- (noticeably slower with many elements, measured by the user); content correction is still handled by the replay paths of layer visibility/edit operations.
-- If "canvas corrupted and refresh can't fix it" ever shows up, just restore self:_renderAll() here
function M:_refreshCanvas()
    UIManager:setDirty(self, "full")
    self:_log("full refresh")
end

-- ============================ Undo / Redo / Clear ============================

-- Push an undo record; beyond UNDO_LIMIT drop the oldest (prevents unbounded memory growth)
function M:_pushUndo(rec)
    table.insert(self.undo, rec)
    if #self.undo > const.UNDO_LIMIT then
        table.remove(self.undo, 1)
    end
end

-- Clear the current layer's redo stack: v61p fix - historically 17 sites did `self.redo = {}`, replacing the stack object with a new table,
-- breaking the binding to layers_redo[layer], so references drifted and redo records were lost after switching layers; must clear in place
function M:_clearRedo()
    for i = #self.redo, 1, -1 do
        self.redo[i] = nil
    end
end

-- Undo: operation record stack (add=remove that element, del=restore the deleted element to its original position)
-- Only redraw the affected region (union of extents of removed/restored elements), no full replay anymore
function M:_undo()
    local rec = table.remove(self.undo)
    if not rec then
        return
    end
    local region = nil
    if rec.kind == "add" then
        if rec.els then
            -- Compound record (e.g. stroke fill = fill + stroke): remove each by reference, refresh region is the union
            for _, el in ipairs(rec.els) do
                for i = #self.elements, 1, -1 do
                    if self.elements[i] == el then
                        table.remove(self.elements, i)
                        break
                    end
                end
                region = self:_mergeRegions(region, self:_elementRegion(el))
            end
        else
            -- Remove the element from elements (by reference)
            for i = #self.elements, 1, -1 do
                if self.elements[i] == rec.el then
                    table.remove(self.elements, i)
                    break
                end
            end
            region = self:_elementRegion(rec.el)
        end
    elseif rec.kind == "del" then
        -- Restore deleted elements to their original indices (ascending inserts keep positions; clamped to stay in bounds)
        for j = 1, #rec.els do
            local idx = math.min(rec.idxs[j], #self.elements + 1)
            table.insert(self.elements, idx, rec.els[j])
        end
        for _, el in ipairs(rec.els) do
            region = self:_mergeRegions(region, self:_elementRegion(el))
        end
    elseif rec.kind == "move" then
        -- Move undo: translate back by the reverse vector, redraw the before-undo ∪ after-undo region
        local old_region = self:_elementRegion(rec.el)
        self:_moveElement(rec.el, -rec.dx, -rec.dy)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    elseif rec.kind == "transform" then
        -- Transform undo: restore the geometry snapshot (scale/rotate), redraw the before-undo ∪ after-undo region
        local old_region = self:_elementRegion(rec.el)
        self:_restoreGeom(rec.el, rec.orig)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    end
    table.insert(self.redo, rec)
    self:_log("undo", rec.kind)
    if self._selected then
        region = self:_mergeRegions(region, self:_elementRegion(self._selected))
        self._selected = nil -- selected object may have changed after undo; clear selection (highlight is cleared by the region redraw)
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

function M:_redo()
    local rec = table.remove(self.redo)
    if not rec then
        return
    end
    local region = nil
    if rec.kind == "add" then
        if rec.els then
            -- Compound records are appended in list order (fill -> stroke), keeping fill below and stroke above in layer order
            for _, el in ipairs(rec.els) do
                table.insert(self.elements, el)
                region = self:_mergeRegions(region, self:_elementRegion(el))
            end
        else
            -- Append back at the end (add always commits by appending)
            table.insert(self.elements, rec.el)
            region = self:_elementRegion(rec.el)
        end
    elseif rec.kind == "del" then
        -- Delete again (by reference)
        for _, el in ipairs(rec.els) do
            for i = #self.elements, 1, -1 do
                if self.elements[i] == el then
                    table.remove(self.elements, i)
                    break
                end
            end
        end
        for _, el in ipairs(rec.els) do
            region = self:_mergeRegions(region, self:_elementRegion(el))
        end
    elseif rec.kind == "move" then
        -- Move redo: translate once more by the forward vector, redraw the before-redo ∪ after-redo region
        local old_region = self:_elementRegion(rec.el)
        self:_moveElement(rec.el, rec.dx, rec.dy)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    elseif rec.kind == "transform" then
        -- Transform redo: restore the final geometry snapshot
        local old_region = self:_elementRegion(rec.el)
        self:_restoreGeom(rec.el, rec.final)
        self:_cacheBBox(rec.el)
        region = self:_mergeRegions(old_region, self:_elementRegion(rec.el))
    end
    table.insert(self.undo, rec)
    self:_log("redo", rec.kind)
    if self._selected then
        region = self:_mergeRegions(region, self:_elementRegion(self._selected))
        self._selected = nil -- selected object may have changed after redo; clear selection (highlight is cleared by the region redraw)
    end
    if region then
        self:_redrawRegion(region)
        UIManager:setDirty(self, "partial", region)
    end
end

function M:_clearAll()
    if #self.elements == 0 then
        return
    end
    UIManager:show(ConfirmBox:new{
        text = L.x(_("Clear this layer? Cannot be undone.")),
        ok_text = L.x(_("Clear")),
        cancel_text = L.x(_("Cancel")),
        ok_callback = function()
            -- Clear only the current layer: reset that layer's elements/undo/redo in place, keeping references intact
            self.layers[self.active_layer] = {}
            self.elements = self.layers[self.active_layer]
            self.layers_undo[self.active_layer] = {}
            self.undo = self.layers_undo[self.active_layer]
            self.layers_redo[self.active_layer] = {}
            self.redo = self.layers_redo[self.active_layer]
            self:_invalidateTasks()
            self._stroke = nil
            self._stroke_pending = nil
            self._shape_start = nil
            self._erase_path = nil
            self:_cancelShapePreview()
            self._shape_preview_region = nil
            self._shape_pos = nil
            self._selected = nil
            self._select_drag = nil
            self._transform = nil
            self:_renderAll()
            self:_log("clear layer", self.active_layer)
        end,
    })
end

-- ============================ Save ============================

-- Save: show a dialog (filename input + folder picker); on confirm, run crop + encode deferred.
-- An empty board just shows a notice, no dialog
function M:_save()
    if #self.elements == 0 then
        components.showToast(_("Canvas is empty, nothing to save."), 2)
        return
    end
    local dlg
    local function folderLabel()
        local f = self.save_folder
        if f == "" then
            return L.t("Folder: root")
        end
        if #f > 26 then
            f = "…" .. f:sub(-24) -- truncate long absolute paths for display (limited button space)
        end
        return L.t("Folder: ") .. f
    end
    local function updateFolderLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["folder_btn"]
        if btn and btn.setText then
            btn:setText(folderLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = L.x("Save PNG"),
        input = os.date("drawing_%Y%m%d_%H%M%S"),
        input_hint = L.x("Filename(auto .png)"),
        buttons = {
            {
                { id = "folder_btn", text = folderLabel(),
                  callback = function() self:_pickSaveFolder(updateFolderLabel, function(name)
                      dlg:setInputText(name) -- tapping an existing PNG prefills the filename (.png appended automatically)
                  end) end },
            },
            {
                { text = L.x(_("Cancel")), id = "close",
                  callback = function() UIManager:close(dlg) end },
                { text = L.x(_("Save")), is_enter_default = true,
                  callback = function()
                      local name = dlg:getInputText()
                      UIManager:close(dlg)
                      self:_doSaveFlow(name)
                  end },
            },
        },
    }
    -- Dialog buttons respond immediately (drop the blocking flash_ui, shared component)
    components.instantButtons(dlg.button_table)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Run the save flow from the dialog input: build path -> add a number on name clash -> "Saving" notice -> deferred _doSave.
-- v57: reject slashes in filenames (prevents "/" acting as a directory separator into an unexpected path); retry once on failure (SD card occasionally busy)
function M:_doSaveFlow(filename)
    if not filename or filename == "" then
        filename = os.date("drawing_%Y%m%d_%H%M%S")
    end
    -- Filename must not contain path separators: input "a/b" would write b.png into a nonexistent a/ directory
    if filename:find("[/\\]") then
        components.showToast("Filename cannot contain / or \\", 3)
        return
    end
    filename = filename .. ".png" -- append extension automatically
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local dir = base
    if self.save_folder ~= "" then
        dir = self.save_folder -- absolute path (any folder from the folder browser; created if missing)
        if lfs.attributes(dir, "mode") ~= "directory" then
            pcall(lfs.mkdir, dir)
        end
    end
    local path = self:_nextSavePath(dir, lfs, filename)
    -- Defer to the next frame so the save dialog closes first; the blocking crop/encode is wrapped in pcall as a whole.
    -- Retry once on failure (after 0.5s): the real device's SD card is occasionally busy so the first write fails; the work must not be lost because of that
    UIManager:scheduleIn(0.01, function()
        local ok, saved_path = pcall(self._doSave, self, path)
        if ok and saved_path then
            self:_log("saved", saved_path)
            components.showToast(L.x("Saved:") .. "\n" .. saved_path, 4)
            return
        end
        self:_log("save failed, retrying", path, ok and "" or tostring(saved_path))
        UIManager:scheduleIn(0.5, function()
            -- Retry with a new path (the first attempt may have left a 0-byte broken file)
            local retry_path = self:_nextSavePath(dir, lfs, filename)
            local ok2, saved2 = pcall(self._doSave, self, retry_path)
            if ok2 and saved2 then
                self:_log("saved (retry)", saved2)
                components.showToast(L.x("Saved:") .. "\n" .. saved2, 4)
            else
                self:_log("save retry failed", retry_path, ok2 and "" or tostring(saved2))
                components.showToast(L.x("Save failed, check folder permission:") .. "\n" .. dir)
            end
        end)
    end)
end

-- Generate a non-clashing save path: add a number on name clash (avoids overwriting each other).
-- filename defaults to a timestamp name; tests can inject a fixed filename
function M:_nextSavePath(dir, lfs, filename)
    filename = filename or (os.date("drawing_%Y%m%d_%H%M%S") .. ".png")
    if not filename:find("%.png$") then
        filename = filename .. ".png"
    end
    local path = dir .. "/" .. filename
    local n = 1
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        local stem = filename:gsub("%.png$", "")
        path = dir .. "/" .. stem .. "_" .. n .. ".png"
    end
    return path
end

-- Actual encode and write (runs in the deferred task; blocks synchronously but the notice is already on screen).
-- The canvas is always full-screen (coordinates = screen coordinates); saving the whole canvas matches the device screen resolution exactly (no white-margin cropping).
-- Returns the saved path (success) or nil (failure); the disk write is wrapped in pcall so failure doesn't crash.
-- v57: verify the PNG magic after writing - writePNG swallows lodepng errors internally, and judging by "file exists" alone
-- would treat 0-byte/truncated files as success, especially when the real device's SD card is busy
function M:_doSave(path)
    if not self.canvas_bb then
        return nil
    end
    local lfs = require("libs/libkoreader-lfs")
    local ok = pcall(function()
        self.canvas_bb:writePNG(path)
    end)
    -- writePNG swallows lodepng errors internally, so judge success by whether the file was actually created
    local size = ok and lfs.attributes(path, "size")
    if not size then
        return nil
    end
    -- PNG magic is the first 8 bytes: 137 80 78 71 13 10 26 10; corrupt files (0-byte/truncated) are caught here
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local magic = f:read(8)
    f:close()
    if magic ~= string.char(137, 80, 78, 71, 13, 10, 26, 10) then
        self:_log("PNG magic mismatch", path, size, "bytes")
        pcall(os.remove, path) -- delete the broken file so _nextSavePath won't mistake the retry path as "taken"
        return nil
    end
    self:_log("saved", path, size, "bytes",
        string.format("(%dx%d = screen)", self.canvas_w, self.canvas_h))
    return path
end

-- ============================ Project file (re-editable) save/open ============================
-- v62d: elements are all plain data tables; serialised as a Lua chunk ("return {...}") they form the project file (.drawing):
-- 3 layers of elements + visibility/opacity/current layer. Reopening restores the objects, which can still be moved/transformed/edited/undone.

-- Recursive serialisation (handles only number/boolean/string/table; private fields starting with underscore such as _bbox are skipped,
-- and recomputed by _cacheBBox after loading)
local function serializeValue(v, out)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = string.format("%.4f", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "table" then
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            if type(k) == "number" then
                serializeValue(val, out)
                out[#out + 1] = ","
            elseif type(k) == "string" and type(val) ~= "function"
                and k:sub(1, 1) ~= "_" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                out[#out + 1] = k .. "="
                serializeValue(val, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    end
end

-- Serialise and write the .drawing file (small synchronous text write, pcall guards against permissions/busy SD)
function M:_doSaveProject(path)
    local data = {
        version = 1,
        active_layer = self.active_layer,
        layer_visible = self.layer_visible,
        layer_alpha = self.layer_alpha,
        layers = self.layers,
    }
    local out = { "return " }
    serializeValue(data, out)
    out[#out + 1] = "\n"
    local ok, err = pcall(function()
        local f = io.open(path, "w")
        if not f then
            error("cannot open " .. path)
        end
        f:write(table.concat(out))
        f:close()
    end)
    if not ok then
        self:_log("save project failed", path, tostring(err))
    end
    return ok
end

-- Save project: dialog (filename + folder); on confirm, write the .drawing file
function M:_saveProject()
    local has_content = false
    for _, els in ipairs(self.layers) do
        if #els > 0 then
            has_content = true
            break
        end
    end
    if not has_content then
        components.showToast(_("Canvas is empty, nothing to save."), 2)
        return
    end
    local dlg
    local function folderLabel()
        local f = self.save_folder
        if f == "" then
            return L.t("Folder: root")
        end
        if #f > 26 then
            f = "…" .. f:sub(-24)
        end
        return L.t("Folder: ") .. f
    end
    local function updateFolderLabel()
        local btn = dlg.button_table and dlg.button_table.button_by_id
            and dlg.button_table.button_by_id["folder_btn"]
        if btn and btn.setText then
            btn:setText(folderLabel(), btn.width)
            UIManager:setDirty(dlg, "partial")
        end
    end
    dlg = InputDialog:new{
        title = L.x("Save project(editable)"),
        input = os.date("drawing_%Y%m%d_%H%M%S"),
        input_hint = L.x("Filename(auto .drawing)"),
        buttons = {
            {
                { id = "folder_btn", text = folderLabel(),
                  callback = function() self:_pickSaveFolder(updateFolderLabel) end },
            },
            {
                { text = L.x(_("Cancel")), id = "close",
                  callback = function() UIManager:close(dlg) end },
                { text = L.x(_("Save")), is_enter_default = true,
                  callback = function()
                      local name = dlg:getInputText()
                      UIManager:close(dlg)
                      self:_doSaveProjectFlow(name)
                  end },
            },
        },
    }
    components.instantButtons(dlg.button_table)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function M:_doSaveProjectFlow(filename)
    if not filename or filename == "" then
        filename = os.date("drawing_%Y%m%d_%H%M%S")
    end
    if filename:find("[/\\]") then
        components.showToast("Filename cannot contain / or \\", 3)
        return
    end
    filename = filename .. ".drawing"
    local lfs = require("libs/libkoreader-lfs")
    local base = DataStorage:getDataDir() .. "/drawingboard"
    if lfs.attributes(base, "mode") ~= "directory" then
        pcall(lfs.mkdir, base)
    end
    local dir = (self.save_folder ~= "") and self.save_folder or base
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, dir)
    end
    -- Add a number on name clash (same semantics as PNG save; _nextSavePath hardcodes .png, so a separate small loop here)
    local stem = filename:gsub("%.drawing$", "")
    local path = dir .. "/" .. filename
    local n = 1
    while lfs.attributes(path, "mode") == "file" do
        n = n + 1
        path = dir .. "/" .. stem .. "_" .. n .. ".drawing"
    end
    if self:_doSaveProject(path) then
        components.showToast(L.x("Saved:") .. "\n" .. path, 4)
        self:_log("project saved", path)
    else
        components.showToast(L.x("Save failed, check folder permission:") .. "\n" .. dir, 4)
    end
end

-- Open project: the browser lists .drawing files (reusing the folder browser); selecting one loads it
function M:_openProject()
    self:_pickSaveFolder(nil, function(name)
        local dir = (self.save_folder ~= "") and self.save_folder
            or (DataStorage:getDataDir() .. "/drawingboard")
        self:_loadProject(dir .. "/" .. name .. ".drawing")
    end, "%.drawing$", L.x("Open project: "))
end

-- Load .drawing: clear the three layers' elements/undo/redo in place and then insert (keeps the binding to layers_*;
-- v61p lesson: swapping in new tables breaks the binding), restore visibility/opacity/current layer, full redraw
function M:_loadProject(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then
        components.showToast(L.x("File not found:") .. "\n" .. path, 3)
        return
    end
    local chunk_ok, chunk = pcall(loadfile, path)
    if not chunk_ok or type(chunk) ~= "function" then
        components.showToast(L.x("Corrupt project file:") .. "\n" .. path, 3)
        self:_log("load project: loadfile failed", path, tostring(chunk))
        return
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.layers) ~= "table" then
        components.showToast(L.x("Corrupt project file:") .. "\n" .. path, 3)
        self:_log("load project: bad data", path)
        return
    end
    for li = 1, 3 do
        local els = self.layers[li]
        for i = #els, 1, -1 do
            els[i] = nil
        end
        local und = self.layers_undo[li]
        for i = #und, 1, -1 do
            und[i] = nil
        end
        local red = self.layers_redo[li]
        for i = #red, 1, -1 do
            red[i] = nil
        end
        for _, el in ipairs(data.layers[li] or {}) do
            if type(el) == "table" and type(el.kind) == "string" then
                el._bbox = nil -- private fields aren't serialised; recomputed after loading
                table.insert(els, el)
                self:_cacheBBox(el)
            end
        end
    end
    local function copy3(src, default)
        local out = { true, true, true }
        if type(src) == "table" then
            for i = 1, 3 do
                out[i] = (src[i] == nil) and default or src[i]
            end
        end
        return out
    end
    self.layer_visible = copy3(data.layer_visible, true)
    self.layer_alpha = copy3(data.layer_alpha, 1.0)
    local n = math.max(1, math.min(3, math.floor(tonumber(data.active_layer) or 2)))
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
    self._canvas_mask = self:_visibleMask()
    self:_renderAll()
    UIManager:setDirty(self, "full")
    components.showToast(L.x("Opened:") .. "\n" .. path, 3)
    self:_log("project loaded", path)
end

-- ============================ Settings persistence ============================
-- Tool state settings (grey/width/brush tip/modes etc.) are auto-written to drawingpad_settings.lua in the plugin directory before exit,
-- and read back and restored on the next open. Skipped silently when there is no plugin directory (tests/direct construction).

function M:_loadSettings()
    if not self.plugin_path then
        return
    end
    local ok, s = pcall(function()
        local luasettings = require("luasettings")
        return luasettings:open(self.plugin_path .. "/drawingpad_settings.lua")
    end)
    if not ok or not s then
        self:_log("settings load failed")
        return
    end
    self._settings = s
    for _, k in ipairs(const.SETTING_KEYS) do
        local v = s:readSetting(k)
        if v ~= nil then
            self[k] = v
        end
    end
    -- Text content (last inserted text) is stored separately: the _last_text field has an underscore, so it isn't in the generic SETTING_KEYS loop.
    -- v57: also store _last_font/_last_font_size so the "font last used for text" survives restarts (v52 stored only the text content,
    -- insert mode fell back to the self.font toolbar font instead of the last text font - after a restart the user saw the font change).
    local function readUnderscore(key)
        local v = s:readSetting(key)
        if v ~= nil then
            self["_" .. key] = v
        end
    end
    readUnderscore("last_text")
    readUnderscore("last_font")
    readUnderscore("last_font_size")
    self:_log("settings loaded")
end

function M:_saveSettings()
    if not self._settings then
        return
    end
    for _, k in ipairs(const.SETTING_KEYS) do
        self._settings:saveSetting(k, self[k])
    end
    -- v57: handle the three underscore fields together (_last_text/_last_font/_last_font_size)
    local function saveUnderscore(key, value)
        if value ~= nil then
            self._settings:saveSetting(key, value)
        end
    end
    saveUnderscore("last_text", self._last_text)
    saveUnderscore("last_font", self._last_font)
    saveUnderscore("last_font_size", self._last_font_size)
    local ok = pcall(function() self._settings:flush() end)
    self:_log("settings saved", ok)
end

-- ============================ Close ============================

function M:_onClose()
    self:_saveSettings() -- auto-save tool settings to the plugin directory before exit
    local function doClose()
        -- Explicit full refresh: ensures the underlying page fully redraws after closing the full-screen board (a plain close relies only
        -- on a fallback partial refresh, which isn't enough on e-ink to clear the previous frame; the page would look unrefreshed)
        UIManager:close(self, "full")
        self:_log("closed")
        if self.on_close then
            self.on_close()
        end
    end
    -- v61q: prompt if any layer has content - self.elements points only to the current layer,
    -- checking only it would miss unsaved content where "other layers were drawn on but the current layer is blank"
    local has_content = false
    for _, els in ipairs(self.layers) do
        if #els > 0 then
            has_content = true
            break
        end
    end
    if has_content then
        UIManager:show(ConfirmBox:new{
            text = L.x("Unsaved content, close anyway?"),
            ok_text = L.x(_("Close")),
            cancel_text = L.x(_("Cancel")),
            ok_callback = doClose,
        })
    else
        doClose()
    end
end

-- The hardware Back key fires the "Close" event -> goes through the same close confirmation
function M:onClose()
    self:_onClose()
    return true
end

-- Free the canvas BlitBuffer on close (pcall-protected so the close flow can't crash)
function M:onCloseWidget()
    local ok, err = pcall(function()
        -- Close any category panel still open (exit button/physical Back and other close paths all pass through here,
        -- otherwise the panel stays in the window stack and the menu is left hanging on screen after the board closes)
        if self._category_popup then
            -- Clear _open_cat first so the panel's own onCloseWidget won't call back into _refreshToolbar
            self._open_cat = nil
            UIManager:close(self._category_popup, "full")
            self._category_popup = nil
        end
        -- Cancel all pending scheduled tasks so callbacks can't touch freed state after close
        self:_invalidateTasks()
        -- Restore the gesture detector's PAN_THRESHOLD (lowered while the board is open; see gestures._applyGestureTuning)
        self:_restoreGestureTuning()
        self:_cancelShapePreview()
        self._shape_preview_region = nil
        self._shape_pos = nil
        if self.canvas_bb and self.canvas_bb.free then
            self.canvas_bb:free()
            self.canvas_bb = nil
        end
        -- Free the visibility-toggle ping-pong cache image (capability probe: the real device once rolled back to an old core without the cache;
        -- a bare call would log an error on every close here, though it's the very last step and cleanup is long done)
        if self._invalidateVisCache then
            self:_invalidateVisCache()
        end
    end)
    if not ok then
        logger.info("drawingpad: onCloseWidget error:", tostring(err))
    end
end

return M
