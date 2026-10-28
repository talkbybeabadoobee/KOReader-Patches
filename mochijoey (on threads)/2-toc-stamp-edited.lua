--[[
    2-toc-stamp-edited.lua  (KOReader user patch)

    Stamp-style Table of Contents.
      * perforated stamp frame with dotted inner outline
      * chapter names left, page numbers right, sub-chapters indented/lighter
      * current chapter highlighted and opened on its page
      * page navigation: buttons or swipe left / right
      * Settings: Navigation tab -> "ToC stamp colours"
        (edge colour and text colour, hex code + RGB sliders)

    Install: copy to koreader/patches/2-toc-stamp-edited.lua and restart.
    Remove the old 2-toc-stamp.lua so the two don't fight each other.
    (KOReader only loads patches whose filename starts with a number.)
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local ButtonTable     = require("ui/widget/buttontable")
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
local InputDialog     = require("ui/widget/inputdialog")
local LineWidget      = require("ui/widget/linewidget")
local ReaderToc       = require("apps/reader/modules/readertoc")
local Screen          = Device.screen
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local GRAY  = Blitbuffer.COLOR_DARK_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK

local L = {
    title    = "Table of contents",
    page     = "Page %d / %d",
    chapters = "%d chapters",
    chapter  = "1 chapter",
    untitled = "Untitled",
}

------------------------------------------------------------------------
-- Colour settings
------------------------------------------------------------------------
local SETTING  = "toc_stamp_colors"
local DEFAULTS = { edge = "#444444", text = "#000000" }

local function parseHex(hex)
    local r, g, b = tostring(hex or ""):match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then return nil end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function toHex(r, g, b)
    return string.format("#%02X%02X%02X", r, g, b)
end

local function getHex(key)
    local t = G_reader_settings:readSetting(SETTING) or {}
    return parseHex(t[key]) and t[key] or DEFAULTS[key]
end

local function setHex(key, hex)
    local t = G_reader_settings:readSetting(SETTING) or {}
    t[key] = hex
    G_reader_settings:saveSetting(SETTING, t)
end

local function color(r, g, b)
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

-- returns edge colour, text colour, and a softer text colour for secondary text
local function getColors()
    local er, eg, eb = parseHex(getHex("edge"))
    local tr, tg, tb = parseHex(getHex("text"))
    local function soft(v) return math.floor(v + (255 - v) * 0.45) end
    return color(er, eg, eb), color(tr, tg, tb), color(soft(tr), soft(tg), soft(tb))
end

------------------------------------------------------------------------
-- Stamp frame
------------------------------------------------------------------------
local StampFrame = FrameContainer:extend{
    bordersize = 0, padding = 0, margin = 0,
    background = nil, hole_r = nil, edge_color = GRAY,
}

function StampFrame:paintTo(bb, x, y)
    local sz = self:getSize()
    local w, h = sz.w, sz.h
    local r = self.hole_r or Screen:scaleBySize(5)
    local band = math.floor(r * 1.8)
    local step = r * 3
    local edge = self.edge_color

    bb:paintRect(x, y, w, h, edge)
    bb:paintRect(x + band, y + band, w - 2 * band, h - 2 * band, WHITE)

    for cx = x + r, x + w - r, step do
        bb:paintCircle(cx, y, r, WHITE)
        bb:paintCircle(cx, y + h - 1, r, WHITE)
    end
    for cy = y + r, y + h - r, step do
        bb:paintCircle(x, cy, r, WHITE)
        bb:paintCircle(x + w - 1, cy, r, WHITE)
    end

    local dot = math.max(2, Screen:scaleBySize(2))
    local m = band + Screen:scaleBySize(6)
    for dx = x + m, x + w - m, dot * 3 do
        bb:paintRect(dx, y + m, dot, dot, edge)
        bb:paintRect(dx, y + h - m - dot, dot, dot, edge)
    end
    for dy = y + m, y + h - m, dot * 3 do
        bb:paintRect(x + m, dy, dot, dot, edge)
        bb:paintRect(x + w - m - dot, dy, dot, dot, edge)
    end

    FrameContainer.paintTo(self, bb, x, y)
end

------------------------------------------------------------------------
-- One table-of-contents row
------------------------------------------------------------------------
local TocRow = InputContainer:extend{
    width = 0, height = 0,
    item = nil, depth = 0, current = false,
    text_color = BLACK, soft_color = GRAY,
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
    local face = Font:getFace("cfont", sub and 14 or 16)

    local num = TextWidget:new{
        text = tostring(self.item.page or ""), face = face,
        bold = self.current,
        fgcolor = self.current and self.text_color or self.soft_color,
    }
    local num_w = num:getSize().w
    local title_w = self.width - indent - num_w - 3 * pad
    local title = TextWidget:new{
        text = (self.item.title and self.item.title ~= "") and self.item.title or L.untitled,
        face = face, bold = self.current or not sub,
        fgcolor = sub and self.soft_color or self.text_color,
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
        LineWidget:new{ dimen = Geom:new{ w = self.width, h = Size.line.thin }, background = LIGHT },
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
    -- fixes the "cut off" display when opened from a gesture/button:
    -- tells UIManager this widget covers the whole screen, so the whole
    -- screen is repainted and refreshed instead of a partial region.
    covers_fullscreen = true,
}

function TocCard:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ w = self.dimen.w, h = self.dimen.h } } },
        Swipe      = { GestureRange:new{ ges = "swipe", range = Geom:new{ w = self.dimen.w, h = self.dimen.h } } },
    }
    self.key_events = { Close = { { Device.input.group.Back } } }

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
    self.footer_h = Screen:scaleBySize(46)
    local header_h = Screen:scaleBySize(64)
    local avail = self.card_h - 2 * self.pad - header_h - self.footer_h
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
    local edge_c, text_c, soft_c = getColors()

    -- header
    local props = self.ui.doc_props or {}
    local book = props.display_title or props.title or ""
    local count = #self.items == 1 and L.chapter or string.format(L.chapters, #self.items)
    local title = TextWidget:new{
        text = L.title, face = Font:getFace("x_smalltfont", 22), bold = true, fgcolor = text_c,
    }
    local count_w = TextWidget:new{ text = count, face = Font:getFace("cfont", 14), fgcolor = soft_c }
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
            fgcolor = soft_c, max_width = inner_w },
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        LineWidget:new{ dimen = Geom:new{ w = inner_w, h = Size.line.thin }, background = edge_c },
    }

    -- rows
    local rows = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    local last = math.min(#self.items, first + self.per_page - 1)
    for i = first, last do
        local it = self.items[i]
        table.insert(rows, TocRow:new{
            width = inner_w, height = self.row_h,
            item = it, depth = (it.depth or 1) - 1,
            current = (i == self.current_idx),
            text_color = text_c, soft_color = soft_c,
            callback = function() self:gotoItem(it) end,
        })
    end

    -- footer
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
        face = Font:getFace("cfont", 15), fgcolor = soft_c,
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

    -- assemble
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
        edge_color = edge_c,
        body,
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h }, card }
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
-- Colour picker: preview, hex code, R/G/B sliders
------------------------------------------------------------------------
local Slider = InputContainer:extend{ width = 0, height = 0, rgb = nil, idx = 1, on_change = nil }

