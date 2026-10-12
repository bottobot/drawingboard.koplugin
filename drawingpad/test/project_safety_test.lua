-- Kobo fork maintenance, 2026-10-11. AGPL-3.0; see ../../LICENSE and ../../NOTICE.
-- Regression fixtures use disposable files only. Run with native KOReader in
-- an isolated runtime, KO_HOME and /tmp mapped to private scratch storage.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/drawingpad/test/[^/]+$"))
package.path = root .. "/?.lua;" .. package.path
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local Project = require("drawingpad.projectfile")
local Canvas = require("drawingpad.drawing_canvas")
local lfs = require("libs/libkoreader-lfs")
local passed = 0
local function check(cond, why) assert(cond, why) end
local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then print("FAIL " .. name .. ": " .. tostring(err)); os.exit(1) end
    passed = passed + 1; print("PASS " .. name)
end
local PATH, MARKER = "/tmp/project_safety.drawing", "/tmp/project_safety_marker"
local EMPTY = "return {version=1,layers={{},{},{}},active_layer=2,layer_visible={true,false,true},layer_alpha={1,0.5,1},}"
local function read(path)
    local f = assert(io.open(path, "rb")); local text = f:read("*a"); assert(f:close()); return text
end
local function put(path, text)
    local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
local function no_temporary_files()
    for name in lfs.dir("/tmp") do
        check(not name:match("^project_safety%.drawing%.saving%-"), "temporary save leaked")
    end
end
local function operations()
    return { mkdir = lfs.mkdir, rmdir = lfs.rmdir, open = io.open,
        remove = os.remove, rename = os.rename, attributes = lfs.attributes }
end

section("legacy literals, defaults, escapes and pressure remain readable", function()
    local data = assert(Project.decode(EMPTY))
    check(data.layer_visible[2] == false and data.layer_alpha[2] == 0.5, "layer properties lost")
    local text = 'quotes " and \\; newline\nNUL\0; UTF-8 café'
    local encoded = string.format('return {version=1,layers={{},{{kind="freehand",gray=1,width=2,points={{x=1,y=2,f=0.3}}}},{{kind="text",gray=1,x=0,y=0,size=20,font="NotoSans-Regular.ttf",text=%q}}},}', text)
    local parsed = assert(Project.decode(encoded))
    check(parsed.layers[3][1].text == text and parsed.layers[2][1].points[1].f == 0.3, "Lua %%q escaping changed")
end)

section("calls, functions, expressions and trailing statements cannot execute", function()
    os.remove(MARKER)
    local malicious = 'io.open(' .. string.format('%q', MARKER) .. ',"w"):write("marker"); ' .. EMPTY
    for _, text in ipairs({ malicious, EMPTY .. '; io.open("ignored","w")',
        'return (function() return {} end)()', 'while true do end',
        'return {version=1,layers={{},{},{}},active_layer=1+1}',
        'return {version=1,layers={{},{},{}},active_layer=math.floor(2)}' }) do
        check(Project.decode(text) == nil, "executable content accepted")
    end
    check(lfs.attributes(MARKER) == nil, "project code ran")
end)

section("malformed data and bounded parser limits are rejected", function()
    for _, text in ipairs({
        'return {version=1,layers={{},{},{}},version=1}',
        'return {version=1,layers={{},{},{}},_bbox={}}',
        'return {version=1,layers={{},{},{}},active_layer=1e999}',
        'return {version=1,layers={{},{},{}},layer_alpha={1,"bad",1}}',
        'return {version=1,layers={{},{},{}},layer_visible=false}',
        'return {version=1,layers={{},{},{{kind="fill",gray=1,spans={},width="bad"}}}}',
        'return {version=1,layers={{},{},{{kind="line",gray=1,width=2}}}}',
        'return {version=1,layers={{},{},{}},extra=' .. string.rep('{', 20) .. string.rep('}', 20) .. '}',
        EMPTY .. string.rep(' ', Project.MAX_BYTES),
    }) do check(Project.decode(text) == nil, "invalid/oversized data accepted") end
end)

