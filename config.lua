-- config.lua — Simple UI
-- Plugin-wide constants, action catalogue, tab/topbar configuration,
-- custom Quick Actions and settings migration.

local G_reader_settings = G_reader_settings
local logger            = require("logger")
local _                 = require("gettext")

-- ---------------------------------------------------------------------------
-- Public constants
-- ---------------------------------------------------------------------------

local M = {}

M.CUSTOM_ICON            = "plugins/simpleui.koplugin/icons/custom.svg"
M.CUSTOM_PLUGIN_ICON     = "plugins/simpleui.koplugin/icons/plugin.svg"
M.CUSTOM_DISPATCHER_ICON = "resources/icons/mdlight/appbar.settings.svg"
M.DEFAULT_NUM_TABS       = 4
M.MAX_TABS               = 5
M.MAX_LABEL_LEN          = 20
M.MAX_CUSTOM_QA          = 10

M.DEFAULT_TABS = { "home", "collections", "history", "continue", "favorites" }

-- Fallback tab IDs used when a duplicate 'home' is detected.
M.NON_HOME_DEFAULTS = {}
for __, id in ipairs(M.DEFAULT_TABS) do
    if id ~= "home" then M.NON_HOME_DEFAULTS[#M.NON_HOME_DEFAULTS + 1] = id end
end

-- ---------------------------------------------------------------------------
-- Predefined action catalogue
-- ---------------------------------------------------------------------------

M.ALL_ACTIONS = {
    { id = "home",           label = _("Library"),        icon = "plugins/simpleui.koplugin/icons/library.svg"        },
    { id = "collections",    label = _("Collections"),    icon = "plugins/simpleui.koplugin/icons/collections.svg"    },
    { id = "history",        label = _("History"),        icon = "plugins/simpleui.koplugin/icons/history.svg"        },
    { id = "continue",       label = _("Continue"),       icon = "plugins/simpleui.koplugin/icons/continue.svg"       },
    { id = "favorites",      label = _("Favorites"),      icon = "resources/icons/mdlight/star.empty.svg"              },
    { id = "wifi_toggle",    label = _("Wi-Fi"),           icon = "resources/icons/mdlight/wifi.open.100.svg"           },
    { id = "stats_calendar", label = _("Stats"),          icon = "plugins/simpleui.koplugin/icons/stats.svg"          },
    { id = "power",          label = _("Power"),          icon = "plugins/simpleui.koplugin/icons/power.svg"          },
    { id = "desktop",        label = _("Home"),           icon = "resources/icons/mdlight/home.svg"                    },
}

-- Fast lookup map keyed by action ID.
M.ACTION_BY_ID = {}
for __, a in ipairs(M.ALL_ACTIONS) do M.ACTION_BY_ID[a.id] = a end

-- ---------------------------------------------------------------------------
-- Topbar configuration
-- ---------------------------------------------------------------------------

M.TOPBAR_ITEMS = { "clock", "wifi", "brightness", "battery", "disk", "ram" }

function M.TOPBAR_ITEM_LABEL(k)
    local labels = {
        clock      = _("Clock"),
        wifi       = _("WiFi"),
        brightness = _("Brightness"),
        battery    = _("Battery"),
        disk       = _("Disk Usage"),
        ram        = _("RAM Usage"),
    }
    return labels[k] or k
end

-- Returns the normalised topbar config, migrating legacy formats when needed.
function M.getTopbarConfig()
    local raw = G_reader_settings:readSetting("navbar_topbar_config")
    local cfg = { side = {}, order_left = {}, order_right = {}, show = {}, order = {} }
    if type(raw) == "table" then
        if type(raw.side) == "table" then
            for k, v in pairs(raw.side) do cfg.side[k] = v end
        end
        if type(raw.order_left) == "table" then
            for __, v in ipairs(raw.order_left) do cfg.order_left[#cfg.order_left + 1] = v end
        end
        if type(raw.order_right) == "table" then
            for __, v in ipairs(raw.order_right) do cfg.order_right[#cfg.order_right + 1] = v end
        end
        if not next(cfg.side) and type(raw.show) == "table" then
            for k, v in pairs(raw.show) do
                cfg.side[k] = v and "right" or "hidden"
            end
            if type(raw.order) == "table" then
                for __, v in ipairs(raw.order) do
                    if v ~= "clock" and cfg.side[v] == "right" then
                        cfg.order_right[#cfg.order_right + 1] = v
                    end
                end
            end
        end
    end
    if not next(cfg.side) then
        cfg.side        = { clock = "left", battery = "right", wifi = "right" }
        cfg.order_left  = { "clock" }
        cfg.order_right = { "wifi", "battery" }
    end
    if #cfg.order_left == 0 then
        for k, s in pairs(cfg.side) do
            if s == "left" and k ~= "clock" then cfg.order_left[#cfg.order_left + 1] = k end
        end
        if cfg.side["clock"] == "left" then
            table.insert(cfg.order_left, 1, "clock")
        end
    end
    if #cfg.order_right == 0 then
        for k, s in pairs(cfg.side) do
            if s == "right" then cfg.order_right[#cfg.order_right + 1] = k end
        end
    end
    return cfg
end

function M.saveTopbarConfig(cfg)
    G_reader_settings:saveSetting("navbar_topbar_config", cfg)
end

-- ---------------------------------------------------------------------------
-- Custom Quick Actions
-- ---------------------------------------------------------------------------

function M.getCustomQAList()
    return G_reader_settings:readSetting("navbar_custom_qa_list") or {}
end

function M.saveCustomQAList(list)
    G_reader_settings:saveSetting("navbar_custom_qa_list", list)
end

function M.getCustomQAConfig(qa_id)
    local cfg = G_reader_settings:readSetting("navbar_cqa_" .. qa_id) or {}
    return {
        label             = cfg.label or qa_id,
        path              = cfg.path,
        collection        = cfg.collection,
        plugin_key        = cfg.plugin_key,
        plugin_method     = cfg.plugin_method,
        dispatcher_action = cfg.dispatcher_action,
        icon              = cfg.icon,
    }
end

function M.saveCustomQAConfig(qa_id, label, path, collection, icon, plugin_key, plugin_method, dispatcher_action)
    G_reader_settings:saveSetting("navbar_cqa_" .. qa_id, {
        label             = label,
        path              = path,
        collection        = collection,
        plugin_key        = plugin_key,
        plugin_method     = plugin_method,
        dispatcher_action = dispatcher_action,
        icon              = icon,
    })
end

function M.deleteCustomQA(qa_id)
    G_reader_settings:delSetting("navbar_cqa_" .. qa_id)
    local list = M.getCustomQAList()
    local new_list = {}
    for __, id in ipairs(list) do
        if id ~= qa_id then new_list[#new_list + 1] = id end
    end
    M.saveCustomQAList(new_list)
    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        local new_tabs = {}
        for __, id in ipairs(tabs) do
            if id ~= qa_id then new_tabs[#new_tabs + 1] = id end
        end
        G_reader_settings:saveSetting("navbar_tabs", new_tabs)
    end
    for slot = 1, 3 do
        local key = "navbar_desktop_quick_actions_" .. slot .. "_items"
        local dqa = G_reader_settings:readSetting(key)
        if type(dqa) == "table" then
            local new_dqa = {}
            for __, id in ipairs(dqa) do
                if id ~= qa_id then new_dqa[#new_dqa + 1] = id end
            end
            G_reader_settings:saveSetting(key, new_dqa)
        end
    end
end

function M.nextCustomQAId()
    local list  = M.getCustomQAList()
    local max_n = 0
    for __, id in ipairs(list) do
        local n = tonumber(id:match("^custom_qa_(%d+)$"))
        if n and n > max_n then max_n = n end
    end
    local n = max_n + 1
    while G_reader_settings:readSetting("navbar_cqa_custom_qa_" .. n) do n = n + 1 end
    return "custom_qa_" .. n
end

-- ---------------------------------------------------------------------------
-- Tab configuration
-- ---------------------------------------------------------------------------

-- In-memory cache to avoid repeated settings reads.
local _tabs_cache = nil

-- Session flag: prevents re-opening the Desktop on every setupLayout call.
M.desktop_session_opened = false

function M.invalidateTabsCache()
    _tabs_cache = nil
end

function M.loadTabConfig()
    if _tabs_cache then return _tabs_cache end
    local cfg = G_reader_settings:readSetting("navbar_tabs")
    local result = {}
    if type(cfg) == "table" and #cfg >= 2 and #cfg <= M.MAX_TABS then
        for i = 1, #cfg do
            local id = cfg[i]
            if M.ACTION_BY_ID[id] or id:match("^custom_qa_%d+$") then
                result[#result + 1] = id
            else
                logger.warn("simpleui: loadTabConfig: ignoring unknown tab id: " .. tostring(id))
            end
        end
    else
        for i = 1, M.DEFAULT_NUM_TABS do
            result[i] = M.DEFAULT_TABS[i] or M.ALL_ACTIONS[2].id
        end
    end
    M._ensureHomePresent(result)
    if not G_reader_settings:nilOrTrue("navbar_desktop_enabled") then
        local filtered = {}
        for __, id in ipairs(result) do
            if id ~= "desktop" then filtered[#filtered + 1] = id end
        end
        if #filtered < 2 then
            for __, id in ipairs(result) do
                if id ~= "desktop" then filtered[#filtered + 1] = id end
                if #filtered >= 2 then break end
            end
        end
        _tabs_cache = filtered
    else
        _tabs_cache = result
    end
    return _tabs_cache
end

function M.saveTabConfig(tabs)
    _tabs_cache = nil
    G_reader_settings:saveSetting("navbar_tabs", tabs)
end

function M.getNumTabs()
    return #M.loadTabConfig()
end

function M.getNavbarMode()
    return G_reader_settings:readSetting("navbar_mode") or "both"
end

function M._ensureHomePresent(tabs)
    local home_pos = nil
    local used = {}
    for i, id in ipairs(tabs) do
        if id == "home" then
            if not home_pos then home_pos = i; used[id] = true end
        else
            used[id] = true
        end
    end
    for i, id in ipairs(tabs) do
        if id == "home" and i ~= home_pos then
            for __, fid in ipairs(M.NON_HOME_DEFAULTS) do
                if not used[fid] then
                    tabs[i] = fid; used[fid] = true; break
                end
            end
        end
    end
    return tabs
end

function M.tabInTabs(tab_id, tabs)
    for __, tid in ipairs(tabs) do
        if tid == tab_id then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Action resolution — returns live label/icon for dynamic actions
-- ---------------------------------------------------------------------------

-- Optimistic Wi-Fi state, updated immediately on toggle.
M.wifi_optimistic = nil

function M.homeLabel()
    return G_reader_settings:nilOrTrue("navbar_desktop_enabled") and _("Library") or _("Home")
end

function M.homeIcon()
    return G_reader_settings:nilOrTrue("navbar_desktop_enabled")
        and "plugins/simpleui.koplugin/icons/library.svg"
        or  "resources/icons/mdlight/home.svg"
end

function M.wifiIcon()
    if M.wifi_optimistic ~= nil then
        return M.wifi_optimistic
            and "resources/icons/mdlight/wifi.open.100.svg"
            or  "resources/icons/mdlight/wifi.open.0.svg"
    end
    local Device = require("device")
    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if not (ok_hw and has_wifi) then return "resources/icons/mdlight/wifi.open.0.svg" end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr then return "resources/icons/mdlight/wifi.open.0.svg" end
    local ok_state, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if ok_state and wifi_on then return "resources/icons/mdlight/wifi.open.100.svg" end
    return "resources/icons/mdlight/wifi.open.0.svg"
end

function M.getActionById(id)
    if id and id:match("^custom_qa_%d+$") then
        local cfg = M.getCustomQAConfig(id)
        local default_icon
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = M.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = M.CUSTOM_PLUGIN_ICON
        else
            default_icon = M.CUSTOM_ICON
        end
        return { id = id, label = cfg.label, icon = cfg.icon or default_icon }
    end
    local a = M.ACTION_BY_ID[id]
    if not a then
        logger.warn("simpleui: unknown action id: " .. tostring(id) .. ", falling back to home")
        return M.ALL_ACTIONS[1]
    end
    if id == "home"        then return { id = a.id, label = M.homeLabel(), icon = M.homeIcon() } end
    if id == "wifi_toggle" then return { id = a.id, label = a.label, icon = M.wifiIcon() } end
    return a
end

-- ---------------------------------------------------------------------------
-- Settings migration
-- ---------------------------------------------------------------------------

function M.sanitizeLabel(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    if #s > M.MAX_LABEL_LEN then s = s:sub(1, M.MAX_LABEL_LEN) end
    return s
end

function M.migrateOldCustomSlots()
    if G_reader_settings:readSetting("navbar_custom_qa_migrated_v1") then return end
    local id_map  = {}
    local qa_list = M.getCustomQAList()
    local qa_set  = {}
    for __, id in ipairs(qa_list) do qa_set[id] = true end

    for slot = 1, 4 do
        local old_id = "custom_" .. slot
        local cfg    = G_reader_settings:readSetting("navbar_custom_" .. slot)
        if type(cfg) == "table" and (cfg.path or cfg.collection) then
            local new_id = M.nextCustomQAId()
            M.saveCustomQAConfig(new_id, cfg.label or (_("Custom") .. " " .. slot), cfg.path, cfg.collection)
            if not qa_set[new_id] then
                qa_list[#qa_list + 1] = new_id
                qa_set[new_id]        = true
            end
            id_map[old_id] = new_id
            logger.info("simpleui: migrated " .. old_id .. " -> " .. new_id)
        end
    end

    M.saveCustomQAList(qa_list)

    local tabs = G_reader_settings:readSetting("navbar_tabs")
    if type(tabs) == "table" then
        local changed = false
        for i, id in ipairs(tabs) do
            if id_map[id] then
                tabs[i] = id_map[id]; changed = true
            elseif id:match("^custom_%d+$") and not id:match("^custom_qa_") then
                table.remove(tabs, i); changed = true; break
            end
        end
        if changed then G_reader_settings:saveSetting("navbar_tabs", tabs) end
    end

    for slot = 1, 3 do
        local key = "navbar_desktop_quick_actions_" .. slot .. "_items"
        local dqa = G_reader_settings:readSetting(key)
        if type(dqa) == "table" then
            local changed = false
            local new_dqa = {}
            for __, id in ipairs(dqa) do
                if id_map[id] then
                    new_dqa[#new_dqa + 1] = id_map[id]; changed = true
                elseif not id:match("^custom_%d+$") or id:match("^custom_qa_") then
                    new_dqa[#new_dqa + 1] = id
                else
                    changed = true
                end
            end
            if changed then G_reader_settings:saveSetting(key, new_dqa) end
        end
    end

    G_reader_settings:saveSetting("navbar_custom_qa_migrated_v1", true)

    local legacy_enabled = G_reader_settings:readSetting("navbar_enabled")
    if legacy_enabled ~= nil and G_reader_settings:readSetting("simpleui_enabled") == nil then
        G_reader_settings:saveSetting("simpleui_enabled", legacy_enabled)
    end
end

-- ---------------------------------------------------------------------------
-- Collection helpers
-- ---------------------------------------------------------------------------

local _ReadCollection
function M.getReadCollection()
    if not _ReadCollection then
        local ok, rc = pcall(require, "readcollection")
        if ok then _ReadCollection = rc end
    end
    return _ReadCollection
end

function M.getNonFavoritesCollections()
    local rc = M.getReadCollection()
    if not rc then return {} end
    if rc._read then pcall(function() rc:_read() end) end
    local coll = rc.coll
    if not coll then return {} end
    local fav   = rc.default_collection_name or "favorites"
    local names = {}
    for name in pairs(coll) do
        if name ~= fav then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function M.isFavoritesWidget(w)
    if not w or w.name ~= "collections" then return false end
    local rc = M.getReadCollection()
    if not rc then return false end
    return w.path == rc.default_collection_name
end

return M