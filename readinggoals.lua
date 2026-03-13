-- readinggoals.lua — Simple UI
-- Annual and daily reading-goal progress bars, and the Reading Stats card module.

local Blitbuffer      = require("ffi/blitbuffer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("gettext")

local db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local PAD  = Screen:scaleBySize(14)
local PAD2 = Screen:scaleBySize(8)

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local function buildProgressBar(w, pct)
    local bh = math.max(1, math.floor(Screen:scaleBySize(10) * 0.90))
    local fw = math.max(0, math.floor(w * math.min(pct, 1.0)))
    local bg = Blitbuffer.gray(0.15)
    local fg = Blitbuffer.gray(0.75)

    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bh }, background = bg }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bh }, background = bg },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bh }, background = fg },
    }
end

local function buildBarAndPct(inner_w, pct, pct_str)
    local pct_reserve = Screen:scaleBySize(62)
    local bar_w       = inner_w - pct_reserve
    local overlap_h   = Screen:scaleBySize(16)
    local bar_top     = Screen:scaleBySize(4)

    local pct_widget = TextWidget:new{
        text    = pct_str,
        face    = Font:getFace("cfont", Screen:scaleBySize(12)),
        fgcolor = Blitbuffer.gray(0.30),
        bold    = true,
    }

    return OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = overlap_h },
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = bar_top },
            buildProgressBar(bar_w, pct),
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = overlap_h },
            pct_widget,
        },
    }
end

-- Height of a single goal row (bar + gap + sub-text).
local GOAL_ROW_H = Screen:scaleBySize(32)

