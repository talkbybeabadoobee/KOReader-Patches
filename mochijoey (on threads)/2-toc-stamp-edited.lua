--[[
    2-toc-stamp-edited.lua  (KOReader user patch)

    Stamp-style Table of Contents.
      * perforated stamp frame with dotted inner outline
      * chapter names left, page numbers right, sub-chapters indented/lighter
      * current chapter highlighted and opened on its page
      * page navigation: buttons or swipe left / right
      * Settings: Navigation tab -> "ToC stamp colours"
        (edge colour and text colour, colour wheel or hex code)

    Install: copy to koreader/patches/2-toc-stamp-edited.lua and restart.
    Remove the old 2-toc-stamp.lua so the two don't fight each other.
    (KOReader only loads patches whose filename starts with a number.)
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
-- Colour wheel (KOReader's ColorWheelWidget, bundled so it works on any
-- version of the patch; wrapped in a function to keep its locals private)
------------------------------------------------------------------------
local ColorWheelWidget = (function()
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font = require("ui/font")
local Screen = Device.screen

------------------------------------------------------------

local ColorWheelWidget = FocusManager:extend {
    title_text           = "Pick a color",
    width                = nil,
    width_factor         = 0.6,

    -- HSV values
    hue                  = 0, -- 0..360
    saturation           = 1,
    value                = 1,

    -- Whether to invert colors in night mode for accurate preview (default: true)
    invert_in_night_mode = true,

    -- Render the wheel at this fraction of full size, then scale up.
    -- Lower values are faster but produce more visible color banding.
    --
    -- | draw_scale | pixels rendered | speedup vs 1.0 |
    -- |------------|-----------------|----------------|
    -- | 1.0        | 100%            | 1x             |
    -- | 0.5        | 25%             | 4x             |
    -- | 0.25       | 6.25%           | 16x            |
    -- | 0.125      | 1.56%           | 64x            |
    draw_scale           = 0.5,

    cancel_text          = "Cancel",
    ok_text              = "Apply",

    callback             = nil,
    cancel_callback      = nil,
    close_callback       = nil,
}

------------------------------------------------------------
-- HSV → RGB
------------------------------------------------------------
local function hsvToRgb(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then
        r, g, b = c, x, 0
    elseif h < 120 then
        r, g, b = x, c, 0
    elseif h < 180 then
        r, g, b = 0, c, x
    elseif h < 240 then
        r, g, b = 0, x, c
    elseif h < 300 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    return
        math.floor((r + m) * 255 + 0.5),
        math.floor((g + m) * 255 + 0.5),
        math.floor((b + m) * 255 + 0.5)
end

------------------------------------------------------------
-- Per-radius lookup cache: hue + saturation for every pixel.
-- Built once per unique draw_radius, survives widget rebuilds.
-- Pixels outside the circle are marked with sat = -1.
--
-- Cap the cache at MAX_CACHE_ENTRIES entries (LRU eviction).
-- Without a bound the table grows forever if draw_scale or widget
-- size varies across the process lifetime.
------------------------------------------------------------
local _wheel_cache      = {}
local _wheel_cache_keys = {} -- insertion-order list for LRU eviction
local MAX_CACHE_ENTRIES = 8

local function getWheelCache(draw_radius)
    if _wheel_cache[draw_radius] then
        return _wheel_cache[draw_radius]
    end

    -- Evict oldest entry when the cache is full
    if #_wheel_cache_keys >= MAX_CACHE_ENTRIES then
        local oldest = table.remove(_wheel_cache_keys, 1)
        _wheel_cache[oldest] = nil
    end

    local r2    = draw_radius * draw_radius
    local hue_t = {}
    local sat_t = {}
    local idx   = 0

    for py = -draw_radius, draw_radius do
        for px = -draw_radius, draw_radius do
            idx = idx + 1
            local dist2 = px * px + py * py
            if dist2 <= r2 then
                hue_t[idx] = (math.deg(math.atan2(py, px)) + 360) % 360
                sat_t[idx] = math.sqrt(dist2) / draw_radius
            else
                sat_t[idx] = -1
            end
        end
    end

    local cache = { hue = hue_t, sat = sat_t }
    _wheel_cache[draw_radius] = cache
    table.insert(_wheel_cache_keys, draw_radius)
    return cache
end

------------------------------------------------------------
-- ColorWheel: draws the wheel into an off-screen buffer
-- and blits it to the screen. Redraws only when value changes;
-- hue/saturation changes only move the indicator dot.
------------------------------------------------------------
local ColorWheel = WidgetContainer:extend {
    radius               = 0,
    hue                  = 0,
    saturation           = 1,
    value                = 1,
    invert_in_night_mode = true,
    draw_scale           = 0.5,
    _needs_redraw        = true,
    _last_val            = nil,
    _cached_buf          = nil,
}

function ColorWheel:init()
    self.radius      = math.floor(self.dimen.w / 2)
    self.dimen       = Geom:new { x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }
    self.night_mode  = self.invert_in_night_mode and Screen.night_mode
    self.draw_radius = math.max(1, math.floor(self.radius * self.draw_scale))
    -- Pre-warm the cache so the first paint doesn't stutter
    getWheelCache(self.draw_radius)
    self._needs_redraw = true
end

function ColorWheel:free()
    if self._cached_buf then
        self._cached_buf:free()
        self._cached_buf = nil
    end
end

function ColorWheel:_renderToBuffer(x, y)
    local dr      = self.draw_radius
    local side    = dr * 2 + 1
    local buf     = Blitbuffer.new(side, side, Blitbuffer.TYPE_BBRGB32)
    local bgcolor = Screen.bb:getPixel(x - 1, y - 1)
    buf:paintRectRGB32(0, 0, side, side, bgcolor)

    local cache = getWheelCache(dr)
    local hue_t = cache.hue
    local sat_t = cache.sat
    local v     = self.value
    local nm    = self.night_mode
    local idx   = 0

    for py = -dr, dr do
        for px = -dr, dr do
            idx = idx + 1
            local s = sat_t[idx]
            if s >= 0 then
                local r, g, b = hsvToRgb(hue_t[idx], s, v)
                if nm then r, g, b = 255 - r, 255 - g, 255 - b end
                buf:setPixel(dr + 1 + px, dr + 1 + py,
                    Blitbuffer.ColorRGB32(r, g, b, 0xFF))
            end
        end
    end

    -- Free any previous buffer before replacing it
    if self._cached_buf then
        self._cached_buf:free()
    end
    self._cached_buf   = buf
    self._last_val     = v
    self._needs_redraw = false
end

function ColorWheel:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    if self._needs_redraw or self._last_val ~= self.value then
        self:_renderToBuffer(x, y)
    end

    local disp_side = self.radius * 2

    if self.draw_scale < 1.0 then
        -- Scale the small buffer up to display size, then free it
        local scaled = self._cached_buf:scale(disp_side, disp_side)
        bb:blitFrom(scaled, x, y, 0, 0, disp_side, disp_side)
        scaled:free()
    else
        bb:blitFrom(self._cached_buf, x, y, 0, 0, disp_side, disp_side)
    end

    -- Selection indicator at full display resolution (always crisp)
    local cx    = x + self.radius
    local cy    = y + self.radius
    local sel_x = cx + math.floor(math.cos(math.rad(self.hue)) * self.saturation * self.radius + 0.5)
    local sel_y = cy + math.floor(math.sin(math.rad(self.hue)) * self.saturation * self.radius + 0.5)

    for py = -4, 4 do
        for px = -4, 4 do
            local d = px * px + py * py
            if d <= 16 then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_WHITE)
            end
            if d <= 9 then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

function ColorWheel:updateColor(ges_pos)
    if not self.dimen then return false end

    local cx    = self.dimen.x + self.radius
    local cy    = self.dimen.y + self.radius
    local dx    = ges_pos.x - cx
    local dy    = ges_pos.y - cy
    local dist2 = dx * dx + dy * dy

    if dist2 > self.radius * self.radius then return false end

    self.hue        = (math.deg(math.atan2(dy, dx)) + 360) % 360
    self.saturation = math.min(1, math.sqrt(dist2) / self.radius)

    if self.update_callback then
        self.update_callback()
    end
    return true
end

------------------------------------------------------------
-- Live color preview — reads hue/sat/val at paint time,
-- no widget rebuild needed during drag.
------------------------------------------------------------
local function makeLivePreview(parent, preview_size)
    local LivePreview = WidgetContainer:extend {
        dimen = Geom:new { w = preview_size, h = preview_size },
    }
    function LivePreview:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local nm = parent.invert_in_night_mode
            and G_reader_settings:isTrue("night_mode")
        if nm then r, g, b = 255 - r, 255 - g, 255 - b end
        bb:paintRectRGB32(x, y, self.dimen.w, self.dimen.h,
            Blitbuffer.ColorRGB32(r, g, b, 0xFF))
    end

    return LivePreview:new {}
end

------------------------------------------------------------
-- Live hex label — reads hue/sat/val at paint time.
------------------------------------------------------------
local function makeLiveHexLabel(parent, face)
    local LiveHex = WidgetContainer:extend {
        dimen = Geom:new { w = 0, h = 0 },
        _last_text = "",
        _tw = nil,
    }
    function LiveHex:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local txt = string.format("#%02X%02X%02X", r, g, b)
        -- Rebuild TextWidget only when the hex value actually changes
        if txt ~= self._last_text or not self._tw then
            if self._tw then self._tw:free() end
            self._tw = TextWidget:new { text = txt, face = face }
            self._last_text = txt
            local sz = self._tw:getSize()
            self.dimen.w = sz.w
            self.dimen.h = sz.h
        end
        self._tw:paintTo(bb, x, y)
    end

    return LiveHex:new {}
end

------------------------------------------------------------
-- Main dialog
------------------------------------------------------------
function ColorWheelWidget:init()
    self.screen_width     = Screen:getWidth()
    self.screen_height    = Screen:getHeight()
    self.medium_font_face = Font:getFace("ffont")
    self.hex_font_face    = Font:getFace("infofont", 20)

    if not self.width then
        self.width = math.floor(
            math.min(self.screen_width, self.screen_height) * self.width_factor
        )
    end

    self.inner_width  = self.width - 2 * Size.padding.large
    self.button_width = math.floor(self.inner_width / 4)

    if Device:isTouchDevice() then
        self.ges_events = {
            TapColorWheel = {
                GestureRange:new {
                    ges   = "tap",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanColorWheel = {
                GestureRange:new {
                    ges   = "pan",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanReleaseColorWheel = {
                GestureRange:new {
                    ges   = "pan_release",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
        }
    end

    self:update()
end

-- Free all owned FFI/widget resources before rebuilding the widget tree.
function ColorWheelWidget:_freeChildren()
    if self.color_wheel then
        self.color_wheel:free()
        self.color_wheel = nil
    end
    if self._live_hex then
        self._live_hex:free()
        self._live_hex = nil
    end
end

function ColorWheelWidget:onCloseWidget()
    self:_freeChildren()
end

function ColorWheelWidget:update()
    -- Free previous ColorWheel (and its _cached_buf) and LiveHex
    -- before creating new ones, so no orphaned FFI buffers are left behind.
    self:_freeChildren()

    local wheel_size    = self.width - 2 * Size.padding.large
    local preview_size  = math.floor(wheel_size / 4)

    self.color_wheel    = ColorWheel:new {
        dimen                = Geom:new { w = wheel_size, h = wheel_size },
        hue                  = self.hue,
        saturation           = self.saturation,
        value                = self.value,
        invert_in_night_mode = self.invert_in_night_mode,
        draw_scale           = self.draw_scale,
        -- update_callback is NOT set here — pan bypasses update() entirely
    }

    -- Live widgets read parent's hue/sat/val at paint time; no rebuild on drag
    self._live_preview  = makeLivePreview(self, preview_size)
    self._live_hex      = makeLiveHexLabel(self, self.hex_font_face)

    local title_bar     = TitleBar:new {
        width            = self.width,
        title            = self.title_text,
        with_bottom_line = true,
        close_button     = true,
        close_callback   = function() self:onCancel() end,
        show_parent      = self,
    }

    local value_minus   = Button:new {
        text        = "−",
        enabled     = self.value > 0,
        width       = self.button_width,
        show_parent = self,
        callback    = function()
            self.value = math.max(0, self.value - 0.1)
            -- Brightness change requires wheel re-render: use full update()
            self.color_wheel._needs_redraw = true
            self:update()
        end,
    }

    local value_plus    = Button:new {
        text        = "＋",
        enabled     = self.value < 1,
        width       = self.button_width,
        show_parent = self,
        callback    = function()
            self.value = math.min(1, self.value + 0.1)
            self.color_wheel._needs_redraw = true
            self:update()
        end,
    }

    local value_label   = TextWidget:new {
        text = string.format("Brightness: %d%%", math.floor(self.value * 100)),
        face = self.medium_font_face,
    }

    local value_group   = HorizontalGroup:new {
        align = "center",
        value_minus,
        HorizontalSpan:new { width = Size.padding.large },
        value_label,
        HorizontalSpan:new { width = Size.padding.large },
        value_plus,
    }

    local preview_group = HorizontalGroup:new {
        align = "center",
        FrameContainer:new {
            bordersize = Size.border.thick,
            margin     = 0,
            padding    = 0,
            self._live_preview,
        },
        HorizontalSpan:new { width = Size.padding.large },
        self._live_hex,
    }

    local cancel_button = Button:new {
        text        = self.cancel_text,
        width       = math.floor(self.width / 2) - Size.padding.large * 2,
        show_parent = self,
        callback    = function() self:onCancel() end,
    }

    local ok_button     = Button:new {
        text        = self.ok_text,
        width       = math.floor(self.width / 2) - Size.padding.large * 2,
        show_parent = self,
        callback    = function() self:onApply() end,
    }

    local button_row    = HorizontalGroup:new {
        align = "center",
        cancel_button,
        HorizontalSpan:new { width = Size.padding.large },
        ok_button,
    }

    local vgroup        = VerticalGroup:new {
        align = "center",
        title_bar,
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = value_label:getSize().h + Size.padding.default,
            },
            value_group,
        },
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = wheel_size + Size.padding.large * 2,
            },
            self.color_wheel,
        },
        VerticalSpan:new { width = Size.padding.large },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = preview_size + Size.padding.default,
            },
            preview_group,
        },
        VerticalSpan:new { width = Size.padding.large * 2 },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.width,
                h = Size.item.height_default,
            },
            button_row,
        },
        VerticalSpan:new { width = Size.padding.default },
    }

    self.frame          = FrameContainer:new {
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    self.movable        = MovableContainer:new { self.frame }

    self[1]             = CenterContainer:new {
        dimen = Geom:new {
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        self.movable,
    }

    UIManager:setDirty(self, "ui")
end

------------------------------------------------------------
-- Gesture handlers
------------------------------------------------------------

-- Tap: update hue/sat.
-- Close on tap outside the dialog.
function ColorWheelWidget:onTapColorWheel(arg, ges_ev)
    if not self.color_wheel.dimen or not self.frame.dimen then return true end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation
            UIManager:setDirty(self, "ui")
        end
        return true
    elseif not ges_ev.pos:intersectWith(self.frame.dimen) then
        self:onCancel()
        return true
    end
    return false
end

-- Pan: sync values + fast-dirty + periodic ui-dirty only the wheel region.
function ColorWheelWidget:onPanColorWheel(arg, ges_ev)
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation

            self._pan_tick  = (self._pan_tick or 0) + 1
            local mode      = (self._pan_tick % 8 == 0) and "ui" or "fast"

            UIManager:setDirty(self, mode)
        end
        return true
    end
    return false
end

-- Pan release: one clean "ui" refresh to fix A2 ghosting,
-- plus a full update() so the hex label and preview sync up.
function ColorWheelWidget:onPanReleaseColorWheel(arg, ges_ev)
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        self:update() -- rebuilds widget tree with final hue/sat; does "ui" dirty
        return true
    end
    return false
end

function ColorWheelWidget:onApply()
    UIManager:close(self)
    if self.callback then
        local r, g, b = hsvToRgb(self.hue, self.saturation, self.value)
        self.callback(string.format("#%02X%02X%02X", r, g, b))
    end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onCancel()
    UIManager:close(self)
    if self.cancel_callback then self.cancel_callback() end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onShow()
    UIManager:setDirty(self, "ui", nil, true)
    return true
end

return ColorWheelWidget

end)()

local function rgbToHsv(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    local h = 0
    if d > 0 then
        if mx == r then h = 60 * (((g - b) / d) % 6)
        elseif mx == g then h = 60 * ((b - r) / d + 2)
        else h = 60 * ((r - g) / d + 4) end
    end
    return h, (mx == 0) and 0 or d / mx, mx
end

local function pickWheel(key, title)
    local h, s, v = rgbToHsv(parseHex(getHex(key)))
    UIManager:show(ColorWheelWidget:new{
        title_text = title, hue = h, saturation = s, value = v,
        callback = function(hex) setHex(key, hex) end,
    })
end

local function pickHex(key, title)
    local dlg
    dlg = InputDialog:new{
        title = title .. " (e.g. #A0B1C2)",
        input = getHex(key),
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
            { text = "OK", is_enter_default = true, callback = function()
                local r, g, b = parseHex(dlg:getInputText())
                if r then
                    setHex(key, toHex(r, g, b))
                    UIManager:close(dlg)
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

------------------------------------------------------------------------
-- Menu entry: Navigation tab -> "ToC stamp colours"
------------------------------------------------------------------------
local orig_addToMainMenu = ReaderToc.addToMainMenu
function ReaderToc:addToMainMenu(menu_items)
    if orig_addToMainMenu then orig_addToMainMenu(self, menu_items) end
    menu_items.toc_stamp_settings = {
        text = "ToC stamp colours",
        sub_item_table = {
            { text = "Edge colour (wheel)…", keep_menu_open = true,
              callback = function() pickWheel("edge", "Stamp edge colour") end },
            { text = "Edge colour (hex code)…", keep_menu_open = true,
              callback = function() pickHex("edge", "Edge hex") end },
            { text = "Text colour (wheel)…", keep_menu_open = true,
              callback = function() pickWheel("text", "Text colour") end },
            { text = "Text colour (hex code)…", keep_menu_open = true,
              callback = function() pickHex("text", "Text hex") end },
            { text = "Reset to defaults", keep_menu_open = true,
              callback = function() G_reader_settings:delSetting(SETTING) end },
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
