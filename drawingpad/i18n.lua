--[[--
drawingpad.i18n - bilingual menus (v62n, following the implementation approach of plugin_manager.koplugin).
**English is the source language**: strings in code are always English; Chinese is looked up via dict (English -> Chinese).
Language resolution L.resolve(pref): the menu_lang setting ("en"/"zh") takes priority; default auto =
Chinese if gettext.current_lang starts with zh, otherwise English. Must be called before any UI construction
(in drawing_canvas:init); t()/x() pick values by the current language at runtime.
- t(en, zh): paired literal translation (compound/dynamic strings); zh falls back to en when missing.
- x(en): dictionary lookup dict[en]; returns the input unchanged if not found (single strings, maintained centrally).
--]]

local M = {
    lang = "en",
    -- Chinese lookup table (key = original English text; same approach as plugin_manager's LANG_TABLE)
    dict = {
        -- Category panel items (static labels)
        ["Tool"] = "工具",
        ["Options"] = "属性设置",
        ["Layer"] = "图层",
        ["Menu"] = "功能",
        ["Brush"] = "画笔",
        ["Line"] = "直线",
        ["Text"] = "文字",
        ["Tip"] = "笔触",
        ["Eraser"] = "橡皮",
        ["Rect"] = "矩形",
        ["Select"] = "选择",
        ["Fill"] = "填充",
        ["Undo"] = "撤销",
        ["Redo"] = "重做",
        ["Clear"] = "清空",
        ["Open"] = "打开",
        ["Export"] = "输出",
        ["Save"] = "保存",
        ["About"] = "关于",
        ["Exit"] = "退出",
        ["Home"] = "主目录",
        ["Up"] = "上一级",
        ["Use this folder"] = "选择此目录",
        ["Close"] = "关闭",
        ["Cancel"] = "取消",
        ["Update"] = "更新",
        ["Insert"] = "插入",
        ["root folder"] = "根目录",
        -- Popup titles
        ["Gray"] = "灰度",
        ["Width"] = "粗细",
        ["Opacity"] = "透明度",
        ["Edit text"] = "修改文字",
        ["Insert text"] = "插入文字",
        ["Save PNG"] = "保存 PNG",
        ["Save project(editable)"] = "保存工程(可再编辑)",
        ["Open project: "] = "打开工程: ",
        ["Choose save folder: "] = "选择保存文件夹: ",
        ["Max gray(0%=white 100%=black)"] = "最大灰度(0%=白 100%=黑)",
        ["Min gray(0%=white 100%=black)"] = "最小灰度(0%=白 100%=黑)",
        ["Random levels(2-256)"] = "随机分级数(2-256)",
        ["Fixed gray(0%=white 100%=black)"] = "固定灰度(0%=白 100%=黑)",
        ["Thickest(px)"] = "最粗(px)",
        ["Thinnest(px)"] = "最细(px)",
        ["Fixed width(px)"] = "固定粗细(px)",
        ["Max opacity(100%=opaque)"] = "最浓(100%=不透明 0%=全透明)",
        ["Min opacity(100%=opaque)"] = "最淡(100%=不透明 0%=全透明)",
        ["Fixed opacity(100%=opaque)"] = "固定透明度(100%=不透明)",
        ["Selected gray(0%=white 100%=black)"] = "选中对象灰度(0%=白 100%=黑)",
        ["Selected width(px)"] = "选中对象粗细(px)",
        ["Selected opacity(100%=opaque)"] = "选中对象透明度(100%=不透明)",
        ["Size(free)"] = "字号(无极调节)",
        ["Layer opacity(100%=opaque)"] = "当前层透明度(100%=不透明)",
        ["Choose font (%1 total)"] = "选择字体(共 %1 个)",
        ["Font: "] = "字体: ",
        ["Size: "] = "字号: ",
        ["Edit text (font/size via buttons below)"] = "修改文字内容(字体/字号用下方按钮)",
        ["Enter text to insert"] = "输入要插入的文字(灰度用工具栏调整)",
        ["Filename(auto .png)"] = "文件名(自动补 .png)",
        ["Filename(auto .drawing)"] = "文件名(自动补 .drawing)",
        ["Folder: root"] = "文件夹: 根目录",
        ["Folder: "] = "文件夹: ",
        -- Settings popup buttons
        ["Max"] = "最大",
        ["Min"] = "最小",
        ["Thick"] = "最粗",
        ["Thin"] = "最细",
        ["Levels"] = "分级",
        ["Levels:%d"] = "分级:%d",
        ["Fixed"] = "固定",
        ["Fixed:%s"] = "固定:%s",
        ["Max:"] = "最大:",
        ["Min:"] = "最小:",
        -- Brush tip menu (const.TIPS display names)
        ["Ellipse"] = "圆形",
        ["Square"] = "方形",
        ["Triangle"] = "正三角",
        ["Inv tri"] = "倒三角",
        ["Diamond"] = "菱形",
        ["Slash"] = "斜线",
        ["Backslash"] = "反斜线",
        -- Status bar abbreviations (const.TIP_NAMES)
        ["O"] = "圆",
        ["S"] = "方",
        ["T"] = "三",
        ["V"] = "倒",
        ["D"] = "菱",
        ["/"] = "斜",
        ["\\"] = "反",
        -- Status bar layers (const.LAYER_NAMES)
        ["bottom"] = "下层",
        ["middle"] = "中层",
        ["top"] = "上层",
        -- Toast/confirmation
        ["Clear this layer? Cannot be undone."] = "确定清空当前图层?此操作不可撤销。",
        ["Canvas is empty, nothing to save."] = "画板是空的,没有内容可保存。",
        ["Filename cannot contain / or \\"] = "文件名不能含 / 或 \\ 字符",
        ["Saved:"] = "已保存:",
        ["Save failed, check folder permission:"] = "保存失败,请检查目录权限:",
        ["File not found:"] = "文件不存在:",
        ["Corrupt project file:"] = "工程文件损坏:",
        ["Opened:"] = "已打开:",
        ["Unsaved content, close anyway?"] = "画板有未保存内容,确定关闭?",
        ["This object has no line width."] = "该对象没有线条粗细。",
        ["This object has no line width"] = "该对象没有线条粗细",
        ["No usable font found (fonts folder)."] = "未找到可用字体(fonts 目录)。",
        ["Tip menu failed to open"] = "笔触菜单打开失败",
        ["Tip menu render failed"] = "笔触菜单渲染失败",
        -- About/language switch
        ["drawingboard"] = "绘图板",
        ["Version:"] = "软件版本:",
        ["Author:"] = "作者:",
        ["Freehand/shapes/text/fill/layers"] = "功能:自由画笔/图形/文字/填充/多图层",
        ["Save to: koreader/drawingboard/"] = "保存路径:koreader/drawingboard/",
        ["Language: auto"] = "菜单语言:自动",
        ["Language: 中文"] = "菜单语言:中文",
        ["Language: English"] = "菜单语言:English",
        ["Menu language: English"] = "菜单语言已切换为英文,重开菜单生效",
        ["Menu language: Chinese"] = "菜单语言已切换为中文,重开菜单生效",
    },
}

-- Paired literal translation (compound/dynamic strings): source language is English
-- v62u: in auto mode (menu_lang never chosen manually) re-detect on every call - KOReader's language
-- can change mid-session (gettext takes effect immediately); if the plugin resolved only once at init it would stay on the old language
local detect_is_chinese -- forward declaration (defined below, referenced by M.t/M.x at runtime)
function M.t(en, zh)
    if M.pref == nil then
        M.lang = detect_is_chinese() and "zh" or "en"
    end
    if M.lang == "zh" then
        return zh ~= nil and zh or en
    end
    return en
end

-- Dictionary lookup (single string)
function M.x(en)
    if M.pref == nil then
        M.lang = detect_is_chinese() and "zh" or "en"
    end
    if M.lang == "zh" then
        local zh = M.dict[en]
        if zh ~= nil then
            return zh
        end
    end
    return en
end

-- Language detection (aligned with plugin_manager.koplugin: decided by gettext.current_lang at module load time)
--   local current_lang = gettext.current_lang or ""
--   local is_chinese = current_lang:match("^zh") and true or false
-- Difference: when current_lang is empty/"C" (POSIX unset, common in test environments), fall back to
-- G_reader_settings' language (the user's real choice); English only if that still isn't zh
function detect_is_chinese()
    local ok, current_lang = pcall(function()
        local gettext = require("gettext")
        return (gettext and gettext.current_lang) or ""
    end)
    if not ok or type(current_lang) ~= "string" then
        current_lang = ""
    end
    if current_lang ~= "" and current_lang ~= "C" then
        return current_lang:match("^zh") and true or false
    end
    local ok2, lang = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language") or nil
    end)
    return ok2 and type(lang) == "string" and lang:match("^zh") and true or false
end

M.lang = detect_is_chinese() and "zh" or "en"

-- Resolve language: pref = "en"/"zh" (manual switch in the About popup) overrides and locks; nil = auto (follows the system language on every string lookup)
function M.resolve(pref)
    M.pref = (pref == "en" or pref == "zh") and pref or nil
    if pref == "en" or pref == "zh" then
        M.lang = pref
        return M.lang
    end
    M.lang = detect_is_chinese() and "zh" or "en"
    return M.lang
end

return M
