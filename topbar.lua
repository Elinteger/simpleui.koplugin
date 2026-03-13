-- topbar.lua — Simple UI
-- Status bar rendered at the top of the screen: clock, Wi-Fi, battery,
-- brightness, disk usage and RAM. Supports left/right item placement.

local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextWidget      = require("ui/widget/textwidget")
local Geom            = require("ui/geometry")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local Device          = require("device")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("gettext")

local Config = require("config")

local M = {}

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

local _dim = {}

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

local function _getTopbarScale()
    local key = G_reader_settings:readSetting("navbar_topbar_size") or "default"
    return key == "large" and 1.4 or 1.0
end

function M.SIDE_M()        return require("ui").SIDE_M()        end  -- delegação para ui.lua
function M.TOPBAR_SIDE_M() return _cached("topbar_side_m", function() return M.SIDE_M() - 3 end) end

function M.TOPBAR_H()
    return _cached("topbar_h", function()
        return math.floor(Screen:scaleBySize(18) * _getTopbarScale())
    end)
end
function M.TOPBAR_FS()
    return _cached("topbar_fs", function()
        return math.floor(Screen:scaleBySize(8) * _getTopbarScale())
    end)
end
function M.TOPBAR_CHEVRON_FS()
    return _cached("tb_chev_fs", function()
        return math.floor(Screen:scaleBySize(22) * _getTopbarScale())
    end)
end
function M.TOPBAR_PAD_TOP()
    return _cached("tb_pad_top", function()
        return math.floor(Screen:scaleBySize(20) * _getTopbarScale())
    end)
end
function M.TOPBAR_PAD_BOT()
    return _cached("tb_pad_bot", function()
        return math.floor(Screen:scaleBySize(8) * _getTopbarScale())
    end)
end
function M.TOTAL_TOP_H()
    return M.TOPBAR_H() + M.TOPBAR_PAD_TOP() + M.TOPBAR_PAD_BOT()
end

function M.invalidateDimCache()
    _dim = {}
end

-- ---------------------------------------------------------------------------
-- Disk-usage cache (refreshed every 5 minutes)
-- ---------------------------------------------------------------------------

local _topbar_disk_text = nil
local _topbar_disk_time = 0

function M.invalidateDiskCache()
    _topbar_disk_text = nil
    _topbar_disk_time = 0
end

-- ---------------------------------------------------------------------------
-- System state readers
-- ---------------------------------------------------------------------------

function M.getTopbarInfo()
    local info = { time = os.date("%H:%M") }

    local ok_p, powerd = pcall(function() return Device:getPowerDevice() end)
    if ok_p and powerd and Device:hasBattery() then
        local ok_c, cap = pcall(function() return powerd:getCapacity() end)
        if ok_c and type(cap) == "number" then
            info.battery  = cap
            local ok_chg, chg = pcall(function() return powerd:isCharging() end)
            local ok_chd, chd = pcall(function() return powerd:isCharged() end)
            info.charging     = ok_chg and chg or false
            local ok_s, sym   = pcall(function()
                return powerd:getBatterySymbol(ok_chd and chd, info.charging, cap)
            end)
            info.battery_sym = ok_s and sym or ""
        end
    end

    local ok_hw, has_wifi = pcall(function() return Device:hasWifiToggle() end)
    if ok_hw and has_wifi then
        local ok_cfg, Config = pcall(require, "config")
        if ok_cfg and Config and Config.wifi_optimistic ~= nil then
            -- Use optimistic state set immediately on toggle (same as bottom bar)
            info.wifi = Config.wifi_optimistic == true
        else
            local ok_w, wifi = pcall(function()
                local NetworkMgr = require("ui/network/manager")
                return NetworkMgr:isWifiOn()
            end)
            info.wifi = ok_w and not not wifi or false
        end
    else
        info.wifi = false
    end

    local ok_hbt, has_bt = pcall(function() return Device:hasBluetoothToggle() end)
    if ok_hbt and has_bt then
        local ok_b, bt = pcall(function() return Device:isBluetoothOn() end)
        info.bluetooth = ok_b and not not bt or false
    else
        info.bluetooth = false
    end

    local ok_br, br = pcall(function()
        local pd = Device:getPowerDevice()
        return pd and pd:frontlightIntensity()
    end)
    if ok_br and type(br) == "number" then
        info.brightness = br
    else
        local ok_sc, sc_br = pcall(function() return Screen:getBrightness() end)
        if ok_sc and type(sc_br) == "number" then
            info.brightness = sc_br > 1
                and math.floor(sc_br / 255 * 100 + 0.5)
                or  math.floor(sc_br * 100 + 0.5)
        end
    end

    pcall(function()
        local f = io.open("/proc/self/statm", "r")
        if f then
            local line = f:read("*line"); f:close()
            if line then
                local rss = tonumber(line:match("^%S+%s+(%S+)"))
                if type(rss) == "number" then info.ram = math.floor(rss / 256) end
            end
        end
    end)

    pcall(function()
        local now = os.time()
        if _topbar_disk_text and (now - (_topbar_disk_time or 0)) < 300 then
            info.disk = _topbar_disk_text; return
        end
        local pipe = io.popen("df -h /mnt/onboard 2>/dev/null || df -h / 2>/dev/null")
        if pipe then
            pipe:read("*line")
            local line = pipe:read("*line"); pipe:close()
            if line then
                local avail = line:match("%S+%s+%S+%s+%S+%s+(%S+)")
                if avail then
                    _topbar_disk_text = avail
                    _topbar_disk_time = now
                    info.disk         = avail
                end
            end
        end
    end)

    return info
