-- collectionswidget.lua — Simple UI
-- Desktop "Collections" module: shows up to 4 selected collections as
-- stacked cover thumbnails with a book-count badge.
-- Tap opens the collection; long-press the label in the menu to pick the cover.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")

-- Thumbnail dimensions — 20 % larger than Recent Books.
local COLL_W = Screen:scaleBySize(75)   -- same as Recent Books
local COLL_H = Screen:scaleBySize(112)  -- same as Recent Books (1.5 ratio)
-- Per-cover stack offset in pixels.
local STACK_OFF = Screen:scaleBySize(5)
-- Total cell width including stack overflow.
local CELL_W = COLL_W + STACK_OFF * 2
local CELL_H = COLL_H + STACK_OFF * 2
-- Total cell height including the label.
local LABEL_LINE_H = Screen:scaleBySize(14)
local COLL_CELL_H  = CELL_H + Screen:scaleBySize(4) + LABEL_LINE_H

local PAD  = Screen:scaleBySize(14)

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------

local SETTINGS_KEY       = "navbar_desktop_collections_list"    -- {name, name, ...}
local COVER_OVERRIDE_KEY = "navbar_desktop_collections_covers"  -- {name = filepath, ...}

local function getSelectedCollections()
    return G_reader_settings:readSetting(SETTINGS_KEY) or {}
end

local function saveSelectedCollections(list)
    G_reader_settings:saveSetting(SETTINGS_KEY, list)
end

local function getCoverOverrides()
    return G_reader_settings:readSetting(COVER_OVERRIDE_KEY) or {}
end

local function saveCoverOverrides(t)
    G_reader_settings:saveSetting(COVER_OVERRIDE_KEY, t)
end

-- ---------------------------------------------------------------------------
-- ReadCollection helpers
-- ---------------------------------------------------------------------------

local function getRC()
    local ok, rc = pcall(require, "readcollection")
    if ok and rc then
        if rc._read then pcall(function() rc:_read() end) end
        return rc
    end
    return nil
end

