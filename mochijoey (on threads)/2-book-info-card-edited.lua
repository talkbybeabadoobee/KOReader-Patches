--[[
    2-book-info-card-edited.lua  (KOReader user patch)

    Adds a "stamp style" Book Info card to the reader, modelled on the
    reference screenshot (cover + title + status badge, author, rating,
    format/size, source, tag chips, 3-column reading stats, three tabs and a
    synopsis box), with every label translated from Chinese to English.

    Install:  copy to  koreader/patches/2-book-info-card-edited.lua  and restart.
    Use:      Reader top menu  ->  Document (page icon)  ->  "Book info card"
              or assign "Show book info card" to a gesture/tap-zone in
              Settings -> Taps and gestures -> Gesture manager.
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Dispatcher      = require("dispatcher")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ReaderUI        = require("apps/reader/readerui")
local ScrollTextWidget= require("ui/widget/scrolltextwidget")
local Screen          = Device.screen
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local util            = require("util")
local _               = require("gettext")

local BLACK, GRAY, LIGHT = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_LIGHT_GRAY

------------------------------------------------------------------------
-- English labels (translated from the Chinese reference)
------------------------------------------------------------------------
local L = {
    reading        = "Reading",
    reading_done   = "Finished",
    on_hold        = "On hold",
    unread         = "Unread",
    author         = "Author: ",
    my_rating      = "My rating: ",
    points         = " pts",
    source         = "Source: ",
    source_library = "Library",
    progress       = "Reading progress",
    total_pages    = "Total pages",
    last_read      = "Last read",
    tab_synopsis   = "Synopsis",
    tab_highlights = "Highlights & bookmarks",
    tab_review     = "My review",
    no_synopsis    = "No synopsis available.",
    no_highlights  = "No highlights or bookmarks yet.",
    no_review      = "No review yet.",
    today          = "Today ",
    menu           = "Book info card",
    action         = "Show book info card",
}

------------------------------------------------------------------------
-- Stamp-style frame: rounded card with a perforated (scalloped) edge
------------------------------------------------------------------------
local StampFrame = FrameContainer:extend{
    bordersize = 0,
    padding = 0,
    margin = 0,
    background = nil, -- painted manually in paintTo
    hole_r = nil,
}

function StampFrame:paintTo(bb, x, y)
    local sz = self:getSize()
    local w, h = sz.w, sz.h
    local r = self.hole_r or Screen:scaleBySize(5)
    local band = math.floor(r * 1.8)          -- thickness of the stamp rim
    local step = r * 3

    -- 1) outer rim (dark gray) + white interior
    bb:paintRect(x, y, w, h, GRAY)
    bb:paintRect(x + band, y + band, w - 2 * band, h - 2 * band, Blitbuffer.COLOR_WHITE)

    -- 2) perforation: punch page-coloured discs through the rim
    local white = Blitbuffer.COLOR_WHITE
    for cx = x + r, x + w - r, step do
        bb:paintCircle(cx, y, r, white)
        bb:paintCircle(cx, y + h - 1, r, white)
    end
    for cy = y + r, y + h - r, step do
        bb:paintCircle(x, cy, r, white)
        bb:paintCircle(x + w - 1, cy, r, white)
    end

    -- 3) dotted inner outline, as in the reference
    local dot = math.max(2, Screen:scaleBySize(2))
    local m = band + Screen:scaleBySize(6)
    for dx = x + m, x + w - m, dot * 3 do
        bb:paintRect(dx, y + m, dot, dot, GRAY)
        bb:paintRect(dx, y + h - m - dot, dot, dot, GRAY)
    end
    for dy = y + m, y + h - m, dot * 3 do
        bb:paintRect(x + m, dy, dot, dot, GRAY)
        bb:paintRect(x + w - m - dot, dy, dot, dot, GRAY)
    end

    -- 4) children (the actual content)
    FrameContainer.paintTo(self, bb, x, y)
end

------------------------------------------------------------------------
-- The popup widget
------------------------------------------------------------------------
local BookInfoCard = InputContainer:extend{
    ui = nil,
    tab = "synopsis",
}

function BookInfoCard:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    self.key_events = { Close = { { Device.input.group.Back } } }
    self:build()
end