function Slider:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.knob_r = math.floor(self.height / 2) - 2
    local range = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        SliderTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SliderPan = { GestureRange:new{ ges = "pan", range = self.dimen } },
    }
end

function Slider:setFromPos(ges)
    local r = self.knob_r
    local rel = (ges.pos.x - self.dimen.x - r) / (self.width - 2 * r)
    self.rgb[self.idx] = math.max(0, math.min(255, math.floor(rel * 255 + 0.5)))
    if self.on_change then self.on_change() end
    return true
end
Slider.onSliderTap = Slider.setFromPos
Slider.onSliderPan = Slider.setFromPos

function Slider:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = self.knob_r
    local cy = y + math.floor(self.height / 2)
    local track_w = self.width - 2 * r
    local pos = math.floor(track_w * self.rgb[self.idx] / 255)
    bb:paintRect(x + r, cy - 1, track_w, 3, LIGHT)
    bb:paintRect(x + r, cy - 1, pos, 3, BLACK)
    bb:paintCircle(x + r + pos, cy, r, BLACK)
    bb:paintCircle(x + r + pos, cy, r - 3, WHITE)
end

local Swatch = InputContainer:extend{ width = 0, height = 0, rgb = nil }
function Swatch:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function Swatch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.width, self.height, BLACK)
    bb:paintRect(x + 2, y + 2, self.width - 4, self.height - 4,
        color(self.rgb[1], self.rgb[2], self.rgb[3]))
end

local ColorPicker = InputContainer:extend{ title = "", hex = "#000000", default = "#000000", on_apply = nil }

