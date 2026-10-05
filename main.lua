--[[--
Drawing board plugin (drawingboard.koplugin) - opens a full-screen drawing board

Entry point: Menu -> Tools -> Drawing Board
The board itself lives in the plugin directory at plugins/drawingboard.koplugin/drawingpad/drawing_canvas.lua (DrawingCanvas);
this plugin only registers the menu item and passes along the debug log path (written to drawingboard.log in the plugin directory).

Features: freehand brush (adjustable grey/width), line, rectangle, circle, arc, text insertion (font/size/grey),
eraser, undo/redo, clear, save PNG (DataStorage:getDataDir()/drawingboard/).
--]]

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local L = require("drawingpad.i18n")

local DrawingBoard = WidgetContainer:extend{
    name = "drawingboard",
    is_doc_only = false,
}

function DrawingBoard:init()
    self.ui.menu:registerToMainMenu(self)
end

function DrawingBoard:addToMainMenu(menu_items)
    menu_items.drawingboard = {
        -- Menu name follows the UI language (the i18n module decides from gettext.current_lang at load time);
        -- side effect: require adds <koplugin>/drawingpad/?.lua to package.path before
        -- this module can be found - pluginloader already adds <koplugin>/?.lua before dofile(main.lua),
        -- but drawingpad is a subdirectory, so a relative package name here relies on pluginloader's path injection
        text = L.t("Drawing Board", "绘图板"),
        sorting_hint = "more_tools",
        callback = function()
            local DrawingCanvas = require("drawingpad.drawing_canvas")
            local canvas = DrawingCanvas:new{
                on_close = function() end,
                -- Plugin directory: debug log + settings persistence (drawingpad_settings.lua, auto-saved on exit)
                plugin_path = self.path,
                log_path = self.path and (self.path .. "/drawingboard.log") or nil,
            }
            UIManager:show(canvas)
        end,
    }
end

return DrawingBoard