-- ---- data helpers ----------------------------------------------------
function BookInfoCard:getData()
    local ui = self.ui
    local doc = ui.document
    local props = ui.doc_props or {}
    local settings = ui.doc_settings
    local summary = settings and settings:readSetting("summary") or {}
    local file = doc and doc.file or ""
    local ext = (file:match("%.([^%.]+)$") or ""):upper()
    local size = ""
    local lfs = require("libs/libkoreader-lfs")
    local attr = file ~= "" and lfs.attributes(file) or nil
    if attr and attr.size then size = string.format("%.2f MB", attr.size / 1048576) end

    local total = doc and doc:getPageCount() or 0
    local cur = ui:getCurrentPage() or 0
    local percent = settings and settings:readSetting("percent_finished")
        or (total > 0 and cur / total or 0)

    local status = summary.status
    local status_text = L.reading
    if status == "complete" then status_text = L.reading_done
    elseif status == "abandoned" then status_text = L.on_hold
    elseif percent == 0 then status_text = L.unread end

    local tags = {}
    if props.keywords and props.keywords ~= "" then
        for kw in util.gsplit(props.keywords, "[,;\n]+") do
            kw = util.trim(kw)
            if kw ~= "" then table.insert(tags, kw) end
        end
    end

    local last = os.date("%H:%M")
    if summary.modified and summary.modified ~= os.date("%Y-%m-%d") then
        last = summary.modified
    else
        last = L.today .. last
    end

    return {
        title = props.display_title or props.title or (file:match("([^/]+)$") or ""),
        author = props.authors or "",
        rating = tonumber(summary.rating) or 0,
        format = ext, size = size,
        status = status_text,
        tags = tags,
        percent = percent,
        cur = cur, total = total,
        last = last,
        description = util.htmlToPlainTextIfHtml(props.description or ""),
        note = summary.note or "",
        doc = doc,
    }
end

function BookInfoCard:getHighlightsText()
    local ann = self.ui.annotation and self.ui.annotation.annotations
    if not ann or #ann == 0 then return L.no_highlights end
    local out = {}
    for i, a in ipairs(ann) do
        local line = string.format("%d. [p.%s] %s", i,
            tostring(a.pageno or a.page or "?"), a.text or a.notes or "")
        table.insert(out, line)
    end
    return table.concat(out, "\n\n")
end

-- ---- small builders --------------------------------------------------
local function txt(s, size, bold, color)
    return TextWidget:new{
        text = s, face = Font:getFace(bold and "x_smalltfont" or "cfont", size),
        bold = bold, fgcolor = color or BLACK,
    }
end

local function stars(n)
    n = math.max(0, math.min(5, n))
    return string.rep("★", n) .. string.rep("☆", 5 - n)
end

function BookInfoCard:buildChip(label)
    return FrameContainer:new{
        bordersize = 0, radius = Size.radius.button,
        background = LIGHT, padding = Screen:scaleBySize(3),
        padding_left = Screen:scaleBySize(6), padding_right = Screen:scaleBySize(6),
        margin = 0,
        txt(label, 12, false, BLACK),
    }
end

function BookInfoCard:buildStat(label, value, w)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(54) },
        VerticalGroup:new{
            align = "center",
            txt(label, 14, false, GRAY),
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            txt(value, 18, true),
        },
    }
end

function BookInfoCard:buildTab(key, label, w)
    local active = (self.tab == key)
    local b = Button:new{
        text = label, width = w, max_width = w,
        text_font_size = 12, bordersize = 0,
        radius = Size.radius.button,
        background = active and GRAY or LIGHT,
        text_font_bold = active,
        callback = function()
            self.tab = key
            self:build()
            UIManager:setDirty(self, "ui")
        end,
    }
    if active then
        b.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
    end
    return b
end

