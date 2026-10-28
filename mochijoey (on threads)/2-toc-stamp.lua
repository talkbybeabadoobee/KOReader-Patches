--[[
    2-toc-stamp-original.lua  (KOReader user patch)

    Restyles the Table of Contents to match the stamp-style book info card:
      * perforated stamp frame with dotted inner outline
      * English title ("Table of contents") with the book title underneath
      * chapter names on the left, page numbers on the right
      * sub-chapters indented and in a lighter weight
      * the chapter you are currently in is highlighted and shown first
      * page navigation: ‹ Page 2 / 7 ›  (or swipe left / right)

    Install:  copy to  koreader/patches/2-toc-stamp.lua  and restart KOReader.
    Use:      open the Table of contents the normal way (top menu -> ToC icon,
              or your existing ToC gesture). The built-in action is replaced,
              so no new gesture assignment is needed.
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Event           = require("ui/event")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ReaderToc       = require("apps/reader/modules/readertoc")
local Screen          = Device.screen
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local BLACK, GRAY, LIGHT = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_LIGHT_GRAY
local WHITE = Blitbuffer.COLOR_WHITE

------------------------------------------------------------------------
-- English labels
------------------------------------------------------------------------
local L = {
    title    = "Table of contents",
    page     = "Page %d / %d",
    chapters = "%d chapters",
    chapter  = "1 chapter",
    untitled = "Untitled",
}

------------------------------------------------------------------------
-- Stamp frame (same design as the book info card)
------------------------------------------------------------------------
local StampFrame = FrameContainer:extend{
    bordersize = 0, padding = 0, margin = 0,
    background = nil, hole_r = nil,
}

function StampFrame:paintTo(bb, x, y)
    local sz = self:getSize()
    local w, h = sz.w, sz.h
    local r = self.hole_r or Screen:scaleBySize(5)
    local band = math.floor(r * 1.8)
    local step = r * 3

    -- 1) rim + white interior
    bb:paintRect(x, y, w, h, GRAY)
    bb:paintRect(x + band, y + band, w - 2 * band, h - 2 * band, WHITE)

    -- 2) perforation
    for cx = x + r, x + w - r, step do
        bb:paintCircle(cx, y, r, WHITE)
        bb:paintCircle(cx, y + h - 1, r, WHITE)
    end
    for cy = y + r, y + h - r, step do
        bb:paintCircle(x, cy, r, WHITE)
        bb:paintCircle(x + w - 1, cy, r, WHITE)
    end

    -- 3) dotted inner outline
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

    -- 4) content
    FrameContainer.paintTo(self, bb, x, y)
end

------------------------------------------------------------------------
-- One table-of-contents row
------------------------------------------------------------------------
local TocRow = InputContainer:extend{
    width = 0, height = 0,
    item = nil, depth = 0, current = false,
    callback = nil,
}

function TocRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height + Size.line.thin }
    self.ges_events = {
        TapRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }

    local pad = Screen:scaleBySize(8)
    local indent = Screen:scaleBySize(16) * math.min(self.depth, 4)
    local sub = self.depth > 0
    local fsize = sub and 14 or 16
    local face = Font:getFace("cfont", fsize)

    local num = TextWidget:new{
        text = tostring(self.item.page or ""), face = face,
        bold = self.current, fgcolor = self.current and BLACK or GRAY,
    }
    local num_w = num:getSize().w
    local title_w = self.width - indent - num_w - 3 * pad
    local title = TextWidget:new{
        text = (self.item.title and self.item.title ~= "") and self.item.title or L.untitled,
        face = face, bold = self.current or not sub,
        fgcolor = sub and GRAY or BLACK,
        max_width = title_w,
    }
    local fill = self.width - indent - title:getSize().w - num_w - 3 * pad
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = pad + indent },
        title,
        HorizontalSpan:new{ width = math.max(fill, 0) },
        num,
        HorizontalSpan:new{ width = pad },
    }

    local frame = FrameContainer:new{
        width = self.width, height = self.height,
        bordersize = 0, padding = 0, margin = 0,
        background = self.current and LIGHT or nil,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            row,
        },
    }
    self[1] = VerticalGroup:new{
        align = "left",
        frame,
        LineWidget:new{ dimen = Geom:new{ w = self.width, h = Size.line.thin },
            background = LIGHT },
    }
end

function TocRow:onTapRow()
    if self.callback then self.callback() end
    return true
end

------------------------------------------------------------------------
-- The ToC card
------------------------------------------------------------------------
local TocCard = InputContainer:extend{
    ui = nil, toc = nil, items = nil, page = 1,
}

function TocCard:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe      = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = { Close = { { Device.input.group.Back } } }

    -- locate current chapter
    local cur_page = self.ui:getCurrentPage() or 1
    self.current_idx = nil
    for i, it in ipairs(self.items) do
        if it.page and it.page <= cur_page then self.current_idx = i else break end
    end

    self.row_h = Screen:scaleBySize(38)
    self:computeLayout()
    if self.current_idx then
        self.page = math.ceil(self.current_idx / self.per_page)
    end
    self:build()
