-- quoteswidget.lua — Simple UI
-- "Quote of the Day" module for the Desktop header.
-- Reads quotes from quotes.lua in the same plugin folder.
-- Tap advances to the next quote. To add quotes, edit quotes.lua.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("gettext")

local PAD  = Screen:scaleBySize(14)
local PAD2 = Screen:scaleBySize(8)

-- ---------------------------------------------------------------------------
-- Load quotes from the local quotes.lua file
-- ---------------------------------------------------------------------------

local _quotes_cache = nil

local function loadQuotes()
    if _quotes_cache then return _quotes_cache end

    -- quotes.lua lives in the same directory as this file.
    local plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+/)[^/]+$") or ""
    local quotes_path = plugin_dir .. "quotes.lua"

    local ok, data = pcall(dofile, quotes_path)
    if not ok or type(data) ~= "table" or #data == 0 then
        logger.warn("quoteswidget: não foi possível carregar " .. quotes_path)
        -- Fallback quotes so the widget is never blank.
        _quotes_cache = {
            { q = "A reader lives a thousand lives before he dies. The man who never reads lives only one.", a = "George R.R. Martin" },
            { q = "So many books, so little time.", a = "Frank Zappa" },
            { q = "I have always imagined that Paradise will be a kind of library.", a = "Jorge Luis Borges" },
            { q = "A book is a dream that you hold in your hands.", a = "Neil Gaiman" },
            { q = "Sleep is good, he said, and books are better.", a = "George R.R. Martin", b = "A Clash of Kings" },
        }
    else
        _quotes_cache = data
        logger.dbg("quoteswidget: " .. #data .. " quotes carregadas")
    end
    return _quotes_cache
end

-- Invalidates the cache so edits to quotes.lua are picked up.
local function reloadQuotes()
    _quotes_cache = nil
    return loadQuotes()
end

-- ---------------------------------------------------------------------------
-- Random quote selection — never repeats the last shown quote
-- ---------------------------------------------------------------------------

local _last_idx = nil

local function pickQuote()
    local quotes = loadQuotes()
    local n = #quotes
    if n == 0 then return nil end
    if n == 1 then _last_idx = 1; return quotes[1] end
    local idx
    repeat idx = math.random(1, n) until idx ~= _last_idx
    _last_idx = idx
    return quotes[idx]
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local QuotesWidget = {}

-- Builds the quote header widget (quote text + attribution, centred).
-- @param w  available width in pixels
-- @return FrameContainer ready to insert in the Desktop header
function QuotesWidget:buildHeader(w)
    local inner_w = w - PAD * 2
    local q       = pickQuote()

    if not q then
        return FrameContainer:new{
            bordersize = 0, padding = PAD, padding_bottom = PAD2,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(14) },
                TextWidget:new{
                    text    = _("No quotes found."),
                    face    = Font:getFace("cfont", Screen:scaleBySize(10)),
                    fgcolor = Blitbuffer.gray(0.5),
                    width   = inner_w,
                },
            },
        }
    end

    local quote_w = TextBoxWidget:new{
        text      = "\u{201C}" .. q.q .. "\u{201D}",
        face      = Font:getFace("cfont", Screen:scaleBySize(11)),
        fgcolor   = Blitbuffer.COLOR_BLACK,
        width     = inner_w,
        alignment = "center",
    }

    local attribution = "— " .. (q.a or "?")
    if q.b and q.b ~= "" then attribution = attribution .. ",  " .. q.b end

    local author_w = TextWidget:new{
        text      = attribution,
        face      = Font:getFace("cfont", Screen:scaleBySize(9)),
        fgcolor   = Blitbuffer.gray(0.40),
        bold      = true,
        width     = inner_w,
        alignment = "center",
    }

    local inner = VerticalGroup:new{
        align = "center",
        quote_w,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        author_w,
    }

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_bottom = PAD2,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner:getSize().h },
            inner,
        },
    }
end

-- Returns the estimated height of the quote header.
function QuotesWidget:getHeaderHeight()
    local line_h   = Screen:scaleBySize(11) * 3  -- up to 3 lines of quote text
    local gap      = Screen:scaleBySize(4)
    local author_h = Screen:scaleBySize(9) + Screen:scaleBySize(2)
    return PAD + line_h + gap + author_h + PAD2
end

-- Advances to the next random quote.
function QuotesWidget:nextQuote()
    _last_idx = nil
end

-- Reloads quotes.lua from disk (useful after editing).
function QuotesWidget:reload()
    reloadQuotes()
end

-- Advances to the next random quote.
function QuotesWidget:nextQuote()
    _last_idx = nil
end

-- Reloads quotes.lua from disk.
function QuotesWidget:reload()
    reloadQuotes()
end

return QuotesWidget