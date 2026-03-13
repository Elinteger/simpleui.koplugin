-- ui.lua — Simple UI
-- Shared layout infrastructure: side margin, content dimensions,
-- OverlapGroup composition (wrapWithNavbar), topbar replacement
-- and access to the UIManager window stack.

local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local LineWidget     = require("ui/widget/linewidget")
local Geom           = require("ui/geometry")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Screen         = Device.screen
local logger         = require("logger")

local M   = {}
local _dim = {}

-- ---------------------------------------------------------------------------
-- Side margin shared by topbar and bottombar
-- ---------------------------------------------------------------------------

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

function M.SIDE_M()
    return _cached("side_m", function() return Screen:scaleBySize(24) end)
end

-- ---------------------------------------------------------------------------
-- Invalidates all dimension caches across bottombar and topbar
-- ---------------------------------------------------------------------------

function M.invalidateDimCache()
    _dim = {}
    local bb = package.loaded["bottombar"]
    if bb and bb.invalidateDimCache then bb.invalidateDimCache() end
    local tb = package.loaded["topbar"]
    if tb and tb.invalidateDimCache then tb.invalidateDimCache() end
end

-- ---------------------------------------------------------------------------
-- Content area dimensions
-- ---------------------------------------------------------------------------

function M.getContentHeight()
    local Bottombar = require("bottombar")
    local Topbar    = require("topbar")
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    return Screen:getHeight() - Bottombar.TOTAL_H() - (topbar_on and Topbar.TOTAL_TOP_H() or 0)
end

function M.getContentTop()
    local Topbar    = require("topbar")
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    return topbar_on and Topbar.TOTAL_TOP_H() or 0
end

-- ---------------------------------------------------------------------------
-- Topbar replacement inside OverlapGroup
-- ---------------------------------------------------------------------------

function M.replaceTopbar(widget, new_topbar)
    local container = widget._navbar_container
    if not container then return end
    if not widget._navbar_topbar then return end
    local idx = widget._navbar_topbar_idx
    if idx and container[idx] == widget._navbar_topbar then
        new_topbar.overlap_offset = container[idx].overlap_offset or { 0, 0 }
        container[idx]        = new_topbar
        widget._navbar_topbar = new_topbar
        return
    end
    for i, child in ipairs(container) do
        if child == widget._navbar_topbar then
            new_topbar.overlap_offset = child.overlap_offset or { 0, 0 }
            container[i]              = new_topbar
            widget._navbar_topbar     = new_topbar
            widget._navbar_topbar_idx = i
            return
        end
    end
    logger.warn("simpleui: replaceTopbar could not find topbar in container — skipping")
end

-- ---------------------------------------------------------------------------
-- Wraps an inner widget with the navbar layout (topbar + content + bottombar)
-- ---------------------------------------------------------------------------

function M.wrapWithNavbar(inner_widget, active_action_id, tabs)
    local Topbar    = require("topbar")
    local Bottombar = require("bottombar")
    local screen_w  = Screen:getWidth()
    local screen_h  = Screen:getHeight()
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local navbar_on = G_reader_settings:nilOrTrue("navbar_enabled")
    local topbar_top = topbar_on and Topbar.TOTAL_TOP_H() or 0
    local content_h  = screen_h - topbar_top - Bottombar.TOTAL_H()

    local bar    = navbar_on and Bottombar.buildBarWidget(active_action_id, tabs) or nil
    local topbar = topbar_on and Topbar.buildTopbarWidget() or nil

    inner_widget.overlap_offset = { 0, topbar_top }
    if inner_widget.dimen then
        inner_widget.dimen.h = content_h
        inner_widget.dimen.w = screen_w
    else
        inner_widget.dimen = Geom:new{ w = screen_w, h = content_h }
    end

    local bar_idx       = 3
    local overlap_items = {
        dimen = Geom:new{ w = screen_w, h = screen_h },
        inner_widget,
    }

    if navbar_on then
        local bar_y = screen_h - Bottombar.TOTAL_H()
        local bot_y = screen_h - Bottombar.BOT_SP()

        local sep_line = LineWidget:new{
            dimen      = Geom:new{ w = screen_w, h = Bottombar.TOP_SP() },
            background = Blitbuffer.COLOR_WHITE,
        }
        local bot_pad = LineWidget:new{
            dimen      = Geom:new{ w = screen_w, h = Bottombar.BOT_SP() },
            background = Blitbuffer.COLOR_WHITE,
        }
        sep_line.overlap_offset = { 0, bar_y }
        bar.overlap_offset      = { 0, bar_y + Bottombar.TOP_SP() }
        bot_pad.overlap_offset  = { 0, bot_y }

        overlap_items[2] = sep_line
        overlap_items[3] = bar
        overlap_items[4] = bot_pad
    end

    if topbar_on then
        topbar.overlap_offset = { 0, 0 }
        overlap_items[#overlap_items + 1] = topbar
    end

    local topbar_idx       = topbar_on and #overlap_items or nil
    local navbar_container = OverlapGroup:new(overlap_items)

    return navbar_container,
           FrameContainer:new{
               bordersize = 0, padding = 0, margin = 0,
               background = Blitbuffer.COLOR_WHITE,
               navbar_container,
           },
           bar, topbar, bar_idx, topbar_on, topbar_idx
end

-- ---------------------------------------------------------------------------
-- Safe access to the UIManager window stack
-- ---------------------------------------------------------------------------

function M.getWindowStack()
    local UIManager = require("ui/uimanager")
    if type(UIManager._window_stack) ~= "table" then
        logger.warn("simpleui: UIManager._window_stack não disponível — API interna mudou?")
        return {}
    end
    return UIManager._window_stack
end

return M