-- ---- layout ----------------------------------------------------------
function BookInfoCard:build()
    local d = self:getData()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local card_w = math.floor(sw * 0.86)
    local card_h = math.floor(sh * 0.86)
    local pad = Screen:scaleBySize(26) -- leaves room for the stamp rim + dotted outline
    local inner_w = card_w - 2 * pad

    -- cover (left) ------------------------------------------------------
    local cover_w = math.floor(inner_w * 0.27)
    local cover_h = math.floor(cover_w * 1.45)
    local cover
    local ok, FMBI = pcall(require, "apps/filemanager/filemanagerbookinfo")
    local bb = ok and d.doc and FMBI:getCoverImage(d.doc) or nil
    if bb then
        cover = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            ImageWidget:new{ image = bb, image_disposable = true,
                width = cover_w, height = cover_h, scale_factor = 0 },
        }
    else
        cover = FrameContainer:new{
            bordersize = Size.border.thin, padding = 0, margin = 0,
            CenterContainer:new{ dimen = Geom:new{ w = cover_w, h = cover_h },
                txt(d.title:sub(1, 12), 14, true) },
        }
    end

    -- info column (right) -------------------------------------------------
    local info_w = inner_w - cover_w - Screen:scaleBySize(14)
    local title_row = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = d.title, face = Font:getFace("x_smalltfont", 22),
            bold = true, max_width = info_w - Screen:scaleBySize(70) },
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        self:buildChip(d.status),
    }
    local info = VerticalGroup:new{
        align = "left",
        title_row,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        LineWidget:new{ dimen = Geom:new{ w = info_w, h = Size.line.thin }, background = GRAY },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        txt(L.author .. d.author, 16, true),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        txt(L.my_rating .. stars(d.rating) .. "  " .. d.rating .. L.points, 15),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        HorizontalGroup:new{
            txt(d.format .. " · " .. d.size, 14),
            HorizontalSpan:new{ width = Screen:scaleBySize(18) },
            txt(L.source .. L.source_library, 14),
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
    }
    local chips = HorizontalGroup:new{}
    local used, maxw = 0, info_w
    for i, t in ipairs(d.tags) do
        local c = self:buildChip(t)
        local w = c:getSize().w + Screen:scaleBySize(5)
        if used + w > maxw - Screen:scaleBySize(40) then
            local extra = #d.tags - i + 1
            table.insert(chips, self:buildChip("+" .. extra))
            break
        end
        table.insert(chips, c)
        table.insert(chips, HorizontalSpan:new{ width = Screen:scaleBySize(5) })
        used = used + w
    end
    table.insert(info, chips)

    local header = HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = Screen:scaleBySize(14) },
        info,
    }

    -- stats row ---------------------------------------------------------
    local col_w = math.floor(inner_w / 3)
    local function vline()
        return LineWidget:new{ dimen = Geom:new{ w = Size.line.thin, h = Screen:scaleBySize(44) },
            background = LIGHT }
    end
    local stats = HorizontalGroup:new{
        align = "center",
        self:buildStat(L.progress, string.format("%.1f%%", d.percent * 100), col_w),
        vline(),
        self:buildStat(L.total_pages, d.cur .. " / " .. d.total, col_w - Size.line.thin),
        vline(),
        self:buildStat(L.last_read, d.last, col_w - Size.line.thin),
    }

    -- tabs --------------------------------------------------------------
    local tab_gap = Screen:scaleBySize(6)
    local avail_w = inner_w - 2 * tab_gap
    local side_w = math.floor(avail_w * 0.27)
    local mid_w = avail_w - 2 * side_w
    local tabs = HorizontalGroup:new{
        self:buildTab("synopsis", L.tab_synopsis, side_w),
        HorizontalSpan:new{ width = tab_gap },
        self:buildTab("highlights", L.tab_highlights, mid_w),
        HorizontalSpan:new{ width = tab_gap },
        self:buildTab("review", L.tab_review, side_w),
    }

    -- content box -------------------------------------------------------
    local content
    if self.tab == "synopsis" then
        content = d.description ~= "" and d.description or L.no_synopsis
    elseif self.tab == "highlights" then
        content = self:getHighlightsText()
    else
        content = d.note ~= "" and d.note or L.no_review
    end
    local header_h = math.max(header:getSize().h, cover_h)
    local used_h = header_h + stats:getSize().h + tabs:getSize().h
        + Size.line.thin + 4 * Screen:scaleBySize(10)
    local box_h = math.max(Screen:scaleBySize(60), card_h - 2 * pad - used_h)
    local box = FrameContainer:new{
        bordersize = Size.border.thin, color = GRAY,
        padding = Screen:scaleBySize(8), margin = 0,
        ScrollTextWidget:new{
            text = content, face = Font:getFace("cfont", 15),
            width = inner_w - Screen:scaleBySize(20),
            height = math.max(Screen:scaleBySize(30), box_h - Screen:scaleBySize(24)),
            dialog = self,
        },
    }

    local gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    local body = VerticalGroup:new{
        align = "left",
        header, gap,
        LineWidget:new{ dimen = Geom:new{ w = inner_w, h = Size.line.thin }, background = LIGHT },
        stats, gap,
        tabs, gap,
        box,
    }

    local card = StampFrame:new{
        width = card_w, height = card_h,
        padding = pad, margin = 0,
        body,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, card }
    self.card_dimen = nil
end

function BookInfoCard:onTapClose(arg, ges)
    local c = self[1] and self[1][1]
    if c and c.dimen and ges.pos:notIntersectWith(c.dimen) then
        UIManager:close(self)
        return true
    end
end

function BookInfoCard:onShow()
    self._closed = false
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    -- a second full repaint shortly after: when the card is opened from a
    -- gesture (e.g. long press), the first e-ink refresh can be swallowed
    UIManager:scheduleIn(0.2, function()
        if not self._closed then
            UIManager:setDirty(self, function() return "ui", self.dimen end)
        end
    end)
end

function BookInfoCard:onCloseWidget()
    self._closed = true
    UIManager:setDirty(nil, function() return "partial", self.dimen end)
end

function BookInfoCard:onClose()
    UIManager:close(self)
    return true
end

------------------------------------------------------------------------
-- Hook into ReaderUI: event, gesture action and menu entry
------------------------------------------------------------------------
Dispatcher:registerAction("show_book_info_card", {
    category = "none", event = "ShowBookInfoCard",
    title = L.action, reader = true,
})

local orig_init = ReaderUI.init
function ReaderUI:init()
    orig_init(self)

    local ui = self
    function ui:onShowBookInfoCard()
        -- let the gesture (e.g. long press) finish before drawing the card
        UIManager:scheduleIn(0.25, function()
            UIManager:show(BookInfoCard:new{ ui = ui })
        end)
        return true
    end

    if ui.menu and ui.menu.registerToMainMenu then
        local mod = { name = "book_info_card_patch" }
        function mod:addToMainMenu(menu_items)
            menu_items.book_info_card = {
                text = L.menu,
                callback = function() ui:handleEvent(require("ui/event"):new("ShowBookInfoCard")) end,
            }
        end
        ui.menu:registerToMainMenu(mod)
    end
end

-- make the entry appear in the document menu
local ok, order = pcall(require, "ui/elements/reader_menu_order")
if ok and order and order.typeset then
    table.insert(order.typeset, 1, "book_info_card")
end
