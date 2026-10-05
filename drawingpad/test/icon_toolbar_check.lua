--[[--
Bottom-bar icon rendering self-check: construct a DrawingCanvas, really paint the toolbar area to a PNG, and manually verify that the 6
icons are consistent in style/size (solid vs outline is obvious at a glance). Run the same way as render_test.lua:
    cd koreader-emulator-x86_64-linux-gnu-debug/koreader && ./luajit \
      plugins/drawingboard.koplugin/drawingpad/test/icon_toolbar_check.lua <output.png>
--]]

local __t_src = debug.getinfo(1, "S").source
local __t_dir = __t_src:match("^@(.*)[/\\][^/\\]*$") or "."
local __t_plugin = __t_dir:match("^(.*)[/\\]drawingpad[/\\]test$") or __t_dir
if not package.path:find(__t_plugin, 1, true) then
    package.path = __t_plugin .. "/?.lua;" .. package.path
end

require("setupkoenv")

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local DrawingCanvas = require("drawingpad.drawing_canvas")
local canvas = DrawingCanvas:new{ on_close = function() end }
assert(canvas.toolbar, "toolbar not built on init")

local W = canvas.dimen.w
local H = canvas.toolbar_h
local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)
canvas.toolbar:paintTo(bb, 0, 0)

local out = arg and arg[1] or "/tmp/toolbar_icons.png"
bb:writePNG(out)
bb:free()
print("toolbar PNG written:", out, W .. "x" .. H)

-- Verify the plugin's bundled icons (drawingpad/icons/*.svg) were installed into the user icons directory with identical content
local function fileContent(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end
local src_dir = __t_dir:gsub("test$", "icons")
local icons_dir = DataStorage:getDataDir() .. "/icons"
for name in require("libs/libkoreader-lfs").dir(src_dir) do
    if name:match("%.svg$") then
        local src = fileContent(src_dir .. "/" .. name)
        local installed = fileContent(icons_dir .. "/" .. name)
        assert(src and installed == src, name .. " stale or missing in user icons dir")
    end
end

-- Also paint the restore button (minimised state) to a PNG for visual inspection
local rb = canvas.restore_btn
assert(rb, "restore_btn missing")
local rw = rb.dimen and rb.dimen.w or 90
local rh = rb.dimen and rb.dimen.h or 44
local bb2 = Blitbuffer.new(rw, rh, Blitbuffer.TYPE_BB8)
bb2:paintRect(0, 0, rw, rh, Blitbuffer.COLOR_WHITE)
rb:paintTo(bb2, 0, 0)
local out2 = (arg and arg[1] or "/tmp/toolbar_icons.png"):gsub("%.png$", "_restore.png")
bb2:writePNG(out2)
bb2:free()
print("restore button PNG written:", out2, rw .. "x" .. rh)
print("PASS: bundled icons installed & up-to-date")