end

-- ---------------------------------------------------------------------------
-- Widget construction
-- ---------------------------------------------------------------------------

function M.buildTopbarWidget()
    local screen_w  = Screen:getWidth()
    local side_m    = M.TOPBAR_SIDE_M()
    local pad_top   = M.TOPBAR_PAD_TOP()
    local pad_bot   = M.TOPBAR_PAD_BOT()
    local total_h   = M.TOPBAR_H() + pad_top + pad_bot
    local face      = Font:getFace("cfont", M.TOPBAR_FS())
    local icon_face = Font:getFace("xx_smallinfofont", M.TOPBAR_FS())
    local info      = M.getTopbarInfo()
    local tb_cfg    = Config.getTopbarConfig()

    local item_builders = {
        clock = function()
            return nil, info.time, false
        end,
        wifi = function()
            if not info.wifi then return nil, nil end
            return "\u{ECA8}", nil, true
        end,
        brightness = function()
            if not info.brightness then return nil, nil end
            return "\xe2\x98\x80", " " .. info.brightness, false
        end,
        battery = function()
            if not info.battery then return nil, nil end
            return (info.battery_sym or ""), info.battery .. "%", false
        end,
        disk = function()
            if not info.disk then return nil, nil end
            return "\u{F0A0}", " " .. info.disk, true
        end,
        ram = function()
            if not info.ram then return nil, nil end
            return "\u{EA5A}", " " .. info.ram .. "M", true
        end,
    }

    local function buildSideGroup(order)
        local group = HorizontalGroup:new{}
        local first = true
        for __, key in ipairs(order) do
            if (tb_cfg.side[key] or "hidden") == "hidden" then goto continue_side end
            local builder = item_builders[key]
            if builder then
                local icon, label, is_nerd = builder()
                if icon or (label and label ~= "") then
                    if not first then
                        group[#group + 1] = TextWidget:new{
                            text = "  ", face = face, fgcolor = Blitbuffer.COLOR_BLACK,
                        }
                    end
                    if icon then
                        group[#group + 1] = TextWidget:new{
                            text    = icon,
                            face    = is_nerd and icon_face or face,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                        }
                    end
                    if label and label ~= "" then
                        group[#group + 1] = TextWidget:new{
                            text    = label,
                            face    = face,
                            fgcolor = Blitbuffer.COLOR_BLACK,
                        }
                    end
                    first = false
                end
            end
            ::continue_side::
        end
        return group
    end

    local inner_w = screen_w - side_m * 2

    local left_w = LeftContainer:new{
        dimen = Geom:new{ w = inner_w, h = total_h },
        buildSideGroup(tb_cfg.order_left),
    }
    local right_w = RightContainer:new{
        dimen = Geom:new{ w = inner_w, h = total_h },
        buildSideGroup(tb_cfg.order_right),
    }

    local show_swipe = G_reader_settings:nilOrTrue("navbar_topbar_swipe_indicator")
    local center_w   = show_swipe and CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = total_h },
        TextWidget:new{
            text    = "\xef\xb9\x80",
            face    = Font:getFace("cfont", M.TOPBAR_CHEVRON_FS()),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    } or nil

    local row = OverlapGroup:new{
        dimen  = Geom:new{ w = inner_w, h = total_h },
        left_w, right_w, center_w,
    }

    return FrameContainer:new{
        bordersize    = 0, padding = 0, margin = 0,
        padding_left  = side_m, padding_right = side_m,
        background    = Blitbuffer.COLOR_WHITE,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Topbar touch zones
-- ---------------------------------------------------------------------------

function M.registerTouchZones(plugin, fm_self)
    if fm_self.unregisterTouchZones then
        fm_self:unregisterTouchZones({
            { id = "navbar_topbar_hold_start"    },
            { id = "navbar_topbar_hold_settings" },
            { id = "navbar_title_hold_start"     },
            { id = "navbar_title_hold_settings"  },
        })
    end

    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return end

    local screen_h    = Screen:getHeight()
    local topbar_h    = M.TOTAL_TOP_H()
    local topbar_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = topbar_h / screen_h }

    local function showSettingsMenu(title, item_table_fn, top_offset)
        if not item_table_fn then return end
        top_offset = top_offset or 0
        local Menu       = require("ui/widget/menu")
        local Bottombar  = require("bottombar")
        local menu_h     = screen_h - Bottombar.TOTAL_H() - top_offset

        local function resolveItems(items)
            local out = {}
            for __, item in ipairs(items) do
                local r = {}
                for k, v in pairs(item) do r[k] = v end
                if type(item.sub_item_table_func) == "function" then
                    r.sub_item_table      = item.sub_item_table_func()
                    r.sub_item_table_func = nil
                end
                if type(item.checked_func) == "function" then
                    local cf = item.checked_func
                    r.mandatory_func = function() return cf() and "✓" or "" end
                    r.checked_func   = nil
                end
                if type(item.enabled_func) == "function" then
                    local ef = item.enabled_func
                    r.dim        = not ef()
                    r.enabled_func = nil
                end
                out[#out + 1] = r
            end
            return out
        end

        local menu
        menu = Menu:new{
            title      = title,
            item_table = resolveItems(item_table_fn()),
            height     = menu_h,
            width      = Screen:getWidth(),
            onMenuSelect = function(self_menu, item)
                if item.sub_item_table then
                    self_menu.item_table.title = self_menu.title
                    table.insert(self_menu.item_table_stack, self_menu.item_table)
                    self_menu:switchItemTable(item.text, resolveItems(item.sub_item_table))
                elseif item.callback then
                    item.callback()
                    self_menu:updateItems()
                end
                return true
            end,
        }
        if top_offset > 0 then
            local orig_paintTo = menu.paintTo
            menu.paintTo = function(self_m, bb, x, y)
                orig_paintTo(self_m, bb, x, y + top_offset)
            end
            menu.dimen.y = top_offset
        end
        UIManager:show(menu)
    end

    fm_self:registerTouchZones({
        {
            id          = "navbar_topbar_hold_start",
            ges         = "hold",
            screen_zone = topbar_zone,
            handler     = function(_ges) return true end,
        },
        {
            id          = "navbar_topbar_hold_settings",
            ges         = "hold_release",
            screen_zone = topbar_zone,
            handler = function(_ges)
                if not plugin._makeTopbarMenu then plugin:addToMainMenu({}) end
                showSettingsMenu(_("Top Bar"), plugin._makeTopbarMenu, M.TOTAL_TOP_H())
                return true
            end,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Refresh timer
-- ---------------------------------------------------------------------------

local function shouldRunTimer()
    if not G_reader_settings:nilOrTrue("navbar_topbar_enabled") then return false end
    local cfg = Config.getTopbarConfig()
    if (cfg.side["clock"] or "hidden") == "hidden" then return false end
    local ok, RUI = pcall(require, "apps/reader/readerui")
    if ok and RUI and RUI.instance then return false end
    return true
end

function M.scheduleRefresh(plugin, delay)
    if plugin._topbar_timer then
        UIManager:unschedule(plugin._topbar_timer)
        plugin._topbar_timer = nil
    end
    if not shouldRunTimer() then return end
    plugin._topbar_timer = function() M.refresh(plugin) end
    UIManager:scheduleIn(delay, plugin._topbar_timer)
end

function M.refresh(plugin)
    if not shouldRunTimer() then return end
    local UI   = require("ui")
    local seen = {}
    local function refreshWidget(w)
        if not w or not w._navbar_container or seen[w] then return end
        seen[w] = true
        UI.replaceTopbar(w, M.buildTopbarWidget())
        UIManager:setDirty(w._navbar_container, "ui")
        UIManager:setDirty(w, "ui")
    end
    refreshWidget(plugin.ui)
    pcall(function()
        for __, entry in ipairs(UI.getWindowStack()) do refreshWidget(entry.widget) end
    end)
    local delay = 60 - (os.time() % 60) + 1
    M.scheduleRefresh(plugin, delay)
end

return M