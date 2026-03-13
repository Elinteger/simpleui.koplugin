-- desktop.lua — Simple UI
-- Builds and manages the Desktop overlay: clock/date header, Currently Reading,
-- Recent Books, Quick Actions, Collections, Reading Goals and Reading Stats modules.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local ImageWidget     = require("ui/widget/imagewidget")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _               = require("gettext")
local Config          = require("config")
local Screen          = Device.screen
local lfs             = require("libs/libkoreader-lfs")

local PAD      = Screen:scaleBySize(14)
local PAD2     = Screen:scaleBySize(8)
local MOD_GAP  = Screen:scaleBySize(15)  -- uniform gap between modules
local MOD_GAP_BOTTOM_EXTRA = Screen:scaleBySize(0)   -- extra bottom gap below reading_goals
local MOD_GAP_RECENT_EXTRA = Screen:scaleBySize(0)   -- extra bottom gap below recent books
local MOD_GAP_COLL_EXTRA   = Screen:scaleBySize(0)   -- extra bottom gap below collections
local QA_TOP_PAD = Screen:scaleBySize(28) -- top padding for quick actions with labels
local QA_TOP_PAD_NO_LABELS = Screen:scaleBySize(36) -- top padding for quick actions without labels
local SECTION_LABEL_SIZE = 13  -- shared size constant with readinggoals.lua
local SIDE_PAD = Screen:scaleBySize(14)  -- padding lateral, alinhado com a bottom bar

-- ---------------------------------------------------------------------------
-- Desktop settings helpers
-- ---------------------------------------------------------------------------
local function dsk(key) return "navbar_desktop_" .. key end

local DESKTOP_DEFAULTS = {
    clock        = true,
    date         = true,
    currently    = true,
    recent       = true,
    reading_goal = true,
    collections  = true,
}

local function desktopEnabled(key)
    local v = G_reader_settings:readSetting(dsk(key))
    if v == nil then return DESKTOP_DEFAULTS[key] ~= false end
    return v
end

-- Dimensions shared between Currently Reading and Recent Books (-15%)
local COVER_W = Screen:scaleBySize(102)
local COVER_H = Screen:scaleBySize(153)   -- 1.5 ratio
local RECENT_W = Screen:scaleBySize(75)
local RECENT_H = Screen:scaleBySize(112)  -- 1.5 ratio
-- Actual cell height = cover + span(4) + bar(5) + span(3) + text(~14)
local RECENT_CELL_H = RECENT_H + Screen:scaleBySize(4 + 5 + 3 + 14)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function getBookData(filepath, cached_ds)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then return {} end
    local ds
    if cached_ds then
        ds = cached_ds
    else
        local ok2
        ok2, ds = pcall(function() return DocSettings:open(filepath) end)
        if not ok2 or not ds then return {} end
    end
    local meta    = ds:readSetting("doc_props") or {}
    local percent = ds:readSetting("percent_finished") or 0
    local pages   = ds:readSetting("doc_pages")
    local md5     = ds:readSetting("partial_md5_checksum")

    -- Try to read avg_time from the statistics database.
    local avg_time = nil
    if md5 then
        local ok_sq, SQ3    = pcall(require, "lua-ljsqlite3/init")
        local ok_ds, DS     = pcall(require, "datastorage")
        if ok_sq and ok_ds then
            local db_path = DS:getSettingsDir() .. "/statistics.sqlite3"
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if ok_lfs and lfs.attributes(db_path, "mode") then
                pcall(function()
                    local conn = SQ3.open(db_path)
                    -- Fetch total read pages and time for this book via its MD5 hash.
                    local sql = [[
                        SELECT count(DISTINCT page_stat.page), sum(page_stat.duration)
                        FROM   page_stat
                        JOIN   book ON book.id = page_stat.id_book
                        WHERE  book.md5 = ?;
                    ]]
                    local stmt   = conn:prepare(sql)
                    local result = stmt:reset():bind(md5):step()
                    conn:close()
                    local read_pages = tonumber(result and result[1]) or 0
                    local total_time = tonumber(result and result[2]) or 0
                    if read_pages > 0 and total_time > 0 then
                        avg_time = total_time / read_pages
                    end
                end)
            end
        end
    end

    -- Fallback to stats stored in DocSettings (legacy format).
    if not avg_time then
        local stats = ds:readSetting("stats") or {}
        if stats.pages and stats.pages > 0
                and stats.total_time_in_sec and stats.total_time_in_sec > 0 then
            avg_time = stats.total_time_in_sec / stats.pages
        end
    end

    local fname = filepath:match("([^/]+)%.[^%.]+$") or "?"
    return {
        percent  = percent,
        title    = meta.title   or fname,
        authors  = meta.authors or "",
        pages    = pages,
        avg_time = avg_time,
    }
end

-- Returns an ImageWidget (w×h) from BookInfoManager cache, or nil.
-- If the cover has not been extracted yet, schedules background extraction
-- and polls until done, then refreshes the Desktop.
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

-- True while a background cover-extraction + refresh cycle is running.
local _extraction_pending = false