-- Builds a single bar row: bold label on the left + bar + pct, then sub-text below.
-- Uses HorizontalGroup with align="center" so label, bar and pct are all
-- vertically centred relative to each other.
-- label_str : short bold label shown to the left of the bar (e.g. "2026", "Today")
-- pct       : 0.0–1.0+
-- pct_str   : e.g. "30%"
-- sub_str   : caption below the bar
local function buildGoalRow(inner_w, label_str, pct, pct_str, sub_str, on_tap)
    local label_reserve = Screen:scaleBySize(52)
    local label_gap     = Screen:scaleBySize(8)   -- gap between label and bar
    local pct_reserve   = Screen:scaleBySize(50)
    local bar_w         = inner_w - label_reserve - label_gap - pct_reserve
    local bh            = math.max(1, math.floor(Screen:scaleBySize(10) * 0.90))
    local fw            = math.max(0, math.floor(bar_w * math.min(pct, 1.0)))
    local bar_bg        = Blitbuffer.gray(0.15)
    local bar_fg        = Blitbuffer.gray(0.75)

    -- Progress bar
    local bar_widget
    if fw <= 0 then
        bar_widget = LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bh }, background = bar_bg }
    else
        bar_widget = OverlapGroup:new{
            dimen = Geom:new{ w = bar_w, h = bh },
            LineWidget:new{ dimen = Geom:new{ w = bar_w, h = bh }, background = bar_bg },
            LineWidget:new{ dimen = Geom:new{ w = fw,    h = bh }, background = bar_fg },
        }
    end

    -- Label text (bold, left-aligned, vertically centred with bar)
    local label_widget = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen = Geom:new{ w = label_reserve, h = bh },
        TextWidget:new{
            text    = label_str,
            face    = Font:getFace("cfont", Screen:scaleBySize(11)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold    = true,
        },
    }

    -- Percentage text (right side, vertically centred)
    local pct_widget = CenterContainer:new{
        dimen = Geom:new{ w = pct_reserve, h = bh },
        TextWidget:new{
            text    = pct_str,
            face    = Font:getFace("cfont", Screen:scaleBySize(11)),
            fgcolor = Blitbuffer.gray(0.30),
            bold    = true,
        },
    }

    -- HorizontalGroup: label | gap | bar | pct — all vertically centred
    local bar_row = HorizontalGroup:new{
        align = "center",
        label_widget,
        HorizontalSpan:new{ width = label_gap },
        bar_widget,
        pct_widget,
    }

    local sub_text = TextWidget:new{
        text    = sub_str,
        face    = Font:getFace("cfont", Screen:scaleBySize(8)),
        fgcolor = Blitbuffer.gray(0.45),
        width   = inner_w,
    }

    local row_content = VerticalGroup:new{
        align = "left",
        bar_row,
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        sub_text,
    }

    -- Wrap in a tappable InputContainer when a callback is provided.
    if on_tap then
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = inner_w, h = GOAL_ROW_H },
            [1]   = row_content,
        }
        tappable.ges_events = {
            TapGoal = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapGoal()
            on_tap()
            return true
        end
        return tappable
    end

    return row_content
end

-- ---------------------------------------------------------------------------
-- Annual Reading Goal
-- ---------------------------------------------------------------------------

local ANNUAL_GOAL_SETTING     = "navbar_reading_goal"
local ANNUAL_PHYSICAL_SETTING = "navbar_reading_goal_physical"

local function getAnnualGoal()
    return G_reader_settings:readSetting(ANNUAL_GOAL_SETTING) or 0
end
local function saveAnnualGoal(n)
    G_reader_settings:saveSetting(ANNUAL_GOAL_SETTING, n)
end
local function getAnnualPhysical()
    return G_reader_settings:readSetting(ANNUAL_PHYSICAL_SETTING) or 0
end
local function saveAnnualPhysical(n)
    G_reader_settings:saveSetting(ANNUAL_PHYSICAL_SETTING, n)
end

local function getBooksReadThisYear()
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return 0 end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return 0 end
    if not lfs.attributes(db_location, "mode") then return 0 end

    local year       = tonumber(os.date("%Y"))
    local year_start = os.time{ year = year,     month = 1, day = 1, hour = 0, min = 0, sec = 0 }
    local year_end   = os.time{ year = year + 1, month = 1, day = 1, hour = 0, min = 0, sec = 0 } - 1

    local count = 0
    local ok, err = pcall(function()
        local conn = SQ3.open(db_location)
        local sql = string.format([[
            SELECT count(DISTINCT ps.id_book)
            FROM   page_stat ps
            JOIN   book b ON b.id = ps.id_book
            WHERE  ps.start_time BETWEEN %d AND %d
            AND    (
                SELECT max(ps2.page)
                FROM   page_stat ps2
                WHERE  ps2.id_book = ps.id_book
            ) >= b.pages - 1;
        ]], year_start + 1, year_end)
        local result = conn:rowexec(sql)
        conn:close()
        count = tonumber(result) or 0
    end)
    if not ok then logger.warn("readinggoals: annual DB query failed:", tostring(err)) end
    return count
end

local function getYearReadingSecs()
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return 0 end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return 0 end
    if not lfs.attributes(db_location, "mode") then return 0 end

    local year       = tonumber(os.date("%Y"))
    local year_start = os.time{ year = year,     month = 1, day = 1, hour = 0, min = 0, sec = 0 }
    local year_end   = os.time{ year = year + 1, month = 1, day = 1, hour = 0, min = 0, sec = 0 } - 1

    local secs = 0
    local ok, err = pcall(function()
        local conn = SQ3.open(db_location)
        local sql = string.format([[
            SELECT sum(sum_duration)
            FROM (
                SELECT sum(duration) AS sum_duration
                FROM   page_stat
                WHERE  start_time BETWEEN %d AND %d
                GROUP  BY id_book, page
            );
        ]], year_start + 1, year_end)
        local result = conn:rowexec(sql)
        conn:close()
        secs = tonumber(result) or 0
    end)
    if not ok then logger.warn("readinggoals: year duration query failed:", tostring(err)) end
    return secs
end


local DAILY_GOAL_SETTING = "navbar_daily_reading_goal_secs"

local function getDailyGoalSecs()
    return G_reader_settings:readSetting(DAILY_GOAL_SETTING) or 0
end
local function saveDailyGoalSecs(secs)
    G_reader_settings:saveSetting(DAILY_GOAL_SETTING, secs)
end

local function getTodayReadingSecs()
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return 0 end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return 0 end
    if not lfs.attributes(db_location, "mode") then return 0 end

    local now_t          = os.date("*t")
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today    = os.time() - from_begin_day

    local secs = 0
    local ok, err = pcall(function()
        local conn = SQ3.open(db_location)
        local sql = string.format([[
            SELECT sum(sum_duration)
            FROM (
                SELECT sum(duration) AS sum_duration
                FROM   page_stat
                WHERE  start_time >= %d
                GROUP  BY id_book, page
            );
        ]], start_today)
        local result = conn:rowexec(sql)
        conn:close()
        secs = tonumber(result) or 0
    end)
    if not ok then logger.warn("readinggoals: daily DB query failed:", tostring(err)) end
    return secs
end

local function formatDuration(secs)
    secs = math.floor(secs)
    if secs <= 0 then return "0min" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then
        return string.format("%dh %dmin", h, m)
    elseif h > 0 then
        return string.format("%dh", h)
    else
        return string.format("%dmin", m)
    end
end

-- ---------------------------------------------------------------------------
-- Public module table
-- ---------------------------------------------------------------------------

local ReadingGoals = {}

-- ---------------------------------------------------------------------------
-- Annual: settings dialogs
-- ---------------------------------------------------------------------------

function ReadingGoals.showAnnualSettingsDialog(on_confirm)
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local goal     = getAnnualGoal()
    local physical = getAnnualPhysical()
    local year     = os.date("%Y")

    local goal_label     = goal > 0
        and string.format(_("Set Goal  (%d books in %d)"), goal, year)
        or  string.format(_("Set Goal  (%d)"), year)
    local physical_label = string.format(_("Physical Books  (%d in %d)"), physical, year)

    local dialog
    dialog = ButtonDialogTitle:new{
        title = string.format(_("Annual Reading Goal %d"), year),
        buttons = {
            {{ text = goal_label, callback = function()
                UIManager:close(dialog)
                ReadingGoals.showAnnualGoalDialog(on_confirm)
            end }},
            {{ text = physical_label, callback = function()
                UIManager:close(dialog)
                ReadingGoals.showAnnualPhysicalDialog(on_confirm)
            end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function ReadingGoals.showAnnualGoalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    local current = getAnnualGoal()
    local spin = SpinWidget:new{
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %d:"), os.date("%Y")),
        value       = current > 0 and current or 1,
        value_min   = 0,
        value_max   = 365,
        value_step  = 1,
        ok_text     = _("Save"),
        cancel_text = _("Cancel"),
        callback    = function(spin_self)
            saveAnnualGoal(math.floor(spin_self.value))
            if on_confirm then on_confirm() end
        end,
    }
    UIManager:show(spin)
end

function ReadingGoals.showAnnualPhysicalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    local current = getAnnualPhysical()
    local spin = SpinWidget:new{
        title_text  = _("Physical Books"),
        info_text   = string.format(_("Physical books read in %d (outside KOReader):"), os.date("%Y")),
        value       = current > 0 and current or 0,
        value_min   = 0,
        value_max   = 365,
        value_step  = 1,
        ok_text     = _("Save"),
        cancel_text = _("Cancel"),
        callback    = function(spin_self)
            saveAnnualPhysical(math.floor(spin_self.value))
            if on_confirm then on_confirm() end
        end,
    }
    UIManager:show(spin)
end

-- ---------------------------------------------------------------------------
-- Daily: settings dialog (hours + minutes via two SpinWidgets)
-- ---------------------------------------------------------------------------

function ReadingGoals.showDailySettingsDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    local current_secs = getDailyGoalSecs()
    local current_h    = math.floor(current_secs / 3600)
    local current_m    = math.floor((current_secs % 3600) / 60)

    -- Ask hours first, then minutes
    local spin_h = SpinWidget:new{
        title_text  = _("Daily Reading Goal — Hours"),
        info_text   = _("Hours to read per day:"),
        value       = current_h,
        value_min   = 0,
        value_max   = 23,
        value_step  = 1,
        ok_text     = _("Next"),
        cancel_text = _("Cancel"),
        callback    = function(spin_h_self)
            local chosen_h = math.floor(spin_h_self.value)
            local spin_m = SpinWidget:new{
                title_text  = _("Daily Reading Goal — Minutes"),
                info_text   = _("Additional minutes (0–55):"),
                value       = current_m,
                value_min   = 0,
                value_max   = 55,
                value_step  = 5,
                ok_text     = _("Save"),
                cancel_text = _("Cancel"),
                callback    = function(spin_m_self)
                    local total_secs = chosen_h * 3600 + math.floor(spin_m_self.value) * 60
                    saveDailyGoalSecs(total_secs)
                    if on_confirm then on_confirm() end
                end,
            }
            UIManager:show(spin_m)
        end,
    }
    UIManager:show(spin_h)
end

-- ---------------------------------------------------------------------------
-- Settings helpers: which sub-bars are enabled
-- ---------------------------------------------------------------------------
local SHOW_ANNUAL_SETTING = "navbar_reading_goals_show_annual"
local SHOW_DAILY_SETTING  = "navbar_reading_goals_show_daily"

local function showAnnual()
    local v = G_reader_settings:readSetting(SHOW_ANNUAL_SETTING)
    return v == nil or v == true   -- default on
end
local function showDaily()
    local v = G_reader_settings:readSetting(SHOW_DAILY_SETTING)
    return v == nil or v == true   -- default on
end

-- ---------------------------------------------------------------------------
-- Unified build: one module, one or two sub-bars
-- ---------------------------------------------------------------------------

function ReadingGoals:build(w, sectionLabel)
    local inner_w  = w - PAD * 2
    local show_ann = showAnnual()
    local show_day = showDaily()

    if not show_ann and not show_day then return nil end

    local rows = VerticalGroup:new{ align = "left" }

    if show_ann then
        local goal      = getAnnualGoal()
        local read      = getBooksReadThisYear() + getAnnualPhysical()
        local year      = tonumber(os.date("%Y"))
        local year_secs = getYearReadingSecs()

        local pct     = (goal > 0) and (read / goal) or 0
        local pct_str = string.format("%d%%", math.floor(pct * 100))

        local books_str
        if goal > 0 and pct >= 1.0 then
            books_str = string.format(_("Goal reached! %d books read."), read)
        elseif goal > 0 then
            books_str = string.format(_("%d / %d books"), read, goal)
        else
            books_str = string.format(_("%d books this year"), read)
        end
        local ann_sub = books_str .. "  ·  " .. formatDuration(year_secs)

        rows[#rows+1] = buildGoalRow(inner_w, tostring(year), pct, pct_str, ann_sub,
            function() ReadingGoals.showAnnualSettingsDialog() end)
    end

    if show_ann and show_day then
        rows[#rows+1] = VerticalSpan:new{ width = Screen:scaleBySize(30) }
    end

    if show_day then
        local goal_secs = getDailyGoalSecs()
        local read_secs = getTodayReadingSecs()

        local pct     = (goal_secs > 0) and (read_secs / goal_secs) or 0
        local pct_str = string.format("%d%%", math.floor(pct * 100))

        local day_sub
        local date_str = os.date("%d %b %Y")
        if goal_secs <= 0 then
            day_sub = string.format(_("%s read today · %s"), formatDuration(read_secs), date_str)
        elseif pct >= 1.0 then
            day_sub = string.format(_("Goal reached! %s read · %s"), formatDuration(read_secs), date_str)
        else
            local remaining = math.max(0, goal_secs - read_secs)
            day_sub = string.format(_("%s read · %s to go · %s"),
                formatDuration(read_secs), formatDuration(remaining), date_str)
        end

        rows[#rows+1] = buildGoalRow(inner_w, _("Today"), pct, pct_str, day_sub,
            function() ReadingGoals.showDailySettingsDialog() end)
    end

    return FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        rows,
    }
end

function ReadingGoals:getHeight()
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    -- n bars (each ~32px) + gap between bars if both
    local bars_h = n * GOAL_ROW_H
                 + (n == 2 and Screen:scaleBySize(30) or 0)
    return bars_h
end

-- Returns a list of {y_offset, h, action} for each visible goal row,
-- relative to the top of the content widget (after label_h).
-- Used by desktop.lua to register touch zones via registerTouchZones.
function ReadingGoals:getZones()
    local zones = {}
    local y = 0
    if showAnnual() then
        zones[#zones+1] = { y = y, h = GOAL_ROW_H, action = "annual" }
        y = y + GOAL_ROW_H
        if showDaily() then
            y = y + Screen:scaleBySize(10)  -- gap between bars
        end
    end
    if showDaily() then
        zones[#zones+1] = { y = y, h = GOAL_ROW_H, action = "daily" }
    end
    return zones
end


-- Convenience accessors used by menu.lua
function ReadingGoals.showAnnualBar()  return showAnnual() end
function ReadingGoals.showDailyBar()   return showDaily()  end
function ReadingGoals.setShowAnnual(v) G_reader_settings:saveSetting(SHOW_ANNUAL_SETTING, v) end
function ReadingGoals.setShowDaily(v)  G_reader_settings:saveSetting(SHOW_DAILY_SETTING,  v) end

-- ---------------------------------------------------------------------------
-- Backwards-compat shims
-- ---------------------------------------------------------------------------
ReadingGoals.buildAnnual           = ReadingGoals.build
ReadingGoals.buildDaily            = ReadingGoals.build
ReadingGoals.showSettingsDialog    = ReadingGoals.showAnnualSettingsDialog
ReadingGoals.showGoalDialog        = ReadingGoals.showAnnualGoalDialog
ReadingGoals.showPhysicalDialog    = ReadingGoals.showAnnualPhysicalDialog

-- ---------------------------------------------------------------------------
-- Reading Stats module
-- ---------------------------------------------------------------------------
-- Single "reading_stats" slot with up to 3 wide cards per row.
-- Each card shows one stat: a large value and a short caption.
--
-- Available stat IDs:
--   "today_time"   — Reading time today
--   "today_pages"  — Pages read today
--   "avg_time"     — Daily average reading time (last 7 days)
--   "avg_pages"    — Daily average pages (last 7 days)
--   "total_time"   — All-time total reading time
--   "total_books"  — Total books read
--   "streak"       — Current consecutive reading-day streak
--
-- Settings:
--   navbar_desktop_reading_stats_enabled  (bool)
--   navbar_desktop_reading_stats_items    (table de stat IDs, max 3)
-- ===========================================================================

local ReadingStats = {}

-- ---------------------------------------------------------------------------
-- Queries SQL
-- ---------------------------------------------------------------------------

local function _openDB()
    local ok_sq,  SQ3  = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end
    local ok_lfs, lfs2 = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs2.attributes(db_location, "mode") then return nil end
    local ok_c, conn = pcall(function() return SQ3.open(db_location) end)
    if not ok_c then return nil end
    return conn
end

local function _startOfToday()
    local t = os.date("*t")
    return os.time() - (t.hour * 3600 + t.min * 60 + t.sec)
end

-- Devolve { today_secs, today_pages, avg_secs, avg_pages, total_secs, total_books, streak }
local function fetchAllStats()
    local r = { today_secs=0, today_pages=0, avg_secs=0, avg_pages=0,
                total_secs=0, total_books=0, streak=0 }

    local conn = _openDB()
    if not conn then return r end

    pcall(function()
        local start_today = _startOfToday()
        local week_start  = start_today - 6 * 86400

        -- Hoje: tempo
        local rt = conn:rowexec(string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d GROUP BY id_book, page
            );]], start_today))
        r.today_secs = tonumber(rt) or 0

        -- Today: pages
        local rp = conn:rowexec(string.format([[
            SELECT count(DISTINCT page || '-' || id_book)
            FROM page_stat WHERE start_time >= %d;]], start_today))
        r.today_pages = tonumber(rp) or 0

        -- Weekly average (days with reading only)
        local rw = conn:exec(string.format([[
            SELECT count(DISTINCT dates) AS nd, sum(sd) AS tt, sum(pg) AS tp
            FROM (
                SELECT strftime('%%Y-%%m-%%d', start_time,'unixepoch','localtime') AS dates,
                       sum(duration) AS sd, count(DISTINCT page) AS pg
                FROM page_stat WHERE start_time >= %d
                GROUP BY id_book, page, dates
            ) GROUP BY dates;]], week_start))
        if rw and rw[1] then
            local nd = #rw[1]
            local tt, tp = 0, 0
            for i = 1, nd do
                tt = tt + (tonumber(rw[2][i]) or 0)
                tp = tp + (tonumber(rw[3][i]) or 0)
            end
            if nd > 0 then
                r.avg_secs  = math.floor(tt / nd)
                r.avg_pages = math.floor(tp / nd)
            end
        end

        -- All-time total
        r.total_secs  = tonumber(conn:rowexec("SELECT sum(duration) FROM page_stat;")) or 0

        -- Count books where pages read >= 99% of total_pages (join with book table)
        local tb = conn:rowexec([[
            SELECT count(*) FROM (
                SELECT ps.id_book,
                       count(DISTINCT ps.page) AS pages_read,
                       b.total_pages
                FROM page_stat ps
                JOIN book b ON b.id = ps.id_book
                WHERE b.total_pages > 0
                GROUP BY ps.id_book
                HAVING CAST(pages_read AS REAL) / b.total_pages >= 0.99
            );]])
        r.total_books = tonumber(tb) or 0

        -- Streak
        local rs = conn:exec([[
            SELECT DISTINCT strftime('%Y-%m-%d', start_time,'unixepoch','localtime') AS d
            FROM page_stat ORDER BY d DESC;]])
        if rs and rs[1] and #rs[1] > 0 then
            local dates   = rs[1]
            local one_day = 86400
            local ref_t   = start_today
            local today_s = os.date("%Y-%m-%d", ref_t)
            local yest_s  = os.date("%Y-%m-%d", ref_t - one_day)
            if dates[1] == today_s or dates[1] == yest_s then
                local y, mo, d = dates[1]:match("(%d+)-(%d+)-(%d+)")
                ref_t = os.time{ year=tonumber(y), month=tonumber(mo),
                                 day=tonumber(d), hour=0, min=0, sec=0 }
                r.streak = 1
                for i = 2, #dates do
                    local prev_s = os.date("%Y-%m-%d", ref_t - one_day)
                    if dates[i] == prev_s then
                        r.streak = r.streak + 1
                        ref_t    = ref_t - one_day
                    else break end
                end
            end
        end
    end)

    conn:close()
    return r
end

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

local function fmtTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m)
    end
end

-- ---------------------------------------------------------------------------
-- STAT_MAP — 7 individual stat entries
-- ---------------------------------------------------------------------------

-- cache de stats por render (evita 7 queries por frame)
local _stats_cache     = nil
local _stats_cache_day = nil

local function getStats()
    local today_s = os.date("%Y-%m-%d")
    if _stats_cache_day ~= today_s or _stats_cache == nil then
        _stats_cache     = fetchAllStats()
        _stats_cache_day = today_s
    end
    return _stats_cache
end

-- Invalidar cache ao refrescar o desktop
function ReadingStats.invalidateCache()
    _stats_cache = nil
end

local STAT_MAP = {
    today_time = {
        display_label = _("Today — Time"),
        value = function(s) return fmtTime(s.today_secs) end,
        label = function(s) return _("of reading today") end,
    },
    today_pages = {
        display_label = _("Today — Pages"),
        value = function(s) return tostring(s.today_pages) end,
        label = function(s) return _("pages read today") end,
    },
    avg_time = {
        display_label = _("Daily avg — Time"),
        value = function(s) return fmtTime(s.avg_secs) end,
        label = function(s) return _("daily avg (7 days)") end,
    },
    avg_pages = {
        display_label = _("Daily avg — Pages"),
        value = function(s) return tostring(s.avg_pages) end,
        label = function(s) return _("pages/day (7 days)") end,
    },
    total_time = {
        display_label = _("All time — Time"),
        value = function(s) return fmtTime(s.total_secs) end,
        label = function(s) return _("of reading, all time") end,
    },
    total_books = {
        display_label = _("All time — Books"),
        value = function(s) return tostring(s.total_books) end,
        label = function(s) return _("books finished") end,
    },
    streak = {
        display_label = _("Streak"),
        value = function(s) return tostring(s.streak) end,
        label = function(s)
            return s.streak == 1 and _("day streak") or _("days streak")
        end,
    },
}

ReadingStats.STAT_POOL = {
    "today_time", "today_pages",
    "avg_time",   "avg_pages",
    "total_time", "total_books",
    "streak",
}

function ReadingStats.getStatLabel(id)
    return STAT_MAP[id] and STAT_MAP[id].display_label or id
end

-- ---------------------------------------------------------------------------
-- buildStatCard — wide, short card (3:2 ratio, white, rounded corners)
-- ---------------------------------------------------------------------------

local RS_CORNER_R = Screen:scaleBySize(12)

local function buildStatCard(card_w, card_h, stat_id)
    local entry = STAT_MAP[stat_id]
    if not entry then return nil end

    local stats   = getStats()
    local val_str = entry.value(stats)
    local lbl_str = entry.label(stats)

    -- Valor principal — fonte grande, negrito, alinhado à esquerda
    local val_sz  = Screen:scaleBySize(16)
    local val_w   = TextWidget:new{
        text    = val_str,
        face    = Font:getFace("smallinfofont", val_sz),
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Legenda — fonte pequena, cinzento, alinhada à esquerda
    local lbl_sz = Screen:scaleBySize(8)
    local lbl_w  = TextWidget:new{
        text      = lbl_str,
        face      = Font:getFace("cfont", lbl_sz),
        fgcolor   = Blitbuffer.gray(0.50),
        alignment = "left",
    }

    -- Bloco de texto: largura determinada pelo próprio conteúdo
    local interior = VerticalGroup:new{ align = "left",
        val_w,
        lbl_w,
    }

    -- CenterContainer centra o bloco (horizontal e verticalmente) dentro do card
    return FrameContainer:new{
        dimen      = Geom:new{ w = card_w, h = card_h },
        bordersize = Screen:scaleBySize(1),
        color      = Blitbuffer.gray(0.72),
        background = Blitbuffer.COLOR_WHITE,
        radius     = RS_CORNER_R,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = card_h },
            interior,
        },
    }
end

-- ---------------------------------------------------------------------------
-- buildRow — up to 3 wide stat cards in a single row
-- card_w fills the full available width with a minimal gap.
-- ---------------------------------------------------------------------------

local RS_GAP    = Screen:scaleBySize(12)  -- espaço entre cards
local RS_CARD_H = Screen:scaleBySize(96)  -- card height (+20%)
local RS_N_COLS = 3                        -- sempre calcula largura para 3 colunas

-- Abre o ReaderProgress do plugin statistics (evento global)
local function openReaderProgress()
    local ok_um, UIManager2 = pcall(require, "ui/uimanager")
    if not ok_um then return end
    -- Fire ShowReaderProgress event, caught by the ReaderStatistics plugin.
    UIManager2:broadcastEvent(require("ui/event"):new("ShowReaderProgress"))
end

function ReadingStats.buildRow(w, stat_ids)
    if not stat_ids or #stat_ids == 0 then return nil end

    ReadingStats.invalidateCache()  -- dados frescos por render

    local n       = math.min(#stat_ids, RS_N_COLS)
    local avail_w = w - PAD * 2
    -- card_w fixo: calculado sempre para RS_N_COLS (3), independentemente de n
    local card_w  = math.floor((avail_w - RS_GAP * (RS_N_COLS - 1)) / RS_N_COLS)

    local row = HorizontalGroup:new{ align = "center" }
    for i = 1, n do
        local card_content = buildStatCard(card_w, RS_CARD_H, stat_ids[i])
                          or FrameContainer:new{
                                 dimen      = Geom:new{ w = card_w, h = RS_CARD_H },
                                 bordersize = 0, padding = 0,
                             }

        -- Envolver em InputContainer para capturar tap
        local tappable = InputContainer:new{
            dimen = Geom:new{ w = card_w, h = RS_CARD_H },
            [1]   = card_content,
        }
        tappable.ges_events = {
            TapStatCard = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapStatCard()
            openReaderProgress()
            return true
        end

        if i > 1 then
            row[#row+1] = HorizontalSpan:new{ width = RS_GAP }
        end
        row[#row+1] = tappable
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = RS_CARD_H },
        row,
    }
end

function ReadingStats.getCardHeight()
    return RS_CARD_H
end

function ReadingStats.getMaxItems()
    return RS_N_COLS
end

-- Settings helpers — single slot, no slot number
function ReadingStats.getEnabledKey() return "navbar_desktop_reading_stats_enabled" end
function ReadingStats.getItemsKey()   return "navbar_desktop_reading_stats_items"   end
function ReadingStats.isEnabled()
    return G_reader_settings:readSetting("navbar_desktop_reading_stats_enabled") == true
end
function ReadingStats.getItems()
    return G_reader_settings:readSetting("navbar_desktop_reading_stats_items") or {}
end

ReadingGoals.Stats = ReadingStats

return ReadingGoals