function ColorPicker:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.key_events = { Close = { { Device.input.group.Back } } }
    local r, g, b = parseHex(self.hex)
    self.rgb = { r, g, b }

    local w = math.floor(Screen:getWidth() * 0.85)
    local pad = Screen:scaleBySize(16)
    local iw = w - 2 * pad
    local row_h = Screen:scaleBySize(44)
    local label_w = Screen:scaleBySize(28)

    self.hex_label = TextWidget:new{
        text = toHex(r, g, b), face = Font:getFace("cfont", 22), bold = true,
    }
    local swatch_h = Screen:scaleBySize(48)
    local top = HorizontalGroup:new{
        align = "center",
        Swatch:new{ width = Screen:scaleBySize(80), height = swatch_h, rgb = self.rgb },
        HorizontalSpan:new{ width = Screen:scaleBySize(16) },
        self.hex_label,
    }

    self.sliders = {}
    local sliders = VerticalGroup:new{ align = "left" }
    for i, name in ipairs({ "R", "G", "B" }) do
        local s = Slider:new{
            width = iw - label_w, height = row_h,
            rgb = self.rgb, idx = i,
            on_change = function() self:refresh() end,
        }
        table.insert(self.sliders, s)
        table.insert(sliders, HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = label_w, h = row_h },
                TextWidget:new{ text = name, face = Font:getFace("cfont", 18), bold = true },
            },
            s,
        })
    end

    local buttons = ButtonTable:new{
        width = iw,
        show_parent = self,
        buttons = {
            {
                { text = "Hex code…", callback = function() self:editHex() end },
                { text = "Default", callback = function()
                    local dr, dg, db = parseHex(self.default)
                    self.rgb[1], self.rgb[2], self.rgb[3] = dr, dg, db
                    self:refresh()
                end },
            },
            {
                { text = "Cancel", callback = function() UIManager:close(self) end },
                { text = "Apply", callback = function()
                    if self.on_apply then
                        self.on_apply(toHex(self.rgb[1], self.rgb[2], self.rgb[3]))
                    end
                    UIManager:close(self)
                end },
            },
        },
    }

    local frame = FrameContainer:new{
        background = WHITE, bordersize = Size.border.window,
        radius = Size.radius.window, padding = pad, margin = 0,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = self.title, face = Font:getFace("x_smalltfont", 20),
                bold = true, max_width = iw },
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            top,
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            sliders,
            VerticalSpan:new{ width = Screen:scaleBySize(10) },
            buttons,
        },
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h }, frame }
end

function ColorPicker:refresh()
    self.hex_label:setText(toHex(self.rgb[1], self.rgb[2], self.rgb[3]))
    UIManager:setDirty(self, "ui")
end

function ColorPicker:editHex()
    local dlg
    dlg = InputDialog:new{
        title = "Hex colour (e.g. #A0B1C2)",
        input = toHex(self.rgb[1], self.rgb[2], self.rgb[3]),
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
            { text = "OK", is_enter_default = true, callback = function()
                local r, g, b = parseHex(dlg:getInputText())
                if r then
                    self.rgb[1], self.rgb[2], self.rgb[3] = r, g, b
                    UIManager:close(dlg)
                    self:refresh()
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function ColorPicker:onClose()
    UIManager:close(self)
    return true
end

------------------------------------------------------------------------
-- Menu entry: Navigation tab -> "ToC stamp colours"
------------------------------------------------------------------------
local function pick(key, title)
    UIManager:show(ColorPicker:new{
        title = title, hex = getHex(key), default = DEFAULTS[key],
        on_apply = function(hex) setHex(key, hex) end,
    })
end

local orig_addToMainMenu = ReaderToc.addToMainMenu
function ReaderToc:addToMainMenu(menu_items)
    if orig_addToMainMenu then orig_addToMainMenu(self, menu_items) end
    menu_items.toc_stamp_settings = {
        text = "ToC stamp colours",
        sub_item_table = {
            { text = "Edge colour…", keep_menu_open = true,
              callback = function() pick("edge", "Stamp edge colour") end },
            { text = "Text colour…", keep_menu_open = true,
              callback = function() pick("text", "Text colour") end },
            { text = "Reset to defaults", keep_menu_open = true,
              callback = function()
                  G_reader_settings:delSetting(SETTING)
              end },
        },
    }
end

do
    local order = require("ui/elements/reader_menu_order")
    local list = order.navi or order.typeset
    if list then
        local at = #list + 1
        for i, v in ipairs(list) do
            if v == "table_of_contents" then at = i + 1 break end
        end
        table.insert(list, at, "toc_stamp_settings")
    end
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
        return orig_onShowToc(self)
    end
    local ui = self.ui
    -- Show on the next tick so any gesture/menu that triggered us has
    -- finished closing and repainting first.
    UIManager:nextTick(function()
        UIManager:show(TocCard:new{ ui = ui, toc = self, items = items })
        UIManager:setDirty("all", "ui")
    end)
    return true
end