section("invalid imports preserve canvas, layers, visibility and undo", function()
    local canvas = Canvas:new{ on_close = function() end }
    canvas:_setTool("brush")
    canvas:onPan(nil, { pos = { x = 100, y = 300 }, start_pos = { x = 100, y = 300 } })
    canvas:onPanRelease(nil, { pos = { x = 100, y = 300 } })
    local element, undo, pixel = canvas.elements[1], #canvas.undo, canvas.canvas_bb:getPixel(100, 300).a
    for _, text in ipairs({ 'return {version=1,layers={{},{},{{kind="line",gray=1,width=2}}}}',
        'io.open(' .. string.format('%q', MARKER) .. ',"w"):write("marker");' .. EMPTY }) do
        put(PATH, text)
        check(canvas:_loadProject(PATH) == false, "invalid import reported success")
        check(canvas.elements[1] == element and #canvas.undo == undo, "drawing or undo changed")
        check(canvas.layer_visible[2] == true, "visibility changed")
        check(canvas.canvas_bb:getPixel(100, 300).a == pixel, "pixels changed")
    end
    canvas:onCloseWidget(); os.remove(PATH)
end)

section("atomic write preserves existing project on success and cleans scratch", function()
    put(PATH, "old project")
    check(Project.write(PATH, EMPTY), "save failed")
    check(read(PATH) == EMPTY, "saved content differs")
    check(Project.read(PATH), "saved content cannot be reopened")
    no_temporary_files(); os.remove(PATH)
end)

section("invalid save data cannot replace an existing file", function()
    put(PATH, EMPTY)
    check(not Project.write(PATH, 'return {version=99}'), "invalid save accepted")
    check(read(PATH) == EMPTY, "invalid save replaced previous project")
    no_temporary_files(); os.remove(PATH)
end)

section("canvas save failure reaches the UI without a Saved notification", function()
    local canvas = Canvas:new{ on_close = function() end }
    canvas.save_folder = "/tmp"
    local components = require("drawingpad.components")
    local write, toast = Project.write, components.showToast
    local messages = {}
    Project.write = function() return nil, "simulated disk full" end
    components.showToast = function(message) messages[#messages + 1] = message end
    local ok, err = pcall(function()
        check(canvas:_doSaveProject(PATH) == false, "canvas reported successful save")
        canvas:_doSaveProjectFlow("project_safety")
        check(#messages == 1 and messages[1]:match("^Save failed"), "failure did not reach UI")
    end)
    Project.write, components.showToast = write, toast
    canvas:onCloseWidget()
    check(ok, err)
end)

for _, mode in ipairs({ "open", "write", "write_throw", "close", "close_throw", "short", "rename" }) do
    section("failed " .. mode .. " preserves previous file and reports failure", function()
        put(PATH, EMPTY)
        local fs = operations()
        if mode == "rename" then fs.rename = function() return nil, "simulated rename error" end
        elseif mode == "open" then fs.open = function() return nil, "simulated open error" end
        else
            fs.open = function(path, flags)
                local actual = assert(io.open(path, flags))
                return {
                    write = function(_, text)
                        if mode == "write" then actual:write(text:sub(1, 10)); return nil, "simulated disk full" end
                        if mode == "write_throw" then error("simulated write exception") end
                        assert(actual:write(mode == "short" and text:sub(1, 10) or text)); return true
                    end,
                    close = function()
                        local ok, err = actual:close()
                        if mode == "close" then return nil, "simulated flush error" end
                        if mode == "close_throw" then error("simulated close exception") end
                        return ok, err
                    end,
                }
            end
        end
        local ok, err = Project.write(PATH, EMPTY, fs)
        check(not ok and type(err) == "string", "save failure was hidden")
        check(read(PATH) == EMPTY, "previous project overwritten")
        no_temporary_files(); os.remove(PATH)
    end)
end

section("pre-existing temporary paths are never used or removed", function()
    put(PATH, EMPTY)
    local fs, attempts = operations(), 0
    fs.mkdir = function() attempts = attempts + 1; return nil, "already exists" end
    fs.open = function() error("opened unowned temporary path") end
    fs.remove = function() error("removed unowned temporary path") end
    fs.rmdir = function() error("removed unowned temporary directory") end
    check(not Project.write(PATH, EMPTY, fs), "failed temporary acquisition accepted")
    check(attempts == 10 and read(PATH) == EMPTY, "existing project changed")
    os.remove(PATH)
end)
print("RESULT: all " .. passed .. " sections passed")