end

function TocCard:computeLayout()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.card_w = math.floor(sw * 0.90)
    self.card_h = math.floor(sh * 0.84)
    self.pad = Screen:scaleBySize(30)
    self.inner_w = self.card_w - 2 * self.pad
    self.header_h = Screen:scaleBySize(64)
    self.footer_h = Screen:scaleBySize(46)
    local avail = self.card_h - 2 * self.pad - self.header_h - self.footer_h
    self.per_page = math.max(3, math.floor(avail / (self.row_h + Size.line.thin)))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
end

function TocCard:gotoItem(item)
    UIManager:close(self)
    local ui = self.ui
    if ui.link and ui.link.addCurrentLocationToStack then
        ui.link:addCurrentLocationToStack()
    end
    if item.xpointer then
        ui:handleEvent(Event:new("GotoXPointer", item.xpointer, item.xpointer))
    else
        ui:handleEvent(Event:new("GotoPage", item.page))
    end
end

function TocCard:changePage(delta)
    local np = math.max(1, math.min(self.pages, self.page + delta))
    if np ~= self.page then
        self.page = np
        self:build()
        UIManager:setDirty(self, "ui")
    end
end

function TocCard:build()
    local inner_w = self.inner_w

    -- header -----------------------------------------------------------
    local props = self.ui.doc_props or {}
    local book = props.display_title or props.title or ""
    local count = #self.items == 1 and L.chapter or string.format(L.chapters, #self.items)
    local title = TextWidget:new{
        text = L.title, face = Font:getFace("x_smalltfont", 22), bold = true,
    }
    local count_w = TextWidget:new{ text = count, face = Font:getFace("cfont", 14), fgcolor = GRAY }
    local head_fill = inner_w - title:getSize().w - count_w:getSize().w
    local header = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "bottom",
            title,
            HorizontalSpan:new{ width = math.max(head_fill, 0) },
            count_w,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        TextWidget:new{ text = book, face = Font:getFace("cfont", 14),
            fgcolor = GRAY, max_width = inner_w },
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        LineWidget:new{ dimen = Geom:new{ w = inner_w, h = Size.line.thin }, background = GRAY },
    }

    -- rows -------------------------------------------------------------
    local rows = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.items, first + self.per_page - 1)
    for i = first, last do
        local it = self.items[i]
        table.insert(rows, TocRow:new{
            width = inner_w, height = self.row_h,
            item = it, depth = (it.depth or 1) - 1,
            current = (i == self.current_idx),
            callback = function() self:gotoItem(it) end,
        })
    end

    -- footer -----------------------------------------------------------
    local bw = Screen:scaleBySize(56)
    local function nav(label, delta, enabled)
        return Button:new{
            text = label, width = bw, bordersize = Size.border.thin,
            radius = Size.radius.button, text_font_size = 20,
            enabled = enabled, background = WHITE,
            callback = function() self:changePage(delta) end,
        }
    end
    local label = TextWidget:new{
        text = string.format(L.page, self.page, self.pages),
        face = Font:getFace("cfont", 15), fgcolor = GRAY,
    }
    local label_slot = inner_w - 2 * bw - 2 * Screen:scaleBySize(8)
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = self.footer_h },
        HorizontalGroup:new{
            align = "center",
            nav("‹", -1, self.page > 1),
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            CenterContainer:new{ dimen = Geom:new{ w = label_slot, h = self.footer_h }, label },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            nav("›", 1, self.page < self.pages),
        },
    }

    -- assemble: header on top, footer pinned to the bottom --------------
    local body_h = self.card_h - 2 * self.pad
    local rows_h = body_h - header:getSize().h - self.footer_h
    local body = VerticalGroup:new{
        align = "left",
        header,
        FrameContainer:new{
            width = inner_w, height = rows_h,
            bordersize = 0, padding = 0, margin = 0, rows,
        },
        footer,
    }

    local card = StampFrame:new{
        width = self.card_w, height = self.card_h,
        padding = self.pad, margin = 0,
        body,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, card }
end

function TocCard:onTapOutside(arg, ges)
    local c = self[1] and self[1][1]
    if c and c.dimen and ges.pos:notIntersectWith(c.dimen) then
        UIManager:close(self)
        return true
    end
end

function TocCard:onSwipe(arg, ges)
    local dir = ges.direction
    if dir == "west" then
        self:changePage(1)
        return true
    elseif dir == "east" then
        self:changePage(-1)
        return true
    end
end

function TocCard:onClose()
    UIManager:close(self)
    return true
end

function TocCard:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

------------------------------------------------------------------------
-- Replace the built-in "show table of contents"
------------------------------------------------------------------------
local orig_onShowToc = ReaderToc.onShowToc

function ReaderToc:onShowToc()
    local items
    if self.getFullToc then
        items = self:getFullToc()
    else
        if not self.toc then self:fillToc() end
        items = self.toc
    end
    if not items or #items == 0 then
        return orig_onShowToc(self) -- built-in "no table of contents" message
    end
    UIManager:show(TocCard:new{ ui = self.ui, toc = self, items = items })
    return true
end