-- Returns file paths in a collection sorted by stored order.
local function getCollectionFiles(coll_name)
    local rc = getRC()
    if not rc then return {} end
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    -- Entries are stored as {filepath = {order=n, ...}, ...}.
    local entries = {}
    for fp, info in pairs(coll) do
        local order = (type(info) == "table" and info.order) or 9999
        entries[#entries+1] = { filepath = fp, order = order }
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    local files = {}
    for _, e in ipairs(entries) do files[#files+1] = e.filepath end
    return files
end

local function getCollectionCount(coll_name)
    return #getCollectionFiles(coll_name)
end

-- ---------------------------------------------------------------------------
-- Cover loading via BookInfoManager (same pattern as desktop.lua)
-- ---------------------------------------------------------------------------

local _BookInfoManager = nil
local function getBookInfoManager()
    if _BookInfoManager then return _BookInfoManager end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    if ok and bim and type(bim) == "table" and bim.getBookInfo then
        _BookInfoManager = bim; return bim
    end
    return nil
end

local _extraction_pending = false

local function _scheduleRefreshPoll(bim)
    UIManager:scheduleIn(0.5, function()
        if not bim:isExtractingInBackground() then
            _extraction_pending = false
            -- Refresh the Desktop if it is currently visible.
            local ok_d, Desktop = pcall(require, "desktop")
            if ok_d and Desktop and Desktop._fm and Desktop._desktop_widget then
                local fm       = Desktop._fm
                local close_fn = Desktop._close_fn
                Desktop:hide()
                Desktop:show(fm, close_fn)
            end
        else
            _scheduleRefreshPoll(bim)
        end
    end)
end

local function getBookCover(filepath, w, h)
    local bim = getBookInfoManager()
    if not bim then return nil end
    local ok, bookinfo = pcall(function()
        return bim:getBookInfo(filepath, true)
    end)
    if not ok then return nil end
    if bookinfo and bookinfo.cover_fetched and bookinfo.has_cover and bookinfo.cover_bb then
        local ok2, img = pcall(function()
            return ImageWidget:new{
                image        = bookinfo.cover_bb,
                width        = w,
                height       = h,
                scale_factor = 0,
            }
        end)
        return ok2 and img or nil
    end
    if not _extraction_pending then
        _extraction_pending = true
        pcall(function()
            bim:extractInBackground({{
                filepath    = filepath,
                cover_specs = { max_cover_w = w, max_cover_h = h },
            }})
        end)
        _scheduleRefreshPoll(bim)
    end
    return nil
end

-- Returns a cover ImageWidget (COLL_W x COLL_H) or a placeholder when no cover is available.
local function coverOrPlaceholder(filepath, label)
    if filepath and lfs.attributes(filepath, "mode") == "file" then
        local img = getBookCover(filepath, COLL_W, COLL_H)
        if img then return img end
    end
    -- Placeholder showing initials when no cover exists.
    return FrameContainer:new{
        bordersize = 1, color = Blitbuffer.gray(0.7),
        background = Blitbuffer.gray(0.88),
        padding    = 0,
        dimen      = Geom:new{ w = COLL_W, h = COLL_H },
        CenterContainer:new{
            dimen = Geom:new{ w = COLL_W, h = COLL_H },
            TextWidget:new{
                text = (label or "?"):sub(1, 2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(12)),
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Build stacked cover thumbnail for a collection
-- Each cover is offset by STACK_OFF to simulate a physical stack.
-- Stack order: cover3 (back) → cover2 (middle) → cover1 (front).
-- ---------------------------------------------------------------------------

local function buildStackedCovers(files, cover_override, coll_name)
    -- Determine the up-to-3 files to show; the override cover goes first.
    local ordered = {}
    local front_fp = cover_override
    if front_fp and lfs.attributes(front_fp, "mode") ~= "file" then
        front_fp = nil
    end

    if front_fp then
        ordered[1] = front_fp
        for _, fp in ipairs(files) do
            if fp ~= front_fp then
                ordered[#ordered+1] = fp
                if #ordered >= 3 then break end
            end
        end
    else
        for i = 1, math.min(3, #files) do
            ordered[i] = files[i]
        end
    end

    -- No files available — show a single placeholder.
    if #ordered == 0 then
        return FrameContainer:new{
            bordersize = 0, padding = 0,
            dimen      = Geom:new{ w = CELL_W, h = CELL_H },
            coverOrPlaceholder(nil, coll_name),
        }
    end

    -- Build OverlapGroup: back cover placed first so front cover renders on top.

    local n = #ordered
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = CELL_W, h = CELL_H },
    }

    for i = n, 1, -1 do
        local fp    = ordered[i]
        local ox    = (n - i) * STACK_OFF + (3 - n) * STACK_OFF
        local oy    = (i - 1) * STACK_OFF
        -- Front cover (i=1) is rightmost/topmost; back (i=n) is leftmost/bottommost.
        ox = (n - i) * STACK_OFF
        oy = (i - 1) * STACK_OFF

        local cover_w = coverOrPlaceholder(fp, coll_name)
        local framed = FrameContainer:new{
            bordersize = 0,
            padding    = 0,
            dimen      = Geom:new{ w = COLL_W, h = COLL_H },
            cover_w,
        }
        framed.overlap_offset = { ox, oy }
        group[#group+1] = framed
    end

    return group
end

-- ---------------------------------------------------------------------------
-- Badge: small filled circle showing the book count
-- ---------------------------------------------------------------------------

local function buildBadge(count)
    local sz  = Screen:scaleBySize(18)
    local txt = tostring(math.min(count, 99))
    -- FrameContainer with background acts as an approximate circle.
    local inner = CenterContainer:new{
        dimen = Geom:new{ w = sz, h = sz },
        TextWidget:new{
            text    = txt,
            face    = Font:getFace("cfont", Screen:scaleBySize(9)),
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold    = true,
        },
    }
    return FrameContainer:new{
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        radius     = math.floor(sz / 2),
        padding    = 0,
        dimen      = Geom:new{ w = sz, h = sz },
        inner,
    }
end

-- ---------------------------------------------------------------------------
-- Opens a collection in the FileManager
-- ---------------------------------------------------------------------------

local function openCollection(coll_name, close_fn)
    if close_fn then close_fn() end
    UIManager:scheduleIn(0.1, function()
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        if not ok_fm or not FM or not FM.instance then return end
        local fm = FM.instance
        -- Try the collections plugin method.
        if fm.collections and type(fm.collections.onShowColl) == "function" then
            fm.collections:onShowColl(coll_name)
        elseif fm.collections and type(fm.collections.onShowCollList) == "function" then
            fm.collections:onShowCollList()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local CollectionsWidget = {}

-- Builds the Collections module widget.
-- @param w        available width in pixels
-- @param close_fn  callback to close the Desktop before navigating
-- @return HorizontalGroup with up to 4 collection cells, or nil if none selected
function CollectionsWidget:build(w, close_fn)
    local selected = getSelectedCollections()
    if #selected == 0 then return nil end

    local inner_w  = w - PAD * 2
    local cols     = math.min(#selected, 5)
    local overrides = getCoverOverrides()

    -- Fixed gap based on 5 columns for consistent alignment regardless of selection count.
    local max_cols = 5
    local gap
    if max_cols <= 1 then
        gap = 0
    else
        gap = math.floor((inner_w - max_cols * CELL_W) / (max_cols - 1))
    end

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, cols do
        local coll_name = selected[i]
        local files     = getCollectionFiles(coll_name)
        local count     = #files
        local override  = overrides[coll_name]

        -- Build the stacked cover thumbnail.
        local stack = buildStackedCovers(files, override, coll_name)

        -- Attach the book-count badge.
        local badge    = buildBadge(count)
        local badge_sz = Screen:scaleBySize(18)

        -- Overlap badge onto the bottom-left of the stack.
        local thumb = OverlapGroup:new{
            dimen = Geom:new{ w = CELL_W, h = CELL_H },
            stack,
        }
        -- Position badge in the bottom-left corner.
        local badge_margin = Screen:scaleBySize(3)
        local badge_frame  = FrameContainer:new{
            bordersize = 0, padding = 0,
            badge,
        }
        badge_frame.overlap_offset = {
            badge_margin,
            CELL_H - badge_sz - badge_margin,
        }
        thumb[#thumb+1] = badge_frame

        -- Collection name label below the thumbnail.
        local label_w = TextWidget:new{
            text      = coll_name,
            face      = Font:getFace("cfont", Screen:scaleBySize(8)),
            fgcolor   = Blitbuffer.gray(0.45),
            width     = CELL_W,
            alignment = "center",
        }

        local cell_vg = VerticalGroup:new{
            align = "center",
            thumb,
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            label_w,
        }

        -- Wrap in a tappable InputContainer.
        local _name    = coll_name
        local _close   = close_fn
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = CELL_W, h = COLL_CELL_H },
            [1]   = cell_vg,
        }
        tappable.ges_events = {
            TapColl = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapColl()
            openCollection(_name, _close)
            return true
        end

        row[#row+1] = FrameContainer:new{
            bordersize   = 0, padding = 0,
            padding_left = (i > 1) and gap or 0,
            tappable,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

-- Returns the module height (same as Recent Books).
function CollectionsWidget:getHeight()
    return COLL_CELL_H
end

-- ---------------------------------------------------------------------------
-- Settings API used by menu.lua
-- ---------------------------------------------------------------------------

function CollectionsWidget.getSelected()
    return getSelectedCollections()
end

function CollectionsWidget.saveSelected(list)
    saveSelectedCollections(list)
end

function CollectionsWidget.getCoverOverrides()
    return getCoverOverrides()
end

function CollectionsWidget.saveCoverOverride(coll_name, filepath)
    local t = getCoverOverrides()
    t[coll_name] = filepath
    saveCoverOverrides(t)
end

function CollectionsWidget.clearCoverOverride(coll_name)
    local t = getCoverOverrides()
    t[coll_name] = nil
    saveCoverOverrides(t)
end

return CollectionsWidget