local function _scheduleRefreshPoll(bim)
    UIManager:scheduleIn(0.5, function()
        if not bim:isExtractingInBackground() then
            _extraction_pending = false
            -- Refresh the Desktop if it is currently visible.
            local Desktop = require("desktop")
            if Desktop and Desktop._fm and Desktop._desktop_widget then
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
    w = w or COVER_W
    h = h or COVER_H
    local bim = getBookInfoManager()
    if not bim then return nil end

    local ok, bookinfo = pcall(function()
        return bim:getBookInfo(filepath, true)
    end)
    if not ok then return nil end

    -- Cover is already in cache — return it immediately.
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

    -- Cover not yet available — trigger a background extraction.
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

local function formatTimeLeft(percent, pages, avg_time)
    if not avg_time or not pages or pages == 0 then return nil end
    local secs = math.max(0, math.floor(pages * (1 - (percent or 0)) * avg_time))
    if secs < 60 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    return h > 0 and string.format("%dh %dmin", h, m) or string.format("%dmin", m)
end

local function sep(w)
    return LineWidget:new{
        dimen      = Geom:new{ w = w, h = Screen:scaleBySize(1) },
        background = Blitbuffer.gray(0.85),
    }
end

local function progressBar(w, pct, bh)
    bh = bh or Screen:scaleBySize(4)
    local fw = math.max(0, math.floor(w * (pct or 0)))
    local bg = LineWidget:new{
        dimen      = Geom:new{ w = w, h = bh },
        background = Blitbuffer.gray(0.15),
    }
    if fw <= 0 then return bg end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{
            dimen      = Geom:new{ w = w, h = bh },
            background = Blitbuffer.gray(0.15),
        },
        LineWidget:new{
            dimen      = Geom:new{ w = fw, h = bh },
            background = Blitbuffer.gray(0.75),
        },
    }
end

