-- Kobo fork maintenance, 2026-10-11. AGPL-3.0; see ../LICENSE and ../NOTICE.
-- Read the literal-data subset written by upstream v62/v63 without compiling
-- or executing Lua. Keep the existing .drawing format and legacy files usable.
local M = { MAX_BYTES = 8 * 1024 * 1024 }
local MAX_DEPTH, MAX_ENTRIES, MAX_STRING = 16, 500000, 65536
local function fail(message) error(message, 0) end
local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function parse(text)
    local pos, entries = 1, 0
    local function whitespace()
        local _, last = text:find("^[ \t\r\n]*", pos)
        pos = (last or pos - 1) + 1
    end
    local function identifier()
        local name = text:match("^[A-Za-z_][A-Za-z0-9_]*", pos)
        if name then pos = pos + #name end
        return name
    end
    local escapes = { a = "\a", b = "\b", f = "\f", n = "\n",
        r = "\r", t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
    local function quoted()
        local quote, out, size = text:sub(pos, pos), {}, 0
        pos = pos + 1
        while pos <= #text do
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == quote then return table.concat(out) end
            if c == "\\" then
                c = text:sub(pos, pos)
                pos = pos + 1
                if c:match("%d") then
                    local digits = c .. (text:match("^%d?%d?", pos) or "")
                    pos = pos + #digits - 1
                    local byte = tonumber(digits)
                    if byte > 255 then fail("invalid string escape") end
                    c = string.char(byte)
                elseif c == "\n" then c = "\n"
                elseif c == "\r" then
                    if text:sub(pos, pos) == "\n" then pos = pos + 1 end
                    c = "\n"
                elseif escapes[c] then c = escapes[c]
                else fail("unsupported string escape") end
            elseif c == "\n" or c == "\r" then fail("unescaped newline") end
            size = size + #c
            if size > MAX_STRING then fail("project string too large") end
            out[#out + 1] = c
        end
        fail("unterminated string")
    end
    local value
    value = function(depth)
        if depth > MAX_DEPTH then fail("project nesting too deep") end
        whitespace()
        local c = text:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local out, index = {}, 0
            whitespace()
            while text:sub(pos, pos) ~= "}" do
                entries = entries + 1
                if entries > MAX_ENTRIES then fail("too many project entries") end
                local start, name = pos, identifier()
                whitespace()
                local key
                if name and text:sub(pos, pos) == "=" then
                    if name:sub(1, 1) == "_" then fail("private project field") end
                    key, pos = name, pos + 1
                else
                    pos, index = start, index + 1
                    key = index
                end
                if out[key] ~= nil then fail("duplicate project field") end
                out[key] = value(depth + 1)
                whitespace()
                c = text:sub(pos, pos)
                if c == "," or c == ";" then
                    pos = pos + 1
                    whitespace()
                elseif c ~= "}" then fail("expected table separator") end
            end
            pos = pos + 1
            return out
        elseif c == '"' or c == "'" then return quoted()
        elseif c:match("[%d+%-%.]") then
            local token = text:match("^[+-]?%d+%.?%d*[eE][+-]?%d+", pos)
                or text:match("^[+-]?%d+%.?%d*", pos)
                or text:match("^[+-]?%.%d+", pos)
            local number = token and tonumber(token)
            if not finite(number) then fail("invalid project number") end
            pos = pos + #token
            return number
        else
            local word = identifier()
            if word == "true" then return true end
            if word == "false" then return false end
            fail("expected literal project data")
        end
    end
    whitespace()
    if identifier() ~= "return" then fail("expected project data header") end
    local data = value(1)
    whitespace()
    if pos <= #text then fail("unexpected trailing project content") end
    return data
end

local function array(t, limit, name)
    if type(t) ~= "table" then fail(name .. " must be an array") end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > limit then
            fail("invalid " .. name .. " index")
        end
        count = count + 1
    end
    if count ~= #t then fail("sparse " .. name) end
    return count
end
local function number(t, k, min, max, optional)
    local n = t[k]
    if n == nil and optional then return end
    if not finite(n) or n < min or n > max then fail("invalid " .. k) end
end
local function points(t, name)
    array(t, 100000, name)
    for _, p in ipairs(t) do
        if type(p) ~= "table" then fail("invalid point") end
        number(p, "x", -32768, 32768)
        number(p, "y", -32768, 32768)
        number(p, "f", 0.01, 1, true)
    end
end
local function validate(data)
    if type(data) ~= "table" or data.version ~= 1 then fail("unsupported project version") end
    if array(data.layers, 3, "layers") ~= 3 then fail("project needs three layers") end
    number(data, "active_layer", 1, 3, true)
    if data.active_layer and data.active_layer % 1 ~= 0 then fail("invalid active layer") end
    data.active_layer = data.active_layer or 2
    if data.layer_visible == nil then data.layer_visible = { true, true, true } end
    if data.layer_alpha == nil then data.layer_alpha = { 1, 1, 1 } end
    if array(data.layer_visible, 3, "visibility") ~= 3
        or array(data.layer_alpha, 3, "opacity") ~= 3 then fail("invalid layer properties") end
    local tips = { circle = true, square = true, triangle = true,
        triangle_inv = true, diamond = true, slash = true, backslash = true }
    local total = 0
    for li = 1, 3 do
        if type(data.layer_visible[li]) ~= "boolean" then fail("invalid visibility") end
        number(data.layer_alpha, li, 0, 1)
        total = total + array(data.layers[li], 10000, "elements")
        if total > 10000 then fail("too many elements") end
        for _, el in ipairs(data.layers[li]) do
            if type(el) ~= "table" then fail("invalid element") end
            -- Recognised numeric fields must be well typed even when optional
            -- for this kind: later selection/transform paths can inspect them.
            for _, k in ipairs({ "x", "y", "x0", "y0", "x1", "y1", "cx", "cy" }) do
                number(el, k, -32768, 32768, true)
            end
            number(el, "width", 0.01, 800, true)
            number(el, "size", 1, 800, true)
            number(el, "sx", 0.01, 16, true); number(el, "sy", 0.01, 16, true)
            number(el, "gray", 0, 1)
            number(el, "alpha", 0, 1, true)
            number(el, "rot", -10000, 10000, true)
            if el.filled ~= nil and type(el.filled) ~= "boolean" then fail("invalid fill flag") end
            if el.tip ~= nil and not tips[el.tip] then fail("invalid brush tip") end
            if el.blend ~= nil and el.blend ~= "normal" and el.blend ~= "multiply"
                and el.blend ~= "dodge" then fail("invalid blend mode") end
            local kind = el.kind
            if kind == "freehand" or kind == "eraser" or kind == "poly" then
                number(el, "width", 0.01, 800)
                points(el.points, "points")
            elseif kind == "line" or kind == "rect" then
                number(el, "width", 0.01, 800)
                for _, k in ipairs({ "x0", "y0", "x1", "y1" }) do number(el, k, -32768, 32768) end
            elseif kind == "circle" then
                number(el, "width", 0.01, 800)
                number(el, "cx", -32768, 32768); number(el, "cy", -32768, 32768)
                number(el, "r", 0, 8192, true); number(el, "rx", 0, 8192, true)
                number(el, "ry", 0, 8192, true)
                if el.rx == nil and el.r == nil then fail("missing radius") end
            elseif kind == "fill" then
                array(el.spans, 100000, "fill spans")
                for _, sp in ipairs(el.spans) do
                    if array(sp, 3, "span") ~= 3 then fail("invalid fill span") end
                    for i = 1, 3 do number(sp, i, -32768, 32768) end
                    if sp[2] > sp[3] then fail("reversed fill span") end
                end
                if el.src_points then points(el.src_points, "source points") end
            elseif kind == "text" then
                number(el, "x", -32768, 32768); number(el, "y", -32768, 32768)
                number(el, "size", 1, 800)
                number(el, "sx", 0.01, 16, true); number(el, "sy", 0.01, 16, true)
                if type(el.text) ~= "string" or #el.text > 4096
                    or type(el.font) ~= "string" or #el.font > 256 then fail("invalid text") end
            else fail("unknown element kind") end
        end
    end
    return data
end

function M.decode(text)
    if type(text) ~= "string" or #text > M.MAX_BYTES then return nil, "project exceeds 8 MiB" end
    local ok, data = pcall(function() return validate(parse(text)) end)
    if not ok then return nil, tostring(data) end
    return data
end

function M.read(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil, "not a project file" end
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local ok, text = pcall(f.read, f, M.MAX_BYTES + 1)
    local closed, close_err = f:close()
    if not ok then return nil, tostring(text) end
    if not closed then return nil, close_err end
    return M.decode(text or "")
end

local save_sequence = 0
-- A sibling directory is acquired atomically; never follow a pre-existing temp
-- file/symlink. Rename only a fully written, closed and size-checked file.
-- Optional operations support deterministic I/O-failure regression fixtures.
function M.write(path, text, operations)
    local valid, err = M.decode(text)
    if not valid then return nil, err end
    local lfs = require("libs/libkoreader-lfs")
    local fs = operations or { mkdir = lfs.mkdir, rmdir = lfs.rmdir,
        open = io.open, remove = os.remove, rename = os.rename, attributes = lfs.attributes }
    local directory
    for _ = 1, 10 do
        save_sequence = save_sequence + 1
        local candidate = path .. ".saving-" .. os.time() .. "-" .. save_sequence
        if fs.mkdir(candidate) then directory = candidate; break end
    end
    if not directory then return nil, "cannot create temporary save directory" end
    local temporary, handle = directory .. "/project.tmp", nil
    local ok, problem = pcall(function()
        local why
        handle, why = fs.open(temporary, "wb")
        if not handle then fail(why or "cannot open temporary file") end
        local written, write_err = handle:write(text)
        if not written then fail(write_err or "project write failed") end
        local closed, close_err = handle:close()
        if not closed then fail(close_err or "project close failed") end
        handle = nil
        if fs.attributes(temporary, "size") ~= #text then fail("incomplete project write") end
        local renamed, rename_err = fs.rename(temporary, path)
        if not renamed then fail(rename_err or "project rename failed") end
    end)
    if handle then pcall(handle.close, handle) end
    pcall(fs.remove, temporary)
    pcall(fs.rmdir, directory)
    if not ok then return nil, tostring(problem) end
    return true
end
return M
