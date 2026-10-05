--[[--
drawingpad.i18n - UI string helpers. This Kobo fork is English-only: the Chinese dictionary,
the language auto-detection and the menu_lang setting were removed (2026-10).
The two helpers are kept so call sites stay identical to upstream (easier merges):
- t(en): paired literal (upstream passed a Chinese variant as a 2nd argument; ignored here)
- x(s): dictionary lookup (now the identity)
--]]

local M = {}

function M.t(en)
    return en
end

function M.x(s)
    return s
end

return M