local function coverPlaceholder(label)
    return FrameContainer:new{
        bordersize = 1, color = Blitbuffer.gray(0.7),
        background = Blitbuffer.gray(0.88),
        padding    = 0,
        dimen      = Geom:new{ w = COVER_W, h = COVER_H },
        CenterContainer:new{
            dimen = Geom:new{ w = COVER_W, h = COVER_H },
            TextWidget:new{
                text = (label or "?"):sub(1,2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
            },
        },
    }
end

local function sectionLabel(text, w)
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        padding_left = PAD, padding_right = PAD,
        padding_top = PAD2, padding_bottom = Screen:scaleBySize(4),
        TextWidget:new{
            text  = text,
            face  = Font:getFace("smallinfofont", Screen:scaleBySize(SECTION_LABEL_SIZE)),
            bold  = true,
            width = w - PAD * 2,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Header block: clock / date / custom text
-- ---------------------------------------------------------------------------

-- Returns the active header mode string.
local function getHeaderMode()
    local mode = G_reader_settings:readSetting("navbar_desktop_header")
    if mode then return mode end
    -- Migrate legacy per-toggle settings to the unified mode string.
    local show_clock = desktopEnabled("clock")
    local show_date  = desktopEnabled("date")
    if show_clock and show_date then return "clock_date" end
    if show_clock then return "clock" end
    return "nothing"
end

local function buildClock(w)
    local mode = getHeaderMode()
    if mode == "nothing" then return nil end

    local vg = VerticalGroup:new{ align = "center" }

    if mode == "clock" or mode == "clock_date" then
        local ts      = os.date("%H:%M") or "??:??"
        local clock_h = Screen:scaleBySize(50)
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = w - PAD*2, h = clock_h },
            TextWidget:new{
                text = ts,
                face = Font:getFace("smallinfofont", Screen:scaleBySize(44)),
                bold = true,
            },
        }
        if mode == "clock_date" then
            local ds     = os.date("%A, %d %B") or ""
            local date_h = Screen:scaleBySize(17)
            vg[#vg+1] = VerticalSpan:new{ width = Screen:scaleBySize(19) }
            vg[#vg+1] = CenterContainer:new{
                dimen = Geom:new{ w = w - PAD*2, h = date_h },
                TextWidget:new{
                    text    = ds,
                    face    = Font:getFace("smallinfofont", Screen:scaleBySize(11)),
                    fgcolor = Blitbuffer.gray(0.45),
                },
            }
        end

    elseif mode == "custom" then
        local custom  = G_reader_settings:readSetting("navbar_desktop_header_custom") or "KOReader"
        local label_h = Screen:scaleBySize(48)
        vg[#vg+1] = CenterContainer:new{
            dimen = Geom:new{ w = w - PAD*2, h = label_h },
            TextWidget:new{
                text  = custom,
                face  = Font:getFace("smallinfofont", Screen:scaleBySize(38)),
                bold  = true,
                width = w - PAD * 4,
            },
        }

    elseif mode == "quote" then
        local ok_qw, QW = pcall(require, "quoteswidget")
        if ok_qw and QW then
            vg[#vg+1] = QW:buildHeader(w - PAD*2)
        end
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_bottom = PAD2 + Screen:scaleBySize(4),
        vg,
    }
end

-- Forward declaration — defined later; needed by buildCurrentlyReading and buildRecentBooks.
local openBook

-- ---------------------------------------------------------------------------
-- "Currently Reading" module block
-- ---------------------------------------------------------------------------
local function buildCurrentlyReading(w, filepath, bd, close_fn)
    local cover   = getBookCover(filepath, COVER_W, COVER_H) or coverPlaceholder(bd.title)
    local tw      = w - COVER_W - PAD * 3
    local pct_str = string.format("%d%%", math.floor((bd.percent or 0) * 100)) .. " Read"
    local tl      = formatTimeLeft(bd.percent, bd.pages, bd.avg_time)

    local meta = VerticalGroup:new{ align = "left" }
    meta[#meta+1] = TextWidget:new{
        text  = bd.title or "?",
        face  = Font:getFace("smallinfofont", Screen:scaleBySize(12)),
        bold  = true,
        width = tw,
    }
    meta[#meta+1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    if bd.authors and bd.authors ~= "" then
        meta[#meta+1] = TextWidget:new{
            text    = bd.authors,
            face    = Font:getFace("smallinfofont", Screen:scaleBySize(11)),
            fgcolor = Blitbuffer.gray(0.45),
            width   = tw,
        }
        meta[#meta+1] = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    end
    meta[#meta+1] = progressBar(tw, bd.percent, Screen:scaleBySize(10))
    meta[#meta+1] = VerticalSpan:new{ width = Screen:scaleBySize(8) }
    meta[#meta+1] = TextWidget:new{
        text    = pct_str,
        face    = Font:getFace("smallinfofont", Screen:scaleBySize(11)),
        bold    = true,
        fgcolor = Blitbuffer.gray(0.20),
        width   = tw,
    }
    if tl then
        meta[#meta+1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        meta[#meta+1] = TextWidget:new{
            text    = tl:upper() .. " TO GO",
            face    = Font:getFace("smallinfofont", Screen:scaleBySize(9)),
            fgcolor = Blitbuffer.gray(0.45),
            width   = tw,
        }
    end

    local inner = FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        HorizontalGroup:new{
            align  = "center",
            FrameContainer:new{ bordersize = 0, padding = 0, padding_right = PAD, cover },
            meta,
        },
    }

    -- Wrap in InputContainer so taps are handled after layout (dimen is correct).
    local fp      = filepath
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = COVER_H + PAD * 2 },
        [1]   = inner,
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapBook()
        openBook(fp, close_fn)
        return true
    end
    return tappable
end

-- ---------------------------------------------------------------------------
-- "Recent Books" module block
-- ---------------------------------------------------------------------------
local function buildRecentBooks(w, list, close_fn)
    if #list == 0 then return nil end
    local cols     = math.min(#list, 5)
    local cw       = RECENT_W
    local ch       = RECENT_H
    local inner_w  = w - PAD * 2

    -- Fixed spacing based on 5 columns for consistent alignment.
    local max_cols = 5
    local gap
    if max_cols == 1 then
        gap = 0
    else
        gap = math.floor((inner_w - max_cols * cw) / (max_cols - 1))
    end

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, cols do
        local e = list[i]
        local cover = getBookCover(e.filepath, cw, ch)
                      or FrameContainer:new{
                          bordersize = 1, color = Blitbuffer.gray(0.7),
                          background = Blitbuffer.gray(0.88),
                          padding    = 0,
                          dimen      = Geom:new{ w = cw, h = ch },
                          CenterContainer:new{
                              dimen = Geom:new{ w = cw, h = ch },
                              TextWidget:new{
                                  text = (e.bd.title or "?"):sub(1,2):upper(),
                                  face = Font:getFace("smallinfofont", Screen:scaleBySize(12)),
                              },
                          },
                      }

        local pct_str = string.format("%d%%", math.floor((e.bd.percent or 0) * 100)) .. " Read"
        local cell = VerticalGroup:new{
            align = "left",
            cover,
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            progressBar(cw, e.bd.percent, Screen:scaleBySize(5)),
            VerticalSpan:new{ width = Screen:scaleBySize(3) },
            TextWidget:new{
                text    = pct_str,
                face    = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
                bold    = true,
                fgcolor = Blitbuffer.gray(0.20),
                width   = cw,
            },
        }
        local fp = e.filepath
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = cw, h = RECENT_CELL_H },
            [1]   = cell,
        }
        tappable.ges_events = {
            TapBook = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapBook()
            openBook(fp, close_fn)
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

-- ---------------------------------------------------------------------------
-- Quick Actions module block
-- ---------------------------------------------------------------------------

-- Reads custom QA config from settings.
local function _getCustomQAConfig(qa_id)
    local cfg = G_reader_settings:readSetting("navbar_cqa_" .. qa_id) or {}
    return {
        label      = cfg.label or qa_id,
        path       = cfg.path,
        collection = cfg.collection,
        icon       = cfg.icon,  -- nil means default folder icon
    }
end

local function buildQuickActions(w, action_ids, show_labels, on_tap_fn)
    if not action_ids or #action_ids == 0 then return nil end
    local n         = math.min(#action_ids, 4)  -- max 4 per module (single row)
    local icon_sz   = Screen:scaleBySize(52)
    local frame_pad = Screen:scaleBySize(18)
    local frame_sz  = icon_sz + frame_pad * 2
    local corner_r  = Screen:scaleBySize(22)
    local lbl_h     = show_labels and Screen:scaleBySize(20) or 0
    local lbl_sp    = show_labels and Screen:scaleBySize(7) or 0

    local inner_w = w - PAD * 2

    local ACTION_MAP = {
        home           = { icon = "plugins/simpleui.koplugin/icons/library.svg",     label = _("Library")    },
        collections    = { icon = "plugins/simpleui.koplugin/icons/collections.svg", label = _("Collections")},
        history        = { icon = "plugins/simpleui.koplugin/icons/history.svg",     label = _("History")    },
        continue       = { icon = "plugins/simpleui.koplugin/icons/continue.svg",    label = _("Continue")   },
        favorites      = { icon = "resources/icons/mdlight/star.empty.svg",          label = _("Favorites")  },
        wifi_toggle    = { icon = Config.wifiIcon(),                                   label = _("Wi-Fi")      },
        frontlight     = { icon = "plugins/simpleui.koplugin/icons/frontlight.svg",   label = _("Brightness") },
        stats_calendar = { icon = "plugins/simpleui.koplugin/icons/stats.svg",       label = _("Stats")      },
        desktop        = { icon = "resources/icons/mdlight/home.svg",                label = _("Home")       },
    }

    -- Pre-resolve all custom QA entries before building widgets.
    for i = 1, n do
        local action = action_ids[i]
        if tostring(action):match("^custom_qa_%d+$") and not ACTION_MAP[action] then
            local cfg = _getCustomQAConfig(action)
            ACTION_MAP[action] = {
                icon  = cfg.icon or "plugins/simpleui.koplugin/icons/custom.svg",
                label = cfg.label,
            }
        end
    end

    -- Compute space-between gap for n icons in the available width.
    local gap = n <= 1 and 0 or math.floor((inner_w - n * frame_sz) / (n - 1))
    -- Centre a single icon.
    local left_off = n == 1 and math.floor((inner_w - frame_sz) / 2) or 0

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, n do
        local entry = ACTION_MAP[action_ids[i]] or { icon = "resources/icons/mdlight/home.svg", label = action_ids[i] }

        local icon_frame = FrameContainer:new{
            bordersize = Screen:scaleBySize(1),
            color      = Blitbuffer.gray(0.75),
            background = Blitbuffer.COLOR_WHITE,
            radius     = corner_r,
            padding    = frame_pad,
            ImageWidget:new{
                file    = entry.icon,
                width   = icon_sz,
                height  = icon_sz,
                is_icon = true,
                alpha   = true,
            },
        }

        local col = VerticalGroup:new{ align = "center" }
        col[#col+1] = icon_frame
        if show_labels then
            col[#col+1] = VerticalSpan:new{ width = lbl_sp }
            col[#col+1] = CenterContainer:new{
                dimen = Geom:new{ w = frame_sz, h = lbl_h },
                TextWidget:new{
                    text    = entry.label,
                    face    = Font:getFace("cfont", Screen:scaleBySize(9)),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = frame_sz,
                },
            }
        end

        -- Wrap col in InputContainer for tap handling (same pattern as recent/collections)
        local _action_id = action_ids[i]
        local col_h_tap  = frame_sz + lbl_sp + lbl_h
        local tappable   = InputContainer:new{
            dimen = Geom:new{ w = frame_sz, h = col_h_tap },
            [1]   = col,
        }
        tappable.ges_events = {
            TapQA = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapQA()
            if on_tap_fn then on_tap_fn(_action_id) end
            return true
        end

        if i > 1 then
            row[#row+1] = FrameContainer:new{
                bordersize = 0, padding = 0, padding_left = gap, tappable,
            }
        else
            row[#row+1] = tappable
        end
    end

    return FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_top    = 0,
        padding_bottom = 0,
        padding_left   = PAD + left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Opens a book: restores the FileManager tab first, then opens the reader
-- ---------------------------------------------------------------------------
function openBook(filepath, close_fn)
    if close_fn then close_fn() end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then
        UIManager:scheduleIn(0.1, function()
            ReaderUI:showReader(filepath)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Empty-state widget shown when no books have been read
-- ---------------------------------------------------------------------------
local function buildEmptyState(w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = Screen:scaleBySize(30) },
                TextWidget:new{
                    text = _("No books opened yet"),
                    face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
                    bold = true,
                },
            },
            VerticalSpan:new{ width = Screen:scaleBySize(12) },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = Screen:scaleBySize(20) },
                TextWidget:new{
                    text    = _("Open a book to get started"),
                    face    = Font:getFace("smallinfofont", Screen:scaleBySize(13)),
                    fgcolor = Blitbuffer.gray(0.45),
                },
            },
        },
    }
end



local Desktop = {}

-- Builds and returns the desktop content widget sized to fit the available
-- content area (screen minus topbar and bottom bar).
function Desktop:_buildContent(w, h, close_fn)
    self._buildContent_count = (self._buildContent_count or 0) + 1
    logger.dbg("Desktop: _buildContent call #" .. self._buildContent_count)
    self._book_zones  = {}

    -- Apply side padding; store the offset for touch-zone coordinate adjustments.
    local side_off = SIDE_PAD
    w = w - side_off * 2

    -- Full height available — Desktop has no internal topbar.
    local content_h = h

    -- Load read history only if at least one book-list module is active.
    local current_fp = nil
    local recent_fps = {}
    local prefetched_data = {}  -- cache: filepath -> book data, avoids a second DocSettings open in getBookData
    local show_currently = desktopEnabled("currently")
    local show_recent    = desktopEnabled("recent")
    if show_currently or show_recent then
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory then
        if not ReadHistory.hist or #ReadHistory.hist == 0 then
            pcall(function() ReadHistory:reload() end)
        end
        local ok_ds, DocSettings = pcall(require, "docsettings")
        for i, entry in ipairs(ReadHistory.hist or {}) do
            local fp = entry.file
            if fp and lfs.attributes(fp, "mode") == "file" then
                if i == 1 then
                    if show_currently then current_fp = fp end
                elseif show_recent and #recent_fps < 5 then
                    -- Open DocSettings once per book: check isFinished and pre-cache metadata.
                    local pct = 0
                    if ok_ds and DocSettings then
                        local ok2, ds = pcall(function() return DocSettings:open(fp) end)
                        if ok2 and ds then
                            pct = ds:readSetting("percent_finished") or 0
                            prefetched_data[fp] = ds  -- guardar para reutilizar no render
                        end
                    end
                    if pct < 1.0 then
                        recent_fps[#recent_fps+1] = fp
                    end
                end
            end
            if not show_recent and current_fp then break end
            if current_fp and #recent_fps >= 5 then break end
        end
    end
    end -- show_currently or show_recent
    local has_content    = (current_fp and show_currently) or (#recent_fps > 0 and show_recent)
    local wants_books    = show_currently or show_recent

    local body = VerticalGroup:new{ align = "left" }
    local header_mode = getHeaderMode()
    local show_date   = (header_mode == "clock_date")
    local clock_h   = Screen:scaleBySize(50 + 4) + PAD * 2 + PAD2
                    + (show_date and (Screen:scaleBySize(17) + Screen:scaleBySize(10)) or 0)
    local label_h   = PAD2 + Screen:scaleBySize(4) + Screen:scaleBySize(16)
    local cursor_y  = 0

    -- Module alignment mode: "top" (default) or "bottom".
    local align_bottom = G_reader_settings:readSetting("navbar_desktop_module_align") == "bottom"

    if wants_books and not has_content then
        -- Empty state: show header (if active) and a centred empty-state message.
        if header_mode ~= "nothing" then
            local hdr = buildClock(w)
            if hdr then body[#body+1] = hdr; cursor_y = clock_h end
        end
        local remaining_h = content_h - cursor_y
        body[#body+1] = buildEmptyState(w, remaining_h)
    else
        -- Load the saved module display order.
        local DEFAULT_MODULE_ORDER = {
            "header",
            "currently", "recent", "collections", "reading_goals",
            "reading_stats",
            "quick_actions_1", "quick_actions_2", "quick_actions_3",
        }
        local saved_order = G_reader_settings:readSetting("navbar_desktop_module_order")
        local module_order
        if type(saved_order) == "table" and #saved_order > 0 then
            -- Ensure every known module is represented in the order list.
            local seen = {}
            module_order = {}
            for __i, v in ipairs(saved_order) do
                seen[v] = true
                module_order[#module_order + 1] = v
            end
            for __i, v in ipairs(DEFAULT_MODULE_ORDER) do
                if not seen[v] then module_order[#module_order + 1] = v end
            end
        else
            module_order = DEFAULT_MODULE_ORDER
        end

        -- ---------------------------------------------------------------------------
        -- Helper: builds active module widgets and accumulates
        -- a sua altura total. Usada tanto no modo top como no modo bottom.
        -- Devolve: lista de {widget_or_pair, height, module_id, extra_data}
        -- ---------------------------------------------------------------------------
        local function collectModules()
            local items = {}
            local total_h = 0
            for __i, module_id in ipairs(module_order) do

                if module_id == "header" and header_mode ~= "nothing" then
                    local hdr = buildClock(w)
                    if hdr then
                        items[#items+1] = { id = "header", content = hdr, h = clock_h }
                        total_h = total_h + clock_h
                    end

                elseif module_id == "currently" and current_fp and desktopEnabled("currently") then
                    local bd = getBookData(current_fp, prefetched_data[current_fp])
                    local cr_block_h = COVER_H
                    local module_h   = label_h + cr_block_h + MOD_GAP
                    items[#items+1] = {
                        id       = "currently",
                        label_w  = sectionLabel(_("Currently Reading"), w),
                        content  = buildCurrentlyReading(w, current_fp, bd, close_fn),
                        h        = module_h,
                        filepath = current_fp,
                    }
                    total_h = total_h + module_h

                elseif module_id == "recent" and #recent_fps > 0 and desktopEnabled("recent") then
                    local list = {}
                    for __i, fp in ipairs(recent_fps) do
                        list[#list+1] = { filepath = fp, bd = getBookData(fp, prefetched_data[fp]) }
                    end
                    local rb = buildRecentBooks(w, list, close_fn)
                    if rb then
                        local module_h = label_h + RECENT_CELL_H + MOD_GAP + MOD_GAP_RECENT_EXTRA
                        items[#items+1] = {
                            id      = "recent",
                            label_w = sectionLabel(_("Recent Books"), w),
                            content = rb,
                            h       = module_h,
                            list    = list,
                        }
                        total_h = total_h + module_h
                    end

                elseif module_id == "collections" and desktopEnabled("collections") then
                    local ok_cw, CW = pcall(require, "collectionswidget")
                    if ok_cw and CW then
                        local coll_widget = CW:build(w, close_fn)
                        if coll_widget then
                            local zone_h   = CW:getHeight()
                            local module_h = label_h + zone_h + MOD_GAP + MOD_GAP_COLL_EXTRA
                            items[#items+1] = {
                                id      = "collections",
                                label_w = sectionLabel(_("Collections"), w),
                                content = coll_widget,
                                h       = module_h,
                                zone_h  = zone_h,
                            }
                            total_h = total_h + module_h
                        end
                    end

                elseif module_id == "reading_goals" and desktopEnabled("reading_goals") then
                    local ok_rg, ReadingGoals = pcall(require, "readinggoals")
                    if ok_rg and ReadingGoals and type(ReadingGoals.build) == "function" then
                        local rg_widget = ReadingGoals:build(w, sectionLabel)
                        if rg_widget then
                            local zone_h   = ReadingGoals:getHeight()
                            local module_h = label_h + zone_h + MOD_GAP + MOD_GAP_BOTTOM_EXTRA
                            items[#items+1] = {
                                id      = "reading_goals",
                                label_w = sectionLabel(_("Reading Goals"), w),
                                content = rg_widget,
                                h       = module_h,
                                zone_h  = zone_h,
                            }
                            total_h = total_h + module_h
                        end
                    end

                elseif module_id == "reading_stats" then
                    local ok_rg, RG = pcall(require, "readinggoals")
                    local RS = ok_rg and RG and RG.Stats
                    if RS and RS.isEnabled() then
                        local stat_ids = RS.getItems()
                        if #stat_ids > 0 then
                            local rs_widget = RS.buildRow(w, stat_ids)
                            if rs_widget then
                                local card_h   = RS.getCardHeight()
                                local rs_top   = QA_TOP_PAD_NO_LABELS
                                local module_h = rs_top + card_h + MOD_GAP
                                items[#items+1] = {
                                    id         = module_id,
                                    content    = rs_widget,
                                    h          = module_h,
                                    rs_top     = rs_top,
                                    rs_card_h  = card_h,
                                }
                                total_h = total_h + module_h
                            end
                        end
                    end

                elseif module_id == "quick_actions_1"
                    or module_id == "quick_actions_2"
                    or module_id == "quick_actions_3" then
                    local slot_n = module_id:match("_(%d+)$")
                    local enabled_key = "navbar_desktop_quick_actions_" .. slot_n .. "_enabled"
                    local items_key   = "navbar_desktop_quick_actions_" .. slot_n .. "_items"
                    local labels_key  = "navbar_desktop_quick_actions_" .. slot_n .. "_labels"
                    if G_reader_settings:readSetting(enabled_key) == true then
                        local qa_ids = G_reader_settings:readSetting(items_key) or {}
                        local show_labels = G_reader_settings:nilOrTrue(labels_key)
                        if #qa_ids > 0 then
                            local n           = math.min(#qa_ids, 4)
                            local qa_widget   = buildQuickActions(w, qa_ids, show_labels, function(aid) if self._on_qa_tap then self._on_qa_tap(aid) end end)
                            if qa_widget then
                                local icon_sz   = Screen:scaleBySize(52)
                                local frame_pad = Screen:scaleBySize(18)
                                local frame_sz  = icon_sz + frame_pad * 2
                                local lbl_sp    = show_labels and Screen:scaleBySize(7) or 0
                                local lbl_h_qa  = show_labels and Screen:scaleBySize(20) or 0
                                local col_h     = frame_sz + lbl_sp + lbl_h_qa
                                local qa_top    = show_labels and QA_TOP_PAD or QA_TOP_PAD_NO_LABELS
                                local module_h  = qa_top + col_h + MOD_GAP
                                items[#items+1] = {
                                    id       = module_id,
                                    content  = qa_widget,
                                    h        = module_h,
                                    qa_col_h = col_h,
                                    qa_top   = qa_top,
                                }
                                total_h = total_h + module_h
                            end
                        end
                    end
                end -- elseif quick_actions
            end -- for module_id
            return items, total_h
        end

        -- ---------------------------------------------------------------------------
        -- Insert module widgets and register their touch zones from start_y downward.
        -- Uniform structure: label_w + content + MOD_GAP for every module.
        -- ---------------------------------------------------------------------------
        local function placeModules(items, start_y)
            local cy = start_y
            for _, m in ipairs(items) do

                if m.id == "header" then
                    body[#body+1] = m.content
                    cy = cy + m.h

                elseif m.id == "currently" then
                    body[#body+1] = m.label_w
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP }
                    -- Tap handled by InputContainer inside buildCurrentlyReading.
                    cy = cy + label_h + COVER_H + MOD_GAP

                elseif m.id == "recent" then
                    body[#body+1] = m.label_w
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP + MOD_GAP_RECENT_EXTRA }
                    -- Taps handled by dynamic GestureRange inside InputContainers.
                    cy = cy + label_h + RECENT_CELL_H + MOD_GAP + MOD_GAP_RECENT_EXTRA

                elseif m.id == "collections" then
                    body[#body+1] = m.label_w
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP + MOD_GAP_COLL_EXTRA }
                    cy = cy + label_h + m.zone_h + MOD_GAP + MOD_GAP_COLL_EXTRA

                elseif m.id == "reading_goals" then
                    body[#body+1] = m.label_w
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP + MOD_GAP_BOTTOM_EXTRA }
                    cy = cy + label_h + m.zone_h + MOD_GAP + MOD_GAP_BOTTOM_EXTRA

                elseif m.id == "reading_stats" then
                    local rs_top = m.rs_top or QA_TOP_PAD_NO_LABELS
                    if rs_top > 0 then
                        body[#body+1] = VerticalSpan:new{ width = rs_top }
                    end
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP }
                    cy = cy + rs_top + m.rs_card_h + MOD_GAP

                elseif m.id == "quick_actions_1"
                    or m.id == "quick_actions_2"
                    or m.id == "quick_actions_3" then
                    local qa_top = m.qa_top or QA_TOP_PAD
                    -- Taps handled by InputContainer inside buildQuickActions.
                    if qa_top > 0 then
                        body[#body+1] = VerticalSpan:new{ width = qa_top }
                    end
                    body[#body+1] = m.content
                    body[#body+1] = VerticalSpan:new{ width = MOD_GAP }
                    cy = cy + qa_top + m.qa_col_h + MOD_GAP
                end
            end
            return cy
        end

        -- Collect all module widgets and compute total content height.
        local module_items, modules_total_h = collectModules()

        if align_bottom then
            -- Bottom-align mode: insert a filler between header and modules.
            -- Reserve bottom margin so content does not touch the bar.
            local bottom_margin = PAD2
            local filler_h = content_h - cursor_y - modules_total_h - bottom_margin
            if filler_h > 0 then
                body[#body+1] = VerticalSpan:new{ width = filler_h }
                cursor_y = cursor_y + filler_h
            end
            cursor_y = placeModules(module_items, cursor_y)
        else
            -- Top-align mode (default): modules immediately follow the header.
            cursor_y = placeModules(module_items, cursor_y)
        end

    end -- has_content

    -- Filler final: garante que a bottom bar fica sempre no fundo
    local filler_h = content_h - cursor_y
    if filler_h > 0 then
        body[#body+1] = VerticalSpan:new{ width = filler_h }
    end

    local content = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen      = Geom:new{ w = w, h = content_h },
        body,
    }

    self._close_fn  = close_fn
    self._content_w = w
    self._content_h = h

    return FrameContainer:new{
        bordersize     = 0, padding = 0,
        padding_left   = side_off,
        padding_right  = side_off,
        background     = Blitbuffer.COLOR_WHITE,
        dimen          = Geom:new{ w = w + side_off * 2, h = h },
        content,
    }
end

-- Injects the Desktop widget into fm's navbar_container (slot 1) synchronously.
-- Safe to call before UIManager:show(fm) — no touch-zone registration happens here.
-- Returns true on success.
function Desktop:_injectWidget(fm, close_fn)
    if not fm or not fm._navbar_container then
        logger.warn("desktop: FileManager or navbar_container not available")
        return false
    end

    local inner_idx = 1
    self._fm        = fm
    self._inner_idx = inner_idx
    self._close_fn  = close_fn
    -- Only capture _orig_inner if it is not already the desktop widget itself.
    -- setupLayout is called multiple times during FM boot; each call replaces
    -- fm._navbar_container[1] with a fresh wrapped widget, but if we already
    -- injected the desktop on a previous call the container slot already holds
    -- the desktop widget — capturing that as _orig_inner would mean hide()
    -- restores a Desktop instead of the FileChooser.
    local candidate = fm._navbar_container[inner_idx]
    if candidate ~= self._desktop_widget then
        self._orig_inner = candidate
    end

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local topbar_h  = fm._navbar_topbar_h or 0
    local content_h = fm._navbar_content_h or (sh - (fm._navbar_height or 0))

    local desktop_widget = self:_buildContent(sw, content_h, close_fn)

    local orig = self._orig_inner
    if orig and orig.overlap_offset then
        desktop_widget.overlap_offset = orig.overlap_offset
    else
        desktop_widget.overlap_offset = { 0, topbar_h }
    end

    fm._navbar_container[inner_idx] = desktop_widget
    self._desktop_widget = desktop_widget
    return true
end

-- Registers touch zones on fm and starts the clock refresh timer.
-- Must be called AFTER UIManager:show(fm) so that registerTouchZones works.
function Desktop:_registerZones(fm)
    fm = fm or self._fm
    if not fm or not self._desktop_widget then return end

    local sh = Screen:getHeight()
    local topbar_h  = fm._navbar_topbar_h or 0
    local content_h = fm._navbar_content_h or (sh - (fm._navbar_height or 0))

    local specific_zones = self:getTouchZones(topbar_h)
    -- registerTouchZones prepends, so the LAST entry here ends up FIRST (highest
    -- priority). content_sink must be FIRST so it ends up with LOWEST priority.
    local reg_zones = {
        {
            id      = "desktop_content_sink",
            ges     = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = topbar_h / sh,
                ratio_w = 1, ratio_h = content_h / sh,
            },
            handler = function() return true end,
        },
    }
    for _, z in ipairs(specific_zones) do
        reg_zones[#reg_zones + 1] = z
    end

    if fm.registerTouchZones then
        fm:registerTouchZones(reg_zones)
        self._registered_zones = reg_zones
    end

    UIManager:setDirty(fm._navbar_container, "ui")
    logger.dbg("desktop _registerZones: navbar_container[1] is desktop_widget=", tostring(fm._navbar_container[1] == self._desktop_widget))
    self:_scheduleClockRefresh()
end

-- Shows the Desktop by replacing the FileManager inner content widget.
-- fm        : the FileManager instance
-- close_fn  : called when the user navigates away from Desktop
function Desktop:show(fm, close_fn)
    if not self:_injectWidget(fm, close_fn) then return end
    self:_registerZones(fm)
end

-- Rebuilds the desktop content in-place (used e.g. after a WiFi toggle to
-- refresh state-dependent icons without closing/reopening the desktop).
-- Calls within 150ms are coalesced into a single rebuild.
function Desktop:refresh()
    if not self._desktop_widget or not self._fm then return end
    if self._refresh_scheduled then return end
    self._refresh_scheduled = true
    UIManager:scheduleIn(0.15, function()
        self._refresh_scheduled = false
        local fm = self._fm
        if not fm or not fm._navbar_container or not self._desktop_widget then return end
        local sw = Screen:getWidth()
        local sh = Screen:getHeight()
        local topbar_h  = fm._navbar_topbar_h or 0
        local content_h = fm._navbar_content_h or (sh - (fm._navbar_height or 0))
        local new_widget = self:_buildContent(sw, content_h, self._close_fn)
        local orig = self._desktop_widget
        if orig and orig.overlap_offset then
            new_widget.overlap_offset = orig.overlap_offset
        else
            new_widget.overlap_offset = { 0, topbar_h }
        end
        fm._navbar_container[self._inner_idx] = new_widget
        self._desktop_widget = new_widget
        UIManager:setDirty(fm._navbar_container, "ui")
        UIManager:setDirty(fm, "ui")
    end)
end


function Desktop:hide()
    local fm = self._fm
    if not fm or not fm._navbar_container then return end
    local idx = self._inner_idx
    if self._orig_inner then
        fm._navbar_container[idx] = self._orig_inner
    end
    -- Unregister desktop touch zones from the FM
    if self._registered_zones and fm.unregisterTouchZones then
        fm:unregisterTouchZones(self._registered_zones)
        self._registered_zones = nil
    end
    UIManager:setDirty(fm._navbar_container, "ui")
    -- Cancel the clock refresh timer.
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
    self._fm = nil
    self._desktop_widget = nil
    self._orig_inner = nil
    self._refresh_scheduled = false
end

-- Schedules a clock refresh at the start of the next minute.
function Desktop:_scheduleClockRefresh()
    if self._clock_timer then
        UIManager:unschedule(self._clock_timer)
        self._clock_timer = nil
    end
    -- Only refresh if the Desktop is still visible.
    if not self._desktop_widget or not self._fm then return end
    -- Only schedule if time-dependent content (clock or date) is visible.
    local mode = getHeaderMode()
    if mode == "nothing" or mode == "custom" or mode == "quote" then return end
    local secs_to_next = 60 - (os.time() % 60) + 1
    self._clock_timer = function()
        self._clock_timer = nil
        if not self._desktop_widget or not self._fm then return end
        -- Do not refresh while the reader is open.
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_rui and ReaderUI and ReaderUI.instance then
            self:_scheduleClockRefresh()
            return
        end
        -- Usar refresh in-place em vez de hide+show para evitar flashui
        -- que acorda a status bar nativa do Kindle
        self:refresh()
        self:_scheduleClockRefresh()
    end
    UIManager:scheduleIn(secs_to_next, self._clock_timer)
end

-- Returns the list of touch zone definitions for the current desktop state.
-- Called by main.lua's _registerTouchZones after Desktop:show().
function Desktop:getTouchZones(top_off)
    local sw      = Screen:getWidth()
    local sh      = Screen:getHeight()
    local close_fn = self._close_fn
    local zones   = {}
    top_off = top_off or 0

    for i, zone in ipairs(self._book_zones or {}) do
        local fp = zone.filepath
        table.insert(zones, {
            id          = "desktop_book_tap_" .. i,
            ges         = "tap",
            screen_zone = {
                ratio_x = zone.x / sw,
                ratio_y = (zone.y + top_off) / sh,
                ratio_w = zone.w / sw,
                ratio_h = zone.h / sh,
            },
            handler = function()
                openBook(fp, close_fn)
                return true
            end,
        })
    end

    return zones
end

-- Entry point called from main.lua
-- fm       : FileManager instance
-- close_fn : callback to call when navigating away
function Desktop:onShowDesktop(fm, close_fn)
    self:show(fm, close_fn)
end
return Desktop