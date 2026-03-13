-- menu.lua — Simple UI
-- Builds the full settings submenu registered in the KOReader main menu
-- (Top Bar, Bottom Bar, Quick Actions, Pagination Bar, Desktop).
-- Returns an installer: require("menu")(plugin) populates plugin.addToMainMenu.

local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local PathChooser     = require("ui/widget/pathchooser")
local SortWidget      = require("ui/widget/sortwidget")
local Device          = require("device")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local _ = require("gettext")

local Config    = require("config")
local Bottombar = require("bottombar")

-- ---------------------------------------------------------------------------
-- Installer function
-- ---------------------------------------------------------------------------

return function(SimpleUIPlugin)

SimpleUIPlugin.addToMainMenu = function(self, menu_items)
    local plugin = self

    -- Local aliases for Config functions.
    local loadTabConfig       = Config.loadTabConfig
    local saveTabConfig       = Config.saveTabConfig
    local getCustomQAList     = Config.getCustomQAList
    local saveCustomQAList    = Config.saveCustomQAList
    local getCustomQAConfig   = Config.getCustomQAConfig
    local saveCustomQAConfig  = Config.saveCustomQAConfig
    local deleteCustomQA      = Config.deleteCustomQA
    local nextCustomQAId      = Config.nextCustomQAId
    local getTopbarConfig     = Config.getTopbarConfig
    local saveTopbarConfig    = Config.saveTopbarConfig
    local _ensureHomePresent  = Config._ensureHomePresent
    local _sanitizeLabel      = Config.sanitizeLabel
    local _homeLabel          = Config.homeLabel
    local _getNonFavoritesCollections = Config.getNonFavoritesCollections
    local ALL_ACTIONS         = Config.ALL_ACTIONS
    local ACTION_BY_ID        = Config.ACTION_BY_ID
    local TOPBAR_ITEMS        = Config.TOPBAR_ITEMS
    local TOPBAR_ITEM_LABEL   = Config.TOPBAR_ITEM_LABEL
    local MAX_CUSTOM_QA       = Config.MAX_CUSTOM_QA
    local CUSTOM_ICON         = Config.CUSTOM_ICON
    local CUSTOM_PLUGIN_ICON  = Config.CUSTOM_PLUGIN_ICON
    local CUSTOM_DISPATCHER_ICON = Config.CUSTOM_DISPATCHER_ICON
    local TOTAL_H             = Bottombar.TOTAL_H
    local MAX_LABEL_LEN       = Config.MAX_LABEL_LEN

    -- -----------------------------------------------------------------------
    -- Mode radio-item helper
    -- -----------------------------------------------------------------------

    local function modeItem(label, mode_value)
        return {
            text         = label,
            radio        = true,
            checked_func = function() return Config.getNavbarMode() == mode_value end,
            callback     = function()
                G_reader_settings:saveSetting("navbar_mode", mode_value)
                plugin:_scheduleRebuild()
            end,
        }
    end

    -- -----------------------------------------------------------------------
    -- Tab and position menu builders
    -- -----------------------------------------------------------------------

    local function makePositionMenu(pos)
        local items        = {}
        local cached_tabs
        local cached_labels = {}

        local function getTabs()
            if not cached_tabs then cached_tabs = loadTabConfig() end
            return cached_tabs
        end

        local function getResolvedLabel(id)
            if not cached_labels[id] then
                if id:match("^custom_qa_%d+$") then
                    cached_labels[id] = getCustomQAConfig(id).label
                elseif id == "home" then
                    cached_labels[id] = _homeLabel()
                else
                    cached_labels[id] = (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
                end
            end
            return cached_labels[id]
        end

        local pool = {}
        for __, action in ipairs(ALL_ACTIONS) do pool[#pool + 1] = action.id end
        for __, qa_id in ipairs(getCustomQAList()) do pool[#pool + 1] = qa_id end

        for __, id in ipairs(pool) do
            local _id = id
            items[#items + 1] = {
                text_func    = function()
                    local lbl  = getResolvedLabel(_id)
                    local tabs = getTabs()
                    for i, tid in ipairs(tabs) do
                        if tid == _id and i ~= pos then
                            return lbl .. "  (#" .. i .. ")"
                        end
                    end
                    return lbl
                end,
                checked_func = function() return getTabs()[pos] == _id end,
                callback     = function()
                    local tabs    = loadTabConfig()
                    cached_tabs   = nil
                    cached_labels = {}
                    local old_id  = tabs[pos]
                    if old_id == _id then return end
                    tabs[pos] = _id
                    for i, tid in ipairs(tabs) do
                        if i ~= pos and tid == _id then tabs[i] = old_id; break end
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        table.sort(items, function(a, b)
            local ta = a.text_func()
            local tb = b.text_func()
            return (ta:match("^(.-)%s+%(#") or ta):lower() < (tb:match("^(.-)%s+%(#") or tb):lower()
        end)
        return items
    end

    local function getActionLabel(id)
        if not id then return "?" end
        if id:match("^custom_qa_%d+$") then return getCustomQAConfig(id).label end
        if id == "home" then return _homeLabel() end
        return (ACTION_BY_ID[id] and ACTION_BY_ID[id].label) or id
    end

    local function makeTabsMenu()
        local items = {}

        items[#items + 1] = {
            text           = _("Arrange tabs"),
            keep_menu_open = true,
            separator      = true,
            callback       = function()
                local tabs       = loadTabConfig()
                local sort_items = {}
                for __, tid in ipairs(tabs) do
                    sort_items[#sort_items + 1] = { text = getActionLabel(tid), orig_item = tid }
                end
                local sort_widget = SortWidget:new{
                    title             = _("Arrange tabs"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local new_tabs = {}
                        for __, item in ipairs(sort_items) do new_tabs[#new_tabs + 1] = item.orig_item end
                        _ensureHomePresent(new_tabs)
                        saveTabConfig(new_tabs)
                        plugin:_scheduleRebuild()
                    end,
                }
                UIManager:show(sort_widget)
            end,
        }

        local toggle_items = {}
        local desktop_on   = G_reader_settings:nilOrTrue("navbar_desktop_enabled")
        local action_pool  = {}
        for __, action in ipairs(ALL_ACTIONS) do action_pool[#action_pool + 1] = action.id end
        for __, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end

        for __, aid in ipairs(action_pool) do
            if not desktop_on and (aid == "home" or aid == "desktop") then goto continue_action end
            local _aid = aid
            local _base_label = getActionLabel(_aid)
            toggle_items[#toggle_items + 1] = {
                _base        = _base_label,
                text_func    = function()
                    for __, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return _base_label end
                    end
                    local rem = 5 - #loadTabConfig()
                    if rem <= 0 then return _base_label .. "  (0 left)" end
                    if rem <= 2 then return _base_label .. "  (" .. rem .. " left)" end
                    return _base_label
                end,
                checked_func = function()
                    for __, tid in ipairs(loadTabConfig()) do
                        if tid == _aid then return true end
                    end
                    return false
                end,
                radio    = false,
                callback = function()
                    local tabs       = loadTabConfig()
                    local active_pos = nil
                    for i, tid in ipairs(tabs) do
                        if tid == _aid then active_pos = i; break end
                    end
                    if active_pos then
                        if #tabs <= 2 then
                            UIManager:show(InfoMessage:new{
                                text = _("Minimum 2 tabs required. Select another tab first."), timeout = 2,
                            })
                            return
                        end
                        table.remove(tabs, active_pos)
                    else
                        if #tabs >= 5 then
                            UIManager:show(InfoMessage:new{
                                text = _("Maximum 5 tabs reached. Remove one first."), timeout = 2,
                            })
                            return
                        end
                        tabs[#tabs + 1] = _aid
                    end
                    _ensureHomePresent(tabs)
                    saveTabConfig(tabs)
                    plugin:_scheduleRebuild()
                end,
            }
            ::continue_action::
        end
        table.sort(toggle_items, function(a, b) return a._base:lower() < b._base:lower() end)
        for __, item in ipairs(toggle_items) do items[#items + 1] = item end
        return items
    end

    -- -----------------------------------------------------------------------
    -- Pagination bar menu builder
    -- -----------------------------------------------------------------------

    local function makePaginationBarMenu()
        return {
            {
                text_func    = function()
                    local state = G_reader_settings:nilOrTrue("navbar_pagination_visible") and _("On") or _("Off")
                    return _("Pagination Bar") .. " — " .. state
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_pagination_visible") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_pagination_visible")
                    G_reader_settings:saveSetting("navbar_pagination_visible", not on)
                    local state_text = on and _("hidden") or _("visible")
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Pagination bar will be %s after restart.\n\nRestart now?"), state_text),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
            },
            {
                text           = _("Size"),
                sub_item_table = (function()
                    local sizes = {
                        { label = _("Extra Small"), key = "xs" },
                        { label = _("Small"),       key = "s"  },
                        { label = _("Default"),     key = "m"  },
                    }
                    local items = {}
                    for __, s in ipairs(sizes) do
                        local key = s.key
                        items[#items + 1] = {
                            text         = s.label,
                            checked_func = function()
                                return (G_reader_settings:readSetting("navbar_pagination_size") or "s") == key
                            end,
                            callback     = function()
                                G_reader_settings:saveSetting("navbar_pagination_size", key)
                                UIManager:show(ConfirmBox:new{
                                    text = _("Pagination bar size will change after restart.\n\nRestart now?"),
                                    ok_text = _("Restart"), cancel_text = _("Later"),
                                    ok_callback = function()
                                        G_reader_settings:flush()
                                        local ok_exit, ExitCode = pcall(require, "exitcode")
                                        UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                                    end,
                                })
                            end,
                        }
                    end
                    return items
                end)(),
            },
        }
    end

    -- -----------------------------------------------------------------------
    -- Topbar menu builders
    -- -----------------------------------------------------------------------

    local function makeTopbarItemsMenu()
        local items = {}
        items[#items + 1] = {
            text         = _("Swipe Indicator"),
            checked_func = function() return G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator") end,
            callback = function()
                G_reader_settings:saveSetting("navbar_topbar_swipe_indicator",
                    not G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator"))
                plugin:_scheduleRebuild()
            end,
            separator = true,
        }

        local sorted_keys = {}
        for __, k in ipairs(TOPBAR_ITEMS) do sorted_keys[#sorted_keys + 1] = k end
        table.sort(sorted_keys, function(a, b) return TOPBAR_ITEM_LABEL(a):lower() < TOPBAR_ITEM_LABEL(b):lower() end)

        for __, key in ipairs(sorted_keys) do
            local k = key
            items[#items + 1] = {
                text_func    = function() return TOPBAR_ITEM_LABEL(k) end,
                checked_func = function() return (getTopbarConfig().side[k] or "hidden") ~= "hidden" end,
                callback = function()
                    local cfg = getTopbarConfig()
                    if (cfg.side[k] or "hidden") == "hidden" then
                        local last_side = "right"
                        for __, v in ipairs(cfg.order_left) do if v == k then last_side = "left"; break end end
                        cfg.side[k] = last_side
                        if last_side == "left" then
                            local found = false
                            for __, v in ipairs(cfg.order_left) do if v == k then found = true; break end end
                            if not found then cfg.order_left[#cfg.order_left + 1] = k end
                        else
                            local found = false
                            for __, v in ipairs(cfg.order_right) do if v == k then found = true; break end end
                            if not found then cfg.order_right[#cfg.order_right + 1] = k end
                        end
                    else
                        cfg.side[k] = "hidden"
                    end
                    saveTopbarConfig(cfg)
                    plugin:_scheduleRebuild()
                end,
            }
        end
        items[#items].separator = true

        items[#items + 1] = {
            text           = _("Arrange Items"),
            keep_menu_open = true,
            callback       = function()
                local cfg        = getTopbarConfig()
                local SEP_LEFT   = "__sep_left__"
                local SEP_RIGHT  = "__sep_right__"
                local sort_items = {}
                sort_items[#sort_items + 1] = { text = "── " .. _("Left") .. " ──", orig_item = SEP_LEFT, dim = true }
                for __, key in ipairs(cfg.order_left) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                sort_items[#sort_items + 1] = { text = "── " .. _("Right") .. " ──", orig_item = SEP_RIGHT, dim = true }
                for __, key in ipairs(cfg.order_right) do
                    if cfg.side[key] ~= "hidden" then
                        sort_items[#sort_items + 1] = { text = TOPBAR_ITEM_LABEL(key), orig_item = key }
                    end
                end
                UIManager:show(SortWidget:new{
                    title             = _("Arrange Items"),
                    item_table        = sort_items,
                    covers_fullscreen = true,
                    callback          = function()
                        local sep_left_pos, sep_right_pos
                        for j, item in ipairs(sort_items) do
                            if item.orig_item == SEP_LEFT  then sep_left_pos  = j end
                            if item.orig_item == SEP_RIGHT then sep_right_pos = j end
                        end
                        if not sep_left_pos or not sep_right_pos or sep_left_pos > sep_right_pos
                                or (sort_items[1] and sort_items[1].orig_item ~= SEP_LEFT) then
                            UIManager:show(InfoMessage:new{
                                text    = _("Invalid arrangement.\nKeep items between the Left and Right separators."),
                                timeout = 3,
                            })
                            return
                        end
                        local new_left, new_right = {}, {}
                        local current_side = nil
                        for __, item in ipairs(sort_items) do
                            if     item.orig_item == SEP_LEFT  then current_side = "left"
                            elseif item.orig_item == SEP_RIGHT then current_side = "right"
                            elseif current_side == "left"  then new_left[#new_left + 1] = item.orig_item;  cfg.side[item.orig_item] = "left"
                            elseif current_side == "right" then new_right[#new_right + 1] = item.orig_item; cfg.side[item.orig_item] = "right"
                            end
                        end
                        for __, key in ipairs(cfg.order_left)  do if cfg.side[key] == "hidden" then new_left[#new_left + 1]   = key end end
                        for __, key in ipairs(cfg.order_right) do if cfg.side[key] == "hidden" then new_right[#new_right + 1] = key end end
                        cfg.order_left  = new_left
                        cfg.order_right = new_right
                        saveTopbarConfig(cfg)
                        plugin:_scheduleRebuild()
                    end,
                })
            end,
        }
        return items
    end

    local function makeTopbarMenu()
        return {
            {
                text_func    = function()
                    return _("Top Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_topbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_topbar_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
                    G_reader_settings:saveSetting("navbar_topbar_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Top Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
            },
            { text = _("Items"), sub_item_table = makeTopbarItemsMenu() },
        }
    end

    -- -----------------------------------------------------------------------
    -- Bottom bar menu builder
    -- -----------------------------------------------------------------------

    local function makeNavbarMenu()
        return {
            {
                text_func    = function()
                    return _("Bottom Bar") .. " — " .. (G_reader_settings:nilOrTrue("navbar_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_enabled")
                    G_reader_settings:saveSetting("navbar_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Bottom Bar will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
                separator = true,
            },
            {
                text = _("Type"),
                sub_item_table = {
                    modeItem(_("Icons") .. " + " .. _("Text"), "both"),
                    modeItem(_("Icons only"),                   "icons"),
                    modeItem(_("Text only"),                    "text"),
                },
            },
            {
                text_func = function()
                    local n = #loadTabConfig()
                    local remaining = 5 - n
                    if remaining <= 0 then
                        return string.format(_("Tabs  (%d/%d — at limit)"), n, 5)
                    end
                    return string.format(_("Tabs  (%d/%d — %d left)"), n, 5, remaining)
                end,
                sub_item_table_func = makeTabsMenu,
            },
        }
    end

    plugin._makeNavbarMenu = makeNavbarMenu
    plugin._makeTopbarMenu = makeTopbarMenu

    -- -----------------------------------------------------------------------
    -- Quick Actions
    -- -----------------------------------------------------------------------

    local QA_CUSTOM_ICONS_DIR = "plugins/simpleui.koplugin/icons/custom"

    local function _loadCustomIconList()
        local icons = {}
        local attr  = lfs.attributes(QA_CUSTOM_ICONS_DIR)
        if not attr or attr.mode ~= "directory" then return icons end
        for fname in lfs.dir(QA_CUSTOM_ICONS_DIR) do
            if fname:match("%.[Ss][Vv][Gg]$") or fname:match("%.[Pp][Nn][Gg]$") then
                local path  = QA_CUSTOM_ICONS_DIR .. "/" .. fname
                local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
                icons[#icons + 1] = { path = path, label = label }
            end
        end
        table.sort(icons, function(a, b) return a.label:lower() < b.label:lower() end)
        return icons
    end

    local function showIconPicker(current_icon, on_select, default_label)
        local ButtonDialog = require("ui/widget/buttondialog")
        local icons   = _loadCustomIconList()
        local buttons = {}
        local default_marker = (not current_icon) and "  ✓" or ""
        buttons[#buttons + 1] = {{
            text     = (default_label or _("Default (Folder)")) .. default_marker,
            callback = function() UIManager:close(plugin._qa_icon_picker); on_select(nil) end,
        }}
        if #icons == 0 then
            buttons[#buttons + 1] = {{ text = _("No icons found in:") .. "\n" .. QA_CUSTOM_ICONS_DIR, enabled = false }}
        else
            for __, icon in ipairs(icons) do
                local p = icon
                buttons[#buttons + 1] = {{
                    text     = p.label .. ((current_icon == p.path) and "  ✓" or ""),
                    callback = function() UIManager:close(plugin._qa_icon_picker); on_select(p.path) end,
                }}
            end
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._qa_icon_picker) end }}
        plugin._qa_icon_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_icon_picker)
    end

    local function _scanFMPlugins()
        local fm = plugin.ui
        if not fm then
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            fm = ok_fm and FM and FM.instance
        end
        if not fm then return {} end
        local known = {
            { key = "history",     method = "onShowHist",          title = _("History") },
            { key = "bookinfo",    method = "onShowBookInfo",       title = _("Book Info") },
            { key = "collections", method = "onShowColl",           title = _("Favorites") },
            { key = "collections", method = "onShowCollList",       title = _("Collections") },
            { key = "filesearcher",method = "onShowFileSearch",     title = _("File Search") },
            { key = "folder_shortcuts", method = "onShowFolderShortcutsDialog", title = _("Folder Shortcuts") },
            { key = "dictionary",  method = "onShowDictionaryLookup", title = _("Dictionary Lookup") },
            { key = "wikipedia",   method = "onShowWikipediaLookup", title = _("Wikipedia Lookup") },
        }
        local results = {}
        for __, entry in ipairs(known) do
            local mod = fm[entry.key]
            if mod and type(mod[entry.method]) == "function" then
                results[#results + 1] = { fm_key = entry.key, fm_method = entry.method, title = entry.title }
            end
        end
        local native_keys = { screenshot=true, menu=true, history=true, bookinfo=true, collections=true,
            filesearcher=true, folder_shortcuts=true, languagesupport=true, dictionary=true, wikipedia=true,
            devicestatus=true, devicelistener=true, networklistener=true }
        local our_name  = plugin.name or "simpleui"
        local seen_keys = {}
        for i = 1, #fm do
            local val = fm[i]
            if type(val) ~= "table" or type(val.name) ~= "string" then goto cont end
            local fm_key = nil
            for k, v in pairs(fm) do if type(k) == "string" and v == val then fm_key = k; break end end
            if not fm_key or native_keys[fm_key] or seen_keys[fm_key] or fm_key == our_name then goto cont end
            if type(val.addToMainMenu) ~= "function" then goto cont end
            seen_keys[fm_key] = true
            local method = nil
            for __, pfx in ipairs({"onShow","show","open","launch","onOpen"}) do
                if type(val[pfx]) == "function" then method = pfx; break end
            end
            if not method then
                local cap = "on" .. fm_key:sub(1,1):upper() .. fm_key:sub(2)
                if type(val[cap]) == "function" then method = cap end
            end
            if method then
                local raw     = (val.name or fm_key):gsub("^filemanager", "")
                local display = raw:sub(1,1):upper() .. raw:sub(2)
                results[#results + 1] = { fm_key = fm_key, fm_method = method, title = display }
            end
            ::cont::
        end
        table.sort(results, function(a, b) return a.title < b.title end)
        return results
    end

    local function _scanDispatcherActions()
        local ok_d, Dispatcher = pcall(require, "dispatcher")
        if not ok_d or not Dispatcher then return {} end
        pcall(function() Dispatcher:init() end)
        local settingsList, dispatcher_menu_order
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList"          then settingsList          = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
        if type(settingsList) ~= "table" then return {} end
        local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
            or (function() local t = {}; for k in pairs(settingsList) do t[#t+1] = k end; table.sort(t); return t end)()
        local results = {}
        for __, action_id in ipairs(order) do
            local def = settingsList[action_id]
            if type(def) == "table" and def.title and def.category == "none"
                    and (def.condition == nil or def.condition == true) then
                results[#results + 1] = { id = action_id, title = tostring(def.title) }
            end
        end
        table.sort(results, function(a, b) return a.title < b.title end)
        return results
    end

    -- Full edit dialog for a Quick Action (path / collection / plugin / dispatcher).
    local function showQuickActionDialog(qa_id, on_done)
        local collections       = _getNonFavoritesCollections()
        table.sort(collections, function(a, b) return a:lower() < b:lower() end)
        local cfg               = qa_id and getCustomQAConfig(qa_id) or {}
        local start_path        = cfg.path or G_reader_settings:readSetting("home_dir") or "/"
        local chosen_icon       = cfg.icon
        local chosen_icon_ref   = { chosen_icon }

        local function iconButtonLabel()
            if not chosen_icon then return _("Icon: Default") end
            local fname = chosen_icon:match("([^/]+)$") or chosen_icon
            local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
            return _("Icon") .. ": " .. label
        end

        -- Plugin picker.
        local function openPluginPicker()
            local ButtonDialog   = require("ui/widget/buttondialog")
            local plugin_actions = _scanFMPlugins()
            if #plugin_actions == 0 then
                UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 })
                return
            end

            local function finishPluginQA(fm_key, fm_method, suggested_label)
                local dialog
                local function openIconPicker2()
                    UIManager:close(dialog)
                    showIconPicker(chosen_icon, function(new_icon)
                        chosen_icon = new_icon; chosen_icon_ref[1] = new_icon
                        dialog = MultiInputDialog:new{
                            title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                            fields = {{ description = _("Name"), text = cfg.label or suggested_label, hint = _("e.g. Rakuyomi…") }},
                            buttons = {{ { text = iconButtonLabel(), callback = function() openIconPicker2() end } },
                                       { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                         { text = _("Save"), is_enter_default = true, callback = function()
                                               local clean_label = _sanitizeLabel(dialog:getFields()[1]) or suggested_label
                                               UIManager:close(dialog)
                                               local final_id = qa_id or nextCustomQAId()
                                               if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                               saveCustomQAConfig(final_id, clean_label, nil, nil, chosen_icon or CUSTOM_PLUGIN_ICON, fm_key, fm_method)
                                               plugin:_rebuildAllNavbars()
                                               if on_done then on_done() end
                                           end } }},
                        }
                        UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                    end, _("Default (Plugin)"))
                end
                dialog = MultiInputDialog:new{
                    title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                    fields = {{ description = _("Name"), text = cfg.label or suggested_label, hint = _("e.g. Rakuyomi…") }},
                    buttons = {{ { text = iconButtonLabel(), callback = function() openIconPicker2() end } },
                               { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                 { text = _("Save"), is_enter_default = true, callback = function()
                                       local clean_label = _sanitizeLabel(dialog:getFields()[1]) or suggested_label
                                       UIManager:close(dialog)
                                       local final_id = qa_id or nextCustomQAId()
                                       if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                       saveCustomQAConfig(final_id, clean_label, nil, nil, chosen_icon or CUSTOM_PLUGIN_ICON, fm_key, fm_method)
                                       plugin:_rebuildAllNavbars()
                                       if on_done then on_done() end
                                   end } }},
                }
                UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
            end

            local buttons = {}
            table.sort(plugin_actions, function(a, b) return a.title:lower() < b.title:lower() end)
            for __, a in ipairs(plugin_actions) do
                local _a = a
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_plugin_picker); finishPluginQA(_a.fm_key, _a.fm_method, _a.title)
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._qa_plugin_picker) end }}
            plugin._qa_plugin_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_plugin_picker)
        end

        -- Dispatcher picker.
        local function openDispatcherPicker()
            local ButtonDialog = require("ui/widget/buttondialog")
            local actions = _scanDispatcherActions()
            if #actions == 0 then
                UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
                return
            end

            local function finishDispatcherQA(action_id, suggested_label)
                local dialog
                local function openIconPicker3()
                    UIManager:close(dialog)
                    showIconPicker(chosen_icon, function(new_icon)
                        chosen_icon = new_icon; chosen_icon_ref[1] = new_icon
                        dialog = MultiInputDialog:new{
                            title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                            fields = {{ description = _("Name"), text = cfg.label or suggested_label, hint = _("e.g. Sleep…") }},
                            buttons = {{ { text = (not chosen_icon and _("Icon: Default (System)") or _("Icon") .. ": " .. ((chosen_icon:match("([^/]+)$") or ""):match("^(.+)%.[^%.]+$") or "")), callback = function() openIconPicker3() end } },
                                       { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                         { text = _("Save"), is_enter_default = true, callback = function()
                                               local clean_label = _sanitizeLabel(dialog:getFields()[1]) or suggested_label
                                               UIManager:close(dialog)
                                               local final_id = qa_id or nextCustomQAId()
                                               if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                               saveCustomQAConfig(final_id, clean_label, nil, nil, chosen_icon or CUSTOM_DISPATCHER_ICON, nil, nil, action_id)
                                               plugin:_rebuildAllNavbars()
                                               if on_done then on_done() end
                                           end } }},
                        }
                        UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                    end, _("Default (System)"))
                end
                dialog = MultiInputDialog:new{
                    title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                    fields = {{ description = _("Name"), text = cfg.label or suggested_label, hint = _("e.g. Sleep, Refresh…") }},
                    buttons = {{ { text = (not chosen_icon and _("Icon: Default (System)") or _("Icon") .. ": ..."), callback = function() openIconPicker3() end } },
                               { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                 { text = _("Save"), is_enter_default = true, callback = function()
                                       local clean_label = _sanitizeLabel(dialog:getFields()[1]) or suggested_label
                                       UIManager:close(dialog)
                                       local final_id = qa_id or nextCustomQAId()
                                       if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                       saveCustomQAConfig(final_id, clean_label, nil, nil, chosen_icon or CUSTOM_DISPATCHER_ICON, nil, nil, action_id)
                                       plugin:_rebuildAllNavbars()
                                       if on_done then on_done() end
                                   end } }},
                }
                UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
            end

            local buttons = {}
            table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
            for __, a in ipairs(actions) do
                local _a = a
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_dispatcher_picker); finishDispatcherQA(_a.id, _a.title)
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._qa_dispatcher_picker) end }}
            plugin._qa_dispatcher_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_dispatcher_picker)
        end

        -- Path chooser.
        local function openPathChooser()
            UIManager:show(PathChooser:new{
                select_directory = true, select_file = false, show_files = false,
                path             = start_path, covers_fullscreen = true,
                height           = Screen:getHeight() - TOTAL_H(),
                onConfirm = function(chosen_path)
                    local dialog
                    local function openIconPickerPath()
                        UIManager:close(dialog)
                        showIconPicker(chosen_icon, function(new_icon)
                            chosen_icon = new_icon
                            dialog = MultiInputDialog:new{
                                title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                                fields = {
                                    { description = _("Name"), text = cfg.label or (chosen_path:match("([^/]+)$") or ""), hint = _("e.g. Books…") },
                                    { description = _("Folder"), text = chosen_path, hint = "/path/to/folder" },
                                },
                                buttons = {{ { text = iconButtonLabel(), callback = function() openIconPickerPath() end } },
                                           { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                             { text = _("Save"), is_enter_default = true, callback = function()
                                                   local inputs    = dialog:getFields()
                                                   local new_path  = inputs[2] ~= "" and inputs[2] or chosen_path
                                                   local attr      = lfs.attributes(new_path)
                                                   if not attr then UIManager:show(InfoMessage:new{ text = string.format(_("Folder not found:\n%s"), new_path), timeout = 3 }); return end
                                                   if attr.mode ~= "directory" then UIManager:show(InfoMessage:new{ text = string.format(_("Path is not a folder:\n%s"), new_path), timeout = 3 }); return end
                                                   local clean_label = _sanitizeLabel(inputs[1]) or (new_path:match("([^/]+)$") or "?")
                                                   UIManager:close(dialog)
                                                   local final_id = qa_id or nextCustomQAId()
                                                   if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                                   saveCustomQAConfig(final_id, clean_label, new_path, nil, chosen_icon)
                                                   plugin:_rebuildAllNavbars()
                                                   if on_done then on_done() end
                                               end } }},
                            }
                            UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                        end)
                    end
                    dialog = MultiInputDialog:new{
                        title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                        fields = {
                            { description = _("Name"), text = cfg.label or (chosen_path:match("([^/]+)$") or ""), hint = _("e.g. Books…") },
                            { description = _("Folder"), text = chosen_path, hint = "/path/to/folder" },
                        },
                        buttons = {{ { text = iconButtonLabel(), callback = function() openIconPickerPath() end } },
                                   { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                     { text = _("Save"), is_enter_default = true, callback = function()
                                           local inputs    = dialog:getFields()
                                           local new_path  = inputs[2] ~= "" and inputs[2] or chosen_path
                                           local attr      = lfs.attributes(new_path)
                                           if not attr then UIManager:show(InfoMessage:new{ text = string.format(_("Folder not found:\n%s"), new_path), timeout = 3 }); return end
                                           if attr.mode ~= "directory" then UIManager:show(InfoMessage:new{ text = string.format(_("Path is not a folder:\n%s"), new_path), timeout = 3 }); return end
                                           local clean_label = _sanitizeLabel(inputs[1]) or (new_path:match("([^/]+)$") or "?")
                                           UIManager:close(dialog)
                                           local final_id = qa_id or nextCustomQAId()
                                           if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                           saveCustomQAConfig(final_id, clean_label, new_path, nil, chosen_icon)
                                           plugin:_rebuildAllNavbars()
                                           if on_done then on_done() end
                                       end } }},
                    }
                    UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                end,
            })
        end

        -- Collection picker.
        local function openCollectionPicker()
            local ButtonDialog = require("ui/widget/buttondialog")
            local buttons = {}
            for __, coll_name in ipairs(collections) do
                local name = coll_name
                buttons[#buttons + 1] = {{ text = name, callback = function()
                    UIManager:close(plugin._qa_coll_picker)
                    local dialog
                    local function openIconPickerColl()
                        UIManager:close(dialog)
                        showIconPicker(chosen_icon, function(new_icon)
                            chosen_icon = new_icon
                            dialog = MultiInputDialog:new{
                                title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                                fields = {{ description = _("Name"), text = cfg.label or name, hint = _("e.g. Sci-Fi…") }},
                                buttons = {{ { text = iconButtonLabel(), callback = function() openIconPickerColl() end } },
                                           { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                             { text = _("Save"), is_enter_default = true, callback = function()
                                                   local clean_label = _sanitizeLabel(dialog:getFields()[1]) or name
                                                   UIManager:close(dialog)
                                                   local final_id = qa_id or nextCustomQAId()
                                                   if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                                   saveCustomQAConfig(final_id, clean_label, nil, name, chosen_icon)
                                                   plugin:_rebuildAllNavbars()
                                                   if on_done then on_done() end
                                               end } }},
                            }
                            UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                        end)
                    end
                    dialog = MultiInputDialog:new{
                        title  = qa_id and _("Edit Quick Action") or _("New Quick Action"),
                        fields = {{ description = _("Name"), text = cfg.label or name, hint = _("e.g. Sci-Fi…") }},
                        buttons = {{ { text = iconButtonLabel(), callback = function() openIconPickerColl() end } },
                                   { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                     { text = _("Save"), is_enter_default = true, callback = function()
                                           local clean_label = _sanitizeLabel(dialog:getFields()[1]) or name
                                           UIManager:close(dialog)
                                           local final_id = qa_id or nextCustomQAId()
                                           if not qa_id then local list = getCustomQAList(); list[#list+1] = final_id; saveCustomQAList(list) end
                                           saveCustomQAConfig(final_id, clean_label, nil, name, chosen_icon)
                                           plugin:_rebuildAllNavbars()
                                           if on_done then on_done() end
                                       end } }},
                    }
                    UIManager:show(dialog); pcall(function() dialog:onShowKeyboard() end)
                end }}
            end
            buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._qa_coll_picker) end }}
            plugin._qa_coll_picker = ButtonDialog:new{ buttons = buttons }
            UIManager:show(plugin._qa_coll_picker)
        end

        local ButtonDialog = require("ui/widget/buttondialog")
        local choice_dialog
        choice_dialog = ButtonDialog:new{ buttons = {
            {{ text = _("Collection"),     callback = function() UIManager:close(choice_dialog); openCollectionPicker()  end, enabled = #collections > 0 }},
            {{ text = _("Folder"),         callback = function() UIManager:close(choice_dialog); openPathChooser()       end }},
            {{ text = _("Plugin"),         callback = function() UIManager:close(choice_dialog); openPluginPicker()      end }},
            {{ text = _("System Actions"), callback = function() UIManager:close(choice_dialog); openDispatcherPicker()  end }},
            {{ text = _("Cancel"),         callback = function() UIManager:close(choice_dialog) end }},
        }}
        UIManager:show(choice_dialog)
    end

    local function makeQuickActionsMenu()
        local items   = {}
        local qa_list = getCustomQAList()
        items[#items + 1] = {
            text         = _("Create Quick Action"),
            enabled_func = function() return #getCustomQAList() < MAX_CUSTOM_QA end,
            callback     = function()
                if #getCustomQAList() >= MAX_CUSTOM_QA then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Maximum %d quick actions reached. Delete one first."), MAX_CUSTOM_QA), timeout = 2 })
                    return
                end
                showQuickActionDialog(nil, nil)
            end,
        }
        if #qa_list == 0 then return items end
        items[#items].separator = true
        -- Sort entries alphabetically by label.
        local sorted_qa = {}
        for __, qa_id in ipairs(qa_list) do sorted_qa[#sorted_qa+1] = qa_id end
        table.sort(sorted_qa, function(a, b)
            local ca = getCustomQAConfig(a); local cb = getCustomQAConfig(b)
            return (ca.label or a):lower() < (cb.label or b):lower()
        end)
        for __, qa_id in ipairs(sorted_qa) do
            local _id = qa_id
            items[#items + 1] = {
                text_func = function()
                    local c = getCustomQAConfig(_id)
                    local desc
                    if c.dispatcher_action and c.dispatcher_action ~= "" then desc = "⊕ " .. c.dispatcher_action
                    elseif c.plugin_key and c.plugin_key ~= "" then desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                    elseif c.collection and c.collection ~= "" then desc = "⊞ " .. c.collection
                    else desc = c.path or _("not configured"); if #desc > 34 then desc = "…" .. desc:sub(-31) end end
                    return c.label .. "  |  " .. desc
                end,
                sub_item_table_func = function()
                    local sub = {}
                    sub[#sub + 1] = {
                        text_func = function()
                            local c = getCustomQAConfig(_id)
                            local desc
                            if c.plugin_key and c.plugin_key ~= "" then desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
                            elseif c.collection and c.collection ~= "" then desc = "⊞ " .. c.collection
                            else desc = c.path or _("not configured"); if #desc > 38 then desc = "…" .. desc:sub(-35) end end
                            return c.label .. "  |  " .. desc
                        end,
                        enabled = false,
                    }
                    sub[#sub + 1] = { text = _("Edit"),   callback = function() showQuickActionDialog(_id, nil) end }
                    sub[#sub + 1] = { text = _("Delete"), callback = function()
                        local c = getCustomQAConfig(_id)
                        UIManager:show(ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"), cancel_text = _("Cancel"),
                            ok_callback = function()
                                deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                plugin:_rebuildAllNavbars()
                            end,
                        })
                    end }
                    return sub
                end,
            }
        end
        return items
    end

    plugin._makeQuickActionsMenu = makeQuickActionsMenu

    -- -----------------------------------------------------------------------
    -- Desktop menu
    -- -----------------------------------------------------------------------

    local function getDesktopHeaderMode()
        return G_reader_settings:readSetting("navbar_desktop_header") or "clock"
    end

    local function refreshDesktop() plugin:_rebuildDesktop() end

    self._goalTapCallback = function()
        local goal     = G_reader_settings:readSetting("navbar_reading_goal") or 0
        local physical = G_reader_settings:readSetting("navbar_reading_goal_physical") or 0
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{ title = _("Annual Reading Goal"), buttons = {
            {{ text = goal > 0 and string.format(_("Digital: %d books in %s"), goal, os.date("%Y")) or string.format(_("Digital Goal  (%s)"), os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshDesktop() end) end
               end }},
            {{ text = string.format(_("Physical: %d books in %s"), physical, os.date("%Y")),
               callback = function()
                   UIManager:close(dlg)
                   local ok_rg, RG = pcall(require, "readinggoals")
                   if ok_rg and RG then RG.showAnnualPhysicalDialog(function() refreshDesktop() end) end
               end }},
        }}
        UIManager:show(dlg)
    end

    local DESKTOP_MODULE_DEFAULT_ORDER = { "header","currently","recent","collections","reading_goals","reading_stats","quick_actions_1","quick_actions_2","quick_actions_3" }
    local DESKTOP_MODULE_LABELS = {
        header="Header",
        currently="Currently Reading", recent="Recent Books",
        collections="Collections",
        reading_goals="Reading Goals",
        reading_stats="Reading Stats",
        quick_actions_1="Quick Actions 1", quick_actions_2="Quick Actions 2", quick_actions_3="Quick Actions 3",
    }

    local function loadDesktopModuleOrder()
        local saved = G_reader_settings:readSetting("navbar_desktop_module_order")
        if type(saved) == "table" and #saved > 0 then
            local seen = {}; for __, v in ipairs(saved) do seen[v] = true end
            local result = {}; for __, v in ipairs(saved) do result[#result+1] = v end
            for __, v in ipairs(DESKTOP_MODULE_DEFAULT_ORDER) do if not seen[v] then result[#result+1] = v end end
            return result
        end
        return { table.unpack(DESKTOP_MODULE_DEFAULT_ORDER) }
    end
    local function saveDesktopModuleOrder(order) G_reader_settings:saveSetting("navbar_desktop_module_order", order) end

    local MAX_MODULES  = 3
    local MAX_QA_ITEMS = 4

    local function countActiveModules()
        local n = 0
        if getDesktopHeaderMode() ~= "nothing" then n = n + 1 end
        for __, k in ipairs({"navbar_desktop_currently","navbar_desktop_recent","navbar_desktop_collections","navbar_desktop_reading_goals"}) do
            if G_reader_settings:nilOrTrue(k) then n = n + 1 end
        end
        for i = 1, 3 do
            if G_reader_settings:readSetting("navbar_desktop_quick_actions_"..i.."_enabled") then n = n + 1 end
        end
        if G_reader_settings:readSetting("navbar_desktop_reading_stats_enabled") == true then n = n + 1 end
        return n
    end

    local function getQAPool()
        local available = {}
        for __, a in ipairs(ALL_ACTIONS) do
            if a.id ~= "power" and a.id ~= "desktop" then
                available[#available+1] = { id = a.id, label = a.id == "home" and Config.homeLabel() or a.label }
            end
        end
        local ok_d2, has_fl = pcall(function() return Device:hasFrontlight() end)
        if ok_d2 and has_fl then available[#available+1] = { id = "frontlight", label = _("Brightness") } end
        for __, qa_id in ipairs(getCustomQAList()) do
            local _qid = qa_id
            available[#available+1] = { id = _qid, label = getCustomQAConfig(_qid).label }
        end
        return available
    end

    local function makeQAModuleMenu(slot_n)
        local items_key  = "navbar_desktop_quick_actions_" .. slot_n .. "_items"
        local labels_key = "navbar_desktop_quick_actions_" .. slot_n .. "_labels"
        local slot_label = string.format(_("Quick Actions %d"), slot_n)
        local function getItems() return G_reader_settings:readSetting(items_key) or {} end
        local function isSelected(id) for __, v in ipairs(getItems()) do if v == id then return true end end return false end
        local function toggleItem(id)
            local items = getItems(); local new_items = {}; local found = false
            for __, v in ipairs(items) do if v == id then found = true else new_items[#new_items+1] = v end end
            if not found then
                if #items >= MAX_QA_ITEMS then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Maximum %d actions per module reached. Remove one first."), MAX_QA_ITEMS), timeout = 2 })
                    return
                end
                new_items[#new_items+1] = id
            end
            G_reader_settings:saveSetting(items_key, new_items); refreshDesktop()
        end
        local sub = {
            { text = _("Show Labels"),
              checked_func = function() return G_reader_settings:nilOrTrue(labels_key) end,
              keep_menu_open = true, callback = function()
                  G_reader_settings:saveSetting(labels_key, not G_reader_settings:nilOrTrue(labels_key)); refreshDesktop()
              end },
            { text = _("Arrange"), keep_menu_open = true, separator = true, callback = function()
                  local qa_ids = getItems()
                  if #qa_ids < 2 then UIManager:show(InfoMessage:new{ text = _("Add at least 2 actions to arrange."), timeout = 2 }); return end
                  local pool_labels = {}; for __, a in ipairs(getQAPool()) do pool_labels[a.id] = a.label end
                  local sort_items = {}
                  for __, id in ipairs(qa_ids) do sort_items[#sort_items+1] = { text = pool_labels[id] or id, orig_item = id } end
                  UIManager:show(SortWidget:new{ title = string.format(_("Arrange %s"), slot_label), covers_fullscreen = true, item_table = sort_items,
                      callback = function()
                          local new_order = {}; for __, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                          G_reader_settings:saveSetting(items_key, new_order); refreshDesktop()
                      end })
              end },
        }
        local sorted_pool = {}
        for __, a in ipairs(getQAPool()) do sorted_pool[#sorted_pool+1] = a end
        table.sort(sorted_pool, function(a, b) return a.label:lower() < b.label:lower() end)
        for __, a in ipairs(sorted_pool) do
            local aid = a.id
            local _lbl = a.label
            sub[#sub+1] = {
                text_func = function()
                    if isSelected(aid) then return _lbl end
                    local rem = MAX_QA_ITEMS - #getItems()
                    if rem <= 0 then return _lbl .. "  (0 left)" end
                    if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                    return _lbl
                end,
                checked_func = function() return isSelected(aid) end,
                keep_menu_open = true, callback = function() toggleItem(aid) end,
            }
        end
        return sub
    end

    -- Reading Stats module menu (mirrors makeQAModuleMenu; max cards = RS_N_COLS).
    local function makeRSModuleMenu()
        local items_key = "navbar_desktop_reading_stats_items"
        local ok_rg2, RG2 = pcall(require, "readinggoals")
        local RS2  = ok_rg2 and RG2 and RG2.Stats
        local MAX_RS = RS2 and RS2.getMaxItems() or 3
        local function getItems() return G_reader_settings:readSetting(items_key) or {} end
        local function isSelected(id)
            for __, v in ipairs(getItems()) do if v == id then return true end end
            return false
        end
        local function toggleItem(id)
            local items = getItems(); local new_items = {}; local found = false
            for __, v in ipairs(items) do
                if v == id then found = true else new_items[#new_items+1] = v end
            end
            if not found then
                if #items >= MAX_RS then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Maximum %d stats per row. Remove one first."), MAX_RS),
                        timeout = 2 })
                    return
                end
                new_items[#new_items+1] = id
            end
            G_reader_settings:saveSetting(items_key, new_items); refreshDesktop()
        end
        local sub = {
            { text = _("Arrange"), keep_menu_open = true, separator = true, callback = function()
                  local rs_ids = getItems()
                  if #rs_ids < 2 then
                      UIManager:show(InfoMessage:new{ text = _("Add at least 2 stats to arrange."), timeout = 2 })
                      return
                  end
                  local ok_rg, RG = pcall(require, "readinggoals")
                  local RS = ok_rg and RG and RG.Stats
                  local sort_items = {}
                  for __, id in ipairs(rs_ids) do
                      local lbl = RS and RS.getStatLabel(id) or id
                      sort_items[#sort_items+1] = { text = lbl, orig_item = id }
                  end
                  UIManager:show(SortWidget:new{
                      title = _("Arrange Reading Stats"),
                      covers_fullscreen = true,
                      item_table = sort_items,
                      callback = function()
                          local new_order = {}
                          for __, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                          G_reader_settings:saveSetting(items_key, new_order); refreshDesktop()
                      end })
              end },
        }
        local ok_rg, RG = pcall(require, "readinggoals")
        local RS   = ok_rg and RG and RG.Stats
        local pool = RS and RS.STAT_POOL or { "today_time","today_pages","avg_time","avg_pages","total_time","total_books","streak" }
        local sorted_rs = {}
        for __, sid in ipairs(pool) do
            sorted_rs[#sorted_rs+1] = { id = sid, label = (RS and RS.getStatLabel(sid)) or sid }
        end
        table.sort(sorted_rs, function(a, b) return a.label:lower() < b.label:lower() end)
        for __, entry in ipairs(sorted_rs) do
            local _sid = entry.id
            local _lbl = entry.label
            sub[#sub+1] = {
                text_func = function()
                    if isSelected(_sid) then return _lbl end
                    local rem = MAX_RS - #getItems()
                    if rem <= 0 then return _lbl .. "  (0 left)" end
                    if rem <= 2 then return _lbl .. "  (" .. rem .. " left)" end
                    return _lbl
                end,
                checked_func = function() return isSelected(_sid) end,
                keep_menu_open = true,
                callback = function() toggleItem(_sid) end,
            }
        end
        return sub
    end

    local function makeDesktopHeaderMenu()
        local PRESETS = {
            { key = "clock",      label = _("Clock") },
            { key = "clock_date", label = _("Clock") .. " + " .. _("Date") },
            { key = "quote",      label = _("Quote of the Day") },
        }
        local items = {}
        for __, p in ipairs(PRESETS) do
            local key = p.key; local label = p.label
            items[#items+1] = { text = label, radio = true,
                checked_func = function() return getDesktopHeaderMode() == key end,
                callback = function() G_reader_settings:saveSetting("navbar_desktop_header", key); refreshDesktop() end }
        end
        local function openCustomHeaderDialog()
            local InputDialog = require("ui/widget/inputdialog"); local dlg
            dlg = InputDialog:new{ title = _("Desktop Header Text"),
                input = G_reader_settings:readSetting("navbar_desktop_header_custom") or "",
                input_hint = _("e.g. My Library"),
                buttons = {{ { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                             { text = _("OK"), is_enter_default = true, callback = function()
                                   local clean = dlg:getInputText():match("^%s*(.-)%s*$")
                                   UIManager:close(dlg)
                                   if clean == "" then return end
                                   if #clean > MAX_LABEL_LEN then clean = clean:sub(1, MAX_LABEL_LEN) end
                                   G_reader_settings:saveSetting("navbar_desktop_header_custom", clean)
                                   G_reader_settings:saveSetting("navbar_desktop_header", "custom")
                                   refreshDesktop()
                               end } }},
            }
            UIManager:show(dlg); pcall(function() dlg:onShowKeyboard() end)
        end
        items[#items+1] = {
            text_func = function()
                local c = G_reader_settings:readSetting("navbar_desktop_header_custom") or ""
                return c ~= "" and (_("Custom") .. "  (" .. c .. ")") or _("Custom")
            end,
            radio = true, checked_func = function() return getDesktopHeaderMode() == "custom" end,
            keep_menu_open = true,
            callback = function()
                local c = G_reader_settings:readSetting("navbar_desktop_header_custom") or ""
                if c == "" then openCustomHeaderDialog()
                else G_reader_settings:saveSetting("navbar_desktop_header", "custom"); refreshDesktop() end
            end,
            hold_callback = function() openCustomHeaderDialog() end,
        }
        return items
    end

    local function makeDesktopMenu()
        return {
            {
                text         = _("Desktop"),
                checked_func = function() return G_reader_settings:nilOrTrue("navbar_desktop_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("navbar_desktop_enabled")
                    G_reader_settings:saveSetting("navbar_desktop_enabled", not on)
                    Config.invalidateTabsCache()
                    if not on then
                        local tabs = loadTabConfig()
                        if Config.tabInTabs("desktop", tabs) then
                            local fm = self.ui
                            if fm and fm.file_chooser then
                                local ok_d, Desktop = pcall(require, "desktop")
                                if ok_d and Desktop and type(Desktop.onShowDesktop) == "function" and not Desktop._desktop_widget then
                                    Desktop:onShowDesktop(fm, function()
                                        local t = loadTabConfig(); setActiveAndRefreshFM(self, "desktop", t)
                                    end)
                                end
                            end
                        end
                    else
                        local ok_d, Desktop = pcall(require, "desktop")
                        if ok_d and Desktop and type(Desktop.hide) == "function" then Desktop:hide() end
                        if G_reader_settings:readSetting("start_with") == "desktop_simpleui" then
                            G_reader_settings:saveSetting("start_with", "filemanager")
                        end
                    end
                    self:_rebuildAllNavbars()
                end,
            },
            {
                text         = _("Start with Desktop"),
                checked_func = function() return G_reader_settings:readSetting("start_with", "filemanager") == "desktop_simpleui" end,
                enabled_func = function() return G_reader_settings:nilOrTrue("navbar_desktop_enabled") end,
                callback     = function()
                    local on = G_reader_settings:readSetting("start_with", "filemanager") == "desktop_simpleui"
                    G_reader_settings:saveSetting("start_with", on and "filemanager" or "desktop_simpleui")
                end,
            },
            {
                text_func           = function()
                    local n = countActiveModules()
                    local rem = MAX_MODULES - n
                    if rem <= 0 then
                        return string.format(_("Modules  (%d/%d — at limit)"), n, MAX_MODULES)
                    end
                    return string.format(_("Modules  (%d/%d — %d left)"), n, MAX_MODULES, rem)
                end,
                sub_item_table_func = function()
                    local function maxModulesMsg()
                        UIManager:show(InfoMessage:new{
                            text    = string.format(_("Maximum %d modules active. Disable one first."), MAX_MODULES),
                            timeout = 2,
                        })
                    end
                    local function moduleToggle(enabled_key, label)
                        return {
                            text_func = function()
                                if G_reader_settings:nilOrTrue(enabled_key) then return label end
                                local remaining = MAX_MODULES - countActiveModules()
                                if remaining <= 0 then return label .. "  (0 left)" end
                                if remaining <= 2 then return label .. "  (" .. remaining .. " left)" end
                                return label
                            end,
                            checked_func = function() return G_reader_settings:nilOrTrue(enabled_key) end,
                            keep_menu_open = true, callback = function()
                                local on = G_reader_settings:nilOrTrue(enabled_key)
                                if not on and countActiveModules() >= MAX_MODULES then maxModulesMsg(); return end
                                G_reader_settings:saveSetting(enabled_key, not on); refreshDesktop()
                            end,
                        }
                    end
                    local function qaToggle(slot)
                        local key = "navbar_desktop_quick_actions_" .. slot .. "_enabled"
                        local base_label = string.format(_("Quick Actions %d"), slot)
                        return {
                            text_func = function()
                                if G_reader_settings:readSetting(key) == true then return base_label end
                                local remaining = MAX_MODULES - countActiveModules()
                                if remaining <= 0 then return base_label .. "  (0 left)" end
                                if remaining <= 2 then return base_label .. "  (" .. remaining .. " left)" end
                                return base_label
                            end,
                            checked_func = function() return G_reader_settings:readSetting(key) == true end,
                            keep_menu_open = true, separator = (slot == 3),
                            callback = function()
                                local on = G_reader_settings:readSetting(key) == true
                                if not on and countActiveModules() >= MAX_MODULES then maxModulesMsg(); return end
                                G_reader_settings:saveSetting(key, not on); refreshDesktop()
                            end,
                        }
                    end
                    local function rsToggle()
                        local key        = "navbar_desktop_reading_stats_enabled"
                        local base_label = _("Reading Stats")
                        return {
                            text_func = function()
                                if G_reader_settings:readSetting(key) == true then return base_label end
                                local remaining = MAX_MODULES - countActiveModules()
                                if remaining <= 0 then return base_label .. "  (0 left)" end
                                if remaining <= 2 then return base_label .. "  (" .. remaining .. " left)" end
                                return base_label
                            end,
                            checked_func = function() return G_reader_settings:readSetting(key) == true end,
                            keep_menu_open = true,
                            callback = function()
                                local on = G_reader_settings:readSetting(key) == true
                                if not on and countActiveModules() >= MAX_MODULES then maxModulesMsg(); return end
                                G_reader_settings:saveSetting(key, not on); refreshDesktop()
                            end,
                        }
                    end
                    return {
                        {
                            text = _("Arrange Modules"), keep_menu_open = true, callback = function()
                                local function loadDesktopModuleOrderLocal()
                                    local saved = G_reader_settings:readSetting("navbar_desktop_module_order")
                                    if type(saved) == "table" and #saved > 0 then
                                        local seen = {}; for __, v in ipairs(saved) do seen[v] = true end
                                        local result = {}; for __, v in ipairs(saved) do result[#result+1] = v end
                                        for __, v in ipairs(DESKTOP_MODULE_DEFAULT_ORDER) do if not seen[v] then result[#result+1] = v end end
                                        return result
                                    end
                                    return { table.unpack(DESKTOP_MODULE_DEFAULT_ORDER) }
                                end
                                local order = loadDesktopModuleOrderLocal()
                                local sort_items = {}
                                for __, key in ipairs(order) do
                                    -- include only active modules
                                    local active = false
                                    if key == "header" then
                                        active = getDesktopHeaderMode() ~= "nothing"
                                    elseif key == "currently" then
                                        active = G_reader_settings:nilOrTrue("navbar_desktop_currently")
                                    elseif key == "recent" then
                                        active = G_reader_settings:nilOrTrue("navbar_desktop_recent")
                                    elseif key == "collections" then
                                        active = G_reader_settings:nilOrTrue("navbar_desktop_collections")
                                    elseif key == "reading_goals" then
                                        active = G_reader_settings:nilOrTrue("navbar_desktop_reading_goals")
                                    elseif key:match("^quick_actions_(%d+)$") then
                                        local n = key:match("^quick_actions_(%d+)$")
                                        active = G_reader_settings:readSetting("navbar_desktop_quick_actions_" .. n .. "_enabled") == true
                                    elseif key == "reading_stats" then
                                        active = G_reader_settings:readSetting("navbar_desktop_reading_stats_enabled") == true
                                    end
                                    if active then
                                        sort_items[#sort_items+1] = { text = DESKTOP_MODULE_LABELS[key] or key, orig_item = key }
                                    end
                                end
                                if #sort_items < 2 then
                                    UIManager:show(InfoMessage:new{ text = _("Enable at least 2 modules to arrange."), timeout = 2 })
                                    return
                                end
                                UIManager:show(SortWidget:new{ title = _("Arrange Modules"), item_table = sort_items, covers_fullscreen = true,
                                    callback = function()
                                        -- rebuild full order: active modules in new order, inactive ones appended
                                        local new_active = {}
                                        local active_set = {}
                                        for __, item in ipairs(sort_items) do
                                            new_active[#new_active+1] = item.orig_item
                                            active_set[item.orig_item] = true
                                        end
                                        local full_order = loadDesktopModuleOrder()
                                        for __, key in ipairs(full_order) do
                                            if not active_set[key] then new_active[#new_active+1] = key end
                                        end
                                        saveDesktopModuleOrder(new_active); refreshDesktop()
                                    end })
                            end,
                        },
                        {
                            text = _("Module Settings"), separator = true, sub_item_table_func = function()
                                -- Collections, Header, Quick Actions, Reading Goals, Reading Stats (alphabetical)
                                return {
                                    {
                                        text_func = function()
                                            local ok_cw2, CW2 = pcall(require, "collectionswidget")
                                            local n   = ok_cw2 and CW2 and #CW2.getSelected() or 0
                                            local MAX_COLL = 5
                                            local rem = MAX_COLL - n
                                            if n == 0 then return _("Collections") end
                                            if rem <= 0 then
                                                return string.format(_("Collections  (%d/%d — at limit)"), n, MAX_COLL)
                                            end
                                            return string.format(_("Collections  (%d/%d — %d left)"), n, MAX_COLL, rem)
                                        end,
                                        sub_item_table_func = function()
                                            local ok_cw, CW = pcall(require, "collectionswidget")
                                            if not ok_cw then
                                                logger.warn("simpleui: collections menu — failed to load collectionswidget:", CW)
                                                return {}
                                            end
                                            local ok_cfg, Config2 = pcall(require, "config")
                                            if not ok_cfg then
                                                logger.warn("simpleui: collections menu — failed to load config:", Config2)
                                                return {}
                                            end

                                            -- All collections: Favorites first, then the rest alphabetically.
                                            local ok_rc, rc = pcall(require, "readcollection")
                                            local fav_name = (ok_rc and rc and rc.default_collection_name) or "favorites"
                                            local non_fav = Config2.getNonFavoritesCollections()
                                            -- Check whether the Favorites collection exists.
                                            local all_colls = {}
                                            if ok_rc and rc then
                                                if rc._read then pcall(function() rc:_read() end) end
                                                if rc.coll and rc.coll[fav_name] then
                                                    all_colls[#all_colls+1] = fav_name
                                                end
                                            end
                                            for __, n in ipairs(non_fav) do all_colls[#all_colls+1] = n end

                                            -- Opens the cover-picker dialog for a collection.
                                            local function openCoverPicker(coll_name)
                                                local _n = coll_name
                                                if not ok_rc then return end
                                                if rc._read then pcall(function() rc:_read() end) end
                                                local coll = rc.coll and rc.coll[_n]
                                                if not coll then
                                                    UIManager:show(InfoMessage:new{ text = _("Collection is empty."), timeout = 2 })
                                                    return
                                                end
                                                local fps = {}
                                                for fp in pairs(coll) do fps[#fps+1] = fp end
                                                table.sort(fps)
                                                if #fps == 0 then
                                                    UIManager:show(InfoMessage:new{ text = _("Collection is empty."), timeout = 2 })
                                                    return
                                                end
                                                local overrides = CW.getCoverOverrides()
                                                local ButtonDialog = require("ui/widget/buttondialog")
                                                local cover_buttons = {}
                                                cover_buttons[#cover_buttons+1] = {{
                                                    text = (not overrides[_n] and "✓ " or "  ") .. _("Auto (first book)"),
                                                    callback = function()
                                                        UIManager:close(plugin._cover_picker)
                                                        CW.clearCoverOverride(_n); refreshDesktop()
                                                    end,
                                                }}
                                                for __, fp in ipairs(fps) do
                                                    local _fp = fp
                                                    local fname = fp:match("([^/]+)%.[^%.]+$") or fp
                                                    local title = fname
                                                    local ok_ds, ds = pcall(function()
                                                        local DocSettings = require("docsettings")
                                                        return DocSettings:open(_fp)
                                                    end)
                                                    if ok_ds and ds then
                                                        local meta = ds:readSetting("doc_props") or {}
                                                        title = meta.title or fname
                                                    end
                                                    cover_buttons[#cover_buttons+1] = {{
                                                        text = ((overrides[_n] == _fp) and "✓ " or "  ") .. title,
                                                        callback = function()
                                                            UIManager:close(plugin._cover_picker)
                                                            CW.saveCoverOverride(_n, _fp); refreshDesktop()
                                                        end,
                                                    }}
                                                end
                                                cover_buttons[#cover_buttons+1] = {{ text = _("Cancel"), callback = function() UIManager:close(plugin._cover_picker) end }}
                                                plugin._cover_picker = ButtonDialog:new{
                                                    title = string.format(_("Cover for \"%s\""), _n),
                                                    buttons = cover_buttons,
                                                }
                                                UIManager:show(plugin._cover_picker)
                                            end

                                            local items = {}

                                            -- Arrange Collections entry.
                                            items[#items+1] = {
                                                text = _("Arrange Collections"),
                                                keep_menu_open = true,
                                                separator = true,
                                                callback = function()
                                                    local cur_sel = CW.getSelected()
                                                    if #cur_sel < 2 then
                                                        UIManager:show(InfoMessage:new{ text = _("Select at least 2 collections to arrange."), timeout = 2 })
                                                        return
                                                    end
                                                    local sort_items = {}
                                                    for __, n in ipairs(cur_sel) do
                                                        sort_items[#sort_items+1] = { text = n, orig_item = n }
                                                    end
                                                    UIManager:show(SortWidget:new{
                                                        title = _("Arrange Collections"),
                                                        item_table = sort_items,
                                                        covers_fullscreen = true,
                                                        callback = function()
                                                            local new_order = {}
                                                            for __, item in ipairs(sort_items) do new_order[#new_order+1] = item.orig_item end
                                                            CW.saveSelected(new_order); refreshDesktop()
                                                        end,
                                                    })
                                                end,
                                            }

                                            -- One entry per collection (native checkbox; long-press to pick cover).
                                            if #all_colls == 0 then
                                                items[#items+1] = { text = _("No collections found."), enabled = false }
                                            else
                                                for __, coll_name in ipairs(all_colls) do
                                                    local _n = coll_name
                                                    items[#items+1] = {
                                                        text_func = function()
                                                            local cur_sel = CW.getSelected()
                                                            for __, n in ipairs(cur_sel) do
                                                                if n == _n then return _n end
                                                            end
                                                            local rem = 4 - #cur_sel
                                                            if rem <= 0 then return _n .. "  (0 left)" end
                                                            if rem <= 2 then return _n .. "  (" .. rem .. " left)" end
                                                            return _n
                                                        end,
                                                        checked_func = function()
                                                            local cur_sel = CW.getSelected()
                                                            for __, n in ipairs(cur_sel) do if n == _n then return true end end
                                                            return false
                                                        end,
                                                        keep_menu_open = true,
                                                        callback = function()
                                                            local cur = CW.getSelected()
                                                            local new_sel = {}
                                                            local found = false
                                                            for __, s in ipairs(cur) do
                                                                if s == _n then found = true
                                                                else new_sel[#new_sel+1] = s end
                                                            end
                                                            if not found then
                                                                if #cur >= 5 then
                                                                    UIManager:show(InfoMessage:new{ text = _("Maximum 5 collections. Remove one first."), timeout = 2 })
                                                                    return
                                                                end
                                                                new_sel[#new_sel+1] = _n
                                                            end
                                                            CW.saveSelected(new_sel); refreshDesktop()
                                                        end,
                                                        hold_callback = function()
                                                            openCoverPicker(_n)
                                                        end,
                                                    }
                                                end
                                            end

                                            logger.dbg("simpleui: collections menu built", #items, "items for", #all_colls, "collections")
                                            return items
                                        end,
                                    },
                                    { text = _("Header"), sub_item_table_func = function() return makeDesktopHeaderMenu() end },
                                    {
                                        text = _("Quick Actions"), sub_item_table_func = function()
                                            local items = {}
                                            for slot = 1, 3 do
                                                local _slot = slot
                                                local key = "navbar_desktop_quick_actions_" .. _slot .. "_items"
                                                items[#items+1] = {
                                                    text_func = function()
                                                        local n   = #(G_reader_settings:readSetting(key) or {})
                                                        local rem = MAX_QA_ITEMS - n
                                                        local base = string.format(_("Quick Actions %d"), _slot)
                                                        if n == 0 then return base end
                                                        if rem <= 0 then
                                                            return string.format("%s  (%d/%d — at limit)", base, n, MAX_QA_ITEMS)
                                                        end
                                                        return string.format("%s  (%d/%d — %d left)", base, n, MAX_QA_ITEMS, rem)
                                                    end,
                                                    sub_item_table_func = function() return makeQAModuleMenu(_slot) end,
                                                }
                                            end
                                            return items
                                        end,
                                    },
                                    {
                                        text = _("Reading Goals"), sub_item_table = {
                                            -- Annual sub-bar toggle.
                                            { text = _("Annual Goal"),
                                              checked_func = function()
                                                  local v = G_reader_settings:readSetting("navbar_reading_goals_show_annual")
                                                  return v == nil or v == true
                                              end,
                                              keep_menu_open = true, callback = function()
                                                  local v = G_reader_settings:readSetting("navbar_reading_goals_show_annual")
                                                  local cur = (v == nil or v == true)
                                                  G_reader_settings:saveSetting("navbar_reading_goals_show_annual", not cur)
                                                  refreshDesktop()
                                              end },
                                            -- Annual goal value.
                                            { text_func = function()
                                                  local g = G_reader_settings:readSetting("navbar_reading_goal") or 0
                                                  return g > 0 and string.format(_("  Set Goal  (%d books in %s)"), g, os.date("%Y"))
                                                             or  string.format(_("  Set Goal  (%s)"), os.date("%Y"))
                                              end, keep_menu_open = true, callback = function()
                                                  local ok_rg, RG = pcall(require, "readinggoals")
                                                  if ok_rg and RG then RG.showAnnualGoalDialog(function() refreshDesktop() end) end
                                              end },
                                            { text_func = function()
                                                  local p = G_reader_settings:readSetting("navbar_reading_goal_physical") or 0
                                                  return string.format(_("  Physical Books  (%d in %s)"), p, os.date("%Y"))
                                              end, keep_menu_open = true, callback = function()
                                                  local ok_rg, RG = pcall(require, "readinggoals")
                                                  if ok_rg and RG then RG.showAnnualPhysicalDialog(function() refreshDesktop() end) end
                                              end },
                                            -- Daily sub-bar toggle.
                                            { text = _("Daily Goal"),
                                              checked_func = function()
                                                  local v = G_reader_settings:readSetting("navbar_reading_goals_show_daily")
                                                  return v == nil or v == true
                                              end,
                                              keep_menu_open = true, callback = function()
                                                  local v = G_reader_settings:readSetting("navbar_reading_goals_show_daily")
                                                  local cur = (v == nil or v == true)
                                                  G_reader_settings:saveSetting("navbar_reading_goals_show_daily", not cur)
                                                  refreshDesktop()
                                              end },
                                            -- Daily goal value.
                                            { text_func = function()
                                                  local secs = G_reader_settings:readSetting("navbar_daily_reading_goal_secs") or 0
                                                  local h = math.floor(secs / 3600)
                                                  local m = math.floor((secs % 3600) / 60)
                                                  if secs <= 0 then
                                                      return _("  Set Goal  (disabled)")
                                                  elseif h > 0 and m > 0 then
                                                      return string.format(_("  Set Goal  (%dh %dmin/day)"), h, m)
                                                  elseif h > 0 then
                                                      return string.format(_("  Set Goal  (%dh/day)"), h)
                                                  else
                                                      return string.format(_("  Set Goal  (%dmin/day)"), m)
                                                  end
                                              end, keep_menu_open = true, callback = function()
                                                  local ok_rg, RG = pcall(require, "readinggoals")
                                                  if ok_rg and RG then RG.showDailySettingsDialog(function() refreshDesktop() end) end
                                              end },
                                        },
                                    },
                                    {
                                        text_func = function()
                                            local n   = #(G_reader_settings:readSetting("navbar_desktop_reading_stats_items") or {})
                                            local ok_rg3, RG3 = pcall(require, "readinggoals")
                                            local RS3 = ok_rg3 and RG3 and RG3.Stats
                                            local MAX_RS = RS3 and RS3.getMaxItems() or 3
                                            local rem = MAX_RS - n
                                            if n == 0 then return _("Reading Stats") end
                                            if rem <= 0 then
                                                return string.format(_("Reading Stats  (%d/%d — at limit)"), n, MAX_RS)
                                            end
                                            return string.format(_("Reading Stats  (%d/%d — %d left)"), n, MAX_RS, rem)
                                        end,
                                        sub_item_table_func = function() return makeRSModuleMenu() end,
                                    },
                                }
                            end,
                        },
                        -- Module toggles in alphabetical order:
                        -- Collections, Currently Reading, Header, Quick Actions 1/2/3,
                        -- Reading Goals, Reading Stats, Recent Books
                        {
                            text = _("Collections"),
                            checked_func = function() return G_reader_settings:nilOrTrue("navbar_desktop_collections") end,
                            keep_menu_open = true,
                            callback = function()
                                local on = G_reader_settings:nilOrTrue("navbar_desktop_collections")
                                if not on and countActiveModules() >= MAX_MODULES then maxModulesMsg(); return end
                                G_reader_settings:saveSetting("navbar_desktop_collections", not on); refreshDesktop()
                            end,
                        },
                        moduleToggle("navbar_desktop_currently",    _("Currently Reading")),
                        {
                            text = _("Header"),
                            checked_func = function() return getDesktopHeaderMode() ~= "nothing" end,
                            keep_menu_open = true, callback = function()
                                local header_on = getDesktopHeaderMode() ~= "nothing"
                                if not header_on and countActiveModules() >= MAX_MODULES then maxModulesMsg(); return end
                                if not header_on then
                                    G_reader_settings:saveSetting("navbar_desktop_header", G_reader_settings:readSetting("navbar_desktop_header_last") or "clock_date")
                                else
                                    G_reader_settings:saveSetting("navbar_desktop_header_last", getDesktopHeaderMode())
                                    G_reader_settings:saveSetting("navbar_desktop_header", "nothing")
                                end
                                refreshDesktop()
                            end,
                        },
                        qaToggle(1), qaToggle(2), qaToggle(3),
                        moduleToggle("navbar_desktop_reading_goals", _("Reading Goals")),
                        rsToggle(),
                        moduleToggle("navbar_desktop_recent",        _("Recent Books")),
                    }
                end,
            },
        }
    end

    -- Local helper: updates the active tab in the FileManager bar.
    function setActiveAndRefreshFM(plugin_ref, action_id, tabs)
        plugin_ref.active_action = action_id
        local fm = plugin_ref.ui
        if fm and fm._navbar_container then
            Bottombar.replaceBar(fm, Bottombar.buildBarWidget(action_id, fm._navbar_tabs or tabs), tabs)
            UIManager:setDirty(fm[1], "ui")
        end
        return action_id
    end

    -- -----------------------------------------------------------------------
    -- Main menu entry
    -- -----------------------------------------------------------------------

    menu_items.simpleui = {
        text = _("Simple UI"),
        sub_item_table = {
            {
                text_func    = function()
                    return _("Simple UI") .. " — " .. (G_reader_settings:nilOrTrue("simpleui_enabled") and _("On") or _("Off"))
                end,
                checked_func = function() return G_reader_settings:nilOrTrue("simpleui_enabled") end,
                callback     = function()
                    local on = G_reader_settings:nilOrTrue("simpleui_enabled")
                    G_reader_settings:saveSetting("simpleui_enabled", not on)
                    UIManager:show(ConfirmBox:new{
                        text        = string.format(_("Simple UI will be %s after restart.\n\nRestart now?"), on and _("disabled") or _("enabled")),
                        ok_text     = _("Restart"), cancel_text = _("Later"),
                        ok_callback = function()
                            G_reader_settings:flush()
                            local ok_exit, ExitCode = pcall(require, "exitcode")
                            UIManager:quit((ok_exit and ExitCode and ExitCode.restart) or 85)
                        end,
                    })
                end,
                separator = true,
            },
            {
                text           = _("Settings"),
                sub_item_table = {
                    { text = _("Bottom Bar"),    sub_item_table = makeNavbarMenu() },
                    { text = _("Desktop"),        sub_item_table_func = makeDesktopMenu },
                    { text = _("Pagination Bar"), sub_item_table = makePaginationBarMenu() },
                    {
                        text_func = function()
                            local n   = #getCustomQAList()
                            local rem = MAX_CUSTOM_QA - n
                            if n == 0 then return _("Quick Actions") end
                            if rem <= 0 then
                                return string.format(_("Quick Actions  (%d/%d — at limit)"), n, MAX_CUSTOM_QA)
                            end
                            return string.format(_("Quick Actions  (%d/%d — %d left)"), n, MAX_CUSTOM_QA, rem)
                        end,
                        sub_item_table_func = makeQuickActionsMenu,
                    },
                    { text = _("Top Bar"),        sub_item_table = makeTopbarMenu() },
                },
            },
        },
    }
end -- addToMainMenu

end -- installer function