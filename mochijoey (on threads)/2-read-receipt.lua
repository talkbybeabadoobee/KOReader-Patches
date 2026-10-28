local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Screen = Device.screen

-- Safely load the bit library
local ok_bit, bit = pcall(require, "bit")
if not ok_bit then
    ok_bit, bit = pcall(require, "bit32")
    if not ok_bit then
        bit = nil
        logger.warn("read-receipt: bit library not found, using fallback")
    end
end

-- ---------------------------------------------------------------- geometry --
local BASE_W, BASE_H = 851.38, 1506.06
local current_scale = 1

local R = 35
local NOTCH_Y = 967.85
local NOTCH_DX = 3
local SCALLOPS = 8

local K_CN, K_LA = 0.792, 0.7625

local COL = {
    K  = Blitbuffer.COLOR_BLACK,
    COVER = Blitbuffer.Color8(0x91),
    TRACK = Blitbuffer.Color8(0xC7),
    FILL = Blitbuffer.Color8(0x4C),
}

local BARS = {{38.3,2.15},{47.9,5.75},{55.6,3.8},{61.35,1.9},{69,1.95},{74.8,7.65},{86.3,1.9},{90.15,7.65},{101.65,1.95},{107.4,1.95},{111.25,1.95},{120.85,3.85},{126.6,1.95},{132.15,3.85},{143.65,1.95},{147.5,1.9},{153.25,3.85},{159,3.85},{166.7,3.85},{174.4,5.75},{182.05,1.95},{189.75,3.85},{195.5,1.9},{203.2,7.65},{212.8,1.9},{216.6,3.85},{227.9,1.9},{231.75,1.9},{237.5,1.9},{243.25,3.85},{249,1.95},{258.6,3.85},{264.4,3.8},{272.05,3.85},{279.75,7.65},{289.35,5.75},{297,1.95},{300.85,1.95},{306.6,1.95},{310.45,3.6},{321.75,1.9},{331.35,1.9},{337.1,3.85},{342.85,1.95},{346.7,3.85},{354.4,1.9},{364,3.8},{369.75,3.85},{377.4,3.85},{385.1,1.9},{394.7,3.85},{400.2,1.95},{406,1.9},{411.75,7.65},{421.35,1.9},{427.1,3.85},{432.85,3.85},{440.55,3.85},{448.2,1.95},{455.9,7.7},{465.5,1.9},{469.35,3.85},{480.85,1.95},{484.7,1.9},{490.2,3.85},{496,3.8},{503.65,3.85},{511.35,1.9},{515.2,1.9},{522.85,3.85},{532.45,1.95},{538.2,7.7},{549.75,1.9},{553.6,1.9},{559.35,3.85},{565.1,1.9},{574.7,3.6},{580.2,3.85},{587.9,3.85},{595.6,3.8},{603.25,5.75},{612.85,1.95},{616.7,5.75},{624.4,1.9},{630.15,3.85},{637.8,3.85},{643.6,3.8},{651.25,3.85},{658.95,1.9},{662.8,5.5},{670.2,7.7},{679.8,3.85},{687.5,1.9},{693.25,5.75},{700.95,5.75},{710.55,1.9},{716.3,3.85},{722.05,5.75},{729.75,1.9},{733.6,7.65},{743.2,1.9},{752.8,3.8},{760.2,1.95},{764.05,1.95},{769.8,1.95},{773.65,7.7},{785.2,3.8},{794.8,5.75},{802.45,1.95},{806.3,3.85}}
local BARCODE_Y, BARCODE_H = 1307.3, 47.8

-- Star rating configuration
local STAR_COUNT = 5
local STAR_SIZE = 50
local STAR_GAP = 2
local STAR_X = 36.92
local STAR_TOP = 631.18
local RATING_TEXT_GAP = 8
local RATING_TEXT_SIZE = 30
local RATING_LABELS = {
    "Terrible", "Very Poor", "Subpar", "Below Average", "Average",
    "Decent", "Good", "Very Good", "Excellent", "Perfect",
}
local RATING_DEFAULT_TEXT = "Rate"
local STAR_TOUCH_EXPAND = 20
local MIN_STAR_SIZE = 8
local RATING_STEP = 0.5

local function normalizeRating(value)
    local rating = tonumber(value) or 0
    rating = math.floor(rating / RATING_STEP + 0.5) * RATING_STEP
    return math.max(0, math.min(STAR_COUNT, rating))
end

-- Text layout data
local ITEMS = {
  {x=759.55,top=132.58,f="C",size=22,ls=0,c="K",t="STATUS"},
  {x=815.5,top=207,f="C",size=38,ls=0,c="K",t="READING",key="status",right_align=true},
  {x=0,top=66.64,f="L",size=25,ls=-0.1,c="K",t="NO. D20260906",key="no",no_align=true},
  {x=35.04,top=89.3,f="C",size=25,ls=0,c="K",t="DAILY READING TICKET"},
  {x=34.12,top=136,f="C",size=72,ls=0.03,c="K",t="READ RECEIPT"},
  {x=34.36,top=232.58,f="C",size=25,ls=0,c="K",t=""},
  {x=193,top=232.92,f="L",size=25,ls=0,c="K",t=""},
  {x=214.52,top=232.2,f="L",size=25,ls=-0.73,c="K",t="TODAY"},
  {x=287.64,top=236.2,f="L",size=25,ls=0,c="K",t="’"},
  {x=304.32,top=232.68,f="L",size=25,ls=0,c="K",t="S "},
  {x=321.6,top=232.2,f="L",size=25,ls=-0.26,c="K",t="READING "},
  {x=434.64,top=232.2,f="L",size=25,ls=-0.42,c="K",t="TRAIL"},
  {x=70.08, top=346.35, f="C", size=20, ls=0, c="K", t="START"},
  {x=0,    top=340,   f="L", size=32,   ls=0,    c="K", t="·", dot_center=true},
  {x=169.37,top=346.24, f="L", size=20, ls=-0.2, c="K", t="DATE"},
  {x=319.24,top=344.75,f="C",size=20,ls=0,c="K",t="DAY OF"},
  {x=0,top=340,f="L",size=32,ls=0,c="K",t="·",dot_center=true},
  {x=418.24,top=346.24,f="L",size=20,ls=-0.51,c="K",t="WEEK"},
  {x=583,top=344.51,f="C",size=20,ls=0,c="K",t="TODAY'S"},
  {x=0,top=340,f="L",size=32,ls=0,c="K",t="·",dot_center=true},
  {x=683.41,top=346.24,f="L",size=20,ls=0.18,c="K",t="DATE"},
  {x=70.08,top=371.53,f="L",size=36,ls=-0.61,c="K",key="start_date"},
  {x=317.76,top=371.69,f="L",size=36,ls=-0.5,c="K",key="weekday_full"},
  {x=582.24,top=371.53,f="L",size=36,ls=-0.61,c="K",key="date"},
  {x=33.6,top=489.58,f="C",size=30,ls=0,c="K",t="CURRENTLY READING"},
  {x=33.6,top=536.78,f="L",size=38,ls=-0.07,c="K",key="title",maxw=460},
  {x=33.6,top=583.98,f="L",size=30,ls=0.2,c="K",key="author",prefix="Author: ",maxw=400},
  {x=33.6,top=716.58,f="C",size=30,ls=0.71,c="K",key="chapter",maxw=460},
  {x=33.6,top=763.78,f="C",size=30,ls=0.2,c="K",key="est_time",prefix="Est. time left: ",maxw=500},
  {x=33.6,top=858.18,f="L",size=28,ls=-0.11,c="K",key="pages"},
  {x=148.72,top=857.52,f="C",size=28,ls=0,c="K",t="pg",follow=10.8},
  {x=457.2,top=858.18,f="L",size=28,ls=-0.21,c="K",t="15%",key="pct", right_align=true},
  {x=39.12,top=1001.4,f="C",size=36,ls=-0.39,c="K",t="TODAY'S",sum_anchor=true},
  {x=200.64,top=1001.78,f="L",size=36,ls=-0.2,c="K",t="SUMMARY"},
  {cx=218.5,top=1077.44,f="C",size=26,ls=0,c="K",t="TODAY"},
  {cx=630,top=1076.96,f="C",size=26,ls=0,c="K",t="TOTAL"},
  {x=35.08,top=1131,f="L",size=26,ls=-0.08,c="K",t="PAGES READ"},
  {x=35.08,top=1202.29,f="L",size=40,ls=-0.35,c="K",key="d_pages"},
  {x=86.2,top=1200.61,f="C",size=40,ls=0,c="K",t="pg",follow=2.3},
  {x=221.08,top=1131,f="L",size=26,ls=-0.02,c="K",t="READING TIME"},
  {x=221.08,top=1201.65,f="L",size=40,ls=0.32,c="K",key="d_time"},
  {x=444.52,top=1131,f="L",size=26,ls=-0.11,c="K",t="PAGES READ"},
  {x=444.52,top=1203.01,f="L",size=40,ls=-0.35,c="K",key="total_pages"},
  {x=495.4,top=1201.33,f="C",size=40,ls=0,c="K",t="pg",follow=2.1},
  {x=634.36,top=1131,f="L",size=26,ls=-0.04,c="K",t="READING TIME"},
  {x=634.36,top=1202.37,f="L",size=40,ls=0.32,c="K",key="total_time"},
  {x=0,top=1396.2,f="C",size=20,ls=0.03,c="K",key="id",prefix="READING LOG · ",maxw=600,center=true},
}

-- ------------------------------------------------------------- primitives --
local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local function px(v) return floor(v + 0.5) end

local function rect(bb, ox, oy, x, y, w, h, c)
    local s = current_scale
    w, h = px(w * s), px(h * s)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    bb:paintRect(ox + px(x * s), oy + px(y * s), w, h, c)
end

local function disc(bb, ox, oy, cx, cy, r, c)
    local s = current_scale
    local scaled_r = r * s
    for dy = -ceil(scaled_r), ceil(scaled_r) do
        local hw = scaled_r * scaled_r - dy * dy
        if hw > 0 then
            hw = sqrt(hw)
            rect(bb, ox, oy, cx - hw/s, cy + dy/s, hw*2/s, 1/s, c)
        end
    end
end

local function dottedH(bb, ox, oy, x1, x2, y, dot_radius, gap, offset, c)
    local s = current_scale
    local period = (dot_radius * 2 + gap) * s
    local t = x1 * s - (offset or 0) * s
    local x1_s = x1 * s
    local x2_s = x2 * s
    local y_s = y * s
    local dot_r_s = dot_radius * s
    while t < x2_s do
        local cx = t + dot_r_s
        if cx >= x1_s and cx <= x2_s then
            disc(bb, ox, oy, cx/s, y, dot_radius, c)
        end
        t = t + period
    end
end

local function scallopCentres()
    local t = {}
    for k = 0, SCALLOPS do t[#t + 1] = k * (BASE_W / SCALLOPS) end
    return t
end

local function subtract(spans, a, b)
    local out = {}
    for _, s in ipairs(spans) do
        if b <= s[1] or a >= s[2] then
            out[#out + 1] = s
        else
            if a > s[1] then out[#out + 1] = { s[1], a } end
            if b < s[2] then out[#out + 1] = { b, s[2] } end
        end
    end
    return out
end

local CX = scallopCentres()

local function rowSpans(y)
    local spans = { { 0, BASE_W } }
    if y < R then
        local hw = sqrt(R * R - y * y)
        for _, cx in ipairs(CX) do spans = subtract(spans, cx - hw, cx + hw) end
    end
    local dyb = BASE_H - y
    if dyb < R then
        local hw = sqrt(R * R - dyb * dyb)
        for _, cx in ipairs(CX) do spans = subtract(spans, cx - hw, cx + hw) end
    end
    local dn = abs(y - NOTCH_Y)
    if dn < R then
        local hw = sqrt(R * R - dn * dn)
        spans = subtract(spans, -1e6, -NOTCH_DX + hw)
        spans = subtract(spans, BASE_W + NOTCH_DX - hw, 1e6)
    end
    return spans
end

local function colSpans(x)
    local spans = { { 0, BASE_H } }
    for _, cx in ipairs(CX) do
        local dx = abs(x - cx)
        if dx < R then
            local hh = sqrt(R * R - dx * dx)
            spans = subtract(spans, -1e6, hh)
            spans = subtract(spans, BASE_H - hh, 1e6)
        end
    end
    if x < R - NOTCH_DX then
        local hh = sqrt(R * R - (x + NOTCH_DX) * (x + NOTCH_DX))
        spans = subtract(spans, NOTCH_Y - hh, NOTCH_Y + hh)
    end
    if x > BASE_W - R + NOTCH_DX then
        local d = BASE_W + NOTCH_DX - x
        local hh = sqrt(R * R - d * d)
        spans = subtract(spans, NOTCH_Y - hh, NOTCH_Y + hh)
    end
    return spans
end

-- Cache the scan spans of each row/column to avoid recomputation
local paper_spans_cache = {}
local function getPaperSpans(scale)
    local key = string.format("%.2f", scale)
    if paper_spans_cache[key] then
        return paper_spans_cache[key]
    end

    local s = scale
    local W_s = floor(BASE_W * s + 0.5)
    local H_s = floor(BASE_H * s + 0.5)

    local rows = {}
    for y_s = 0, H_s - 1 do
        local y_base = y_s / s
        rows[y_s] = rowSpans(y_base)
    end

    local cols = {}
    for x_s = 0, W_s - 1 do
        local x_base = x_s / s
        cols[x_s] = colSpans(x_base)
    end

    local cache = { rows = rows, cols = cols, W_s = W_s, H_s = H_s }
    paper_spans_cache[key] = cache
    return cache
end

local function paintPaper(bb, ox, oy)
    local s = current_scale
    local cache = getPaperSpans(s)
    local rows, cols = cache.rows, cache.cols
    local W_s, H_s = cache.W_s, cache.H_s

    -- Draw the horizontal direction (white interior + black dots on left/right edges)
    for y_s = 0, H_s - 1 do
        local spans = rows[y_s]
        for _, span in ipairs(spans) do
            local x1_base, x2_base = span[1], span[2]
            local x1_s = floor(x1_base * s + 0.5)
            local x2_s = floor(x2_base * s + 0.5)
            if x2_s > x1_s then
                bb:paintRect(ox + x1_s, oy + y_s, x2_s - x1_s, 1, Blitbuffer.COLOR_WHITE)
                bb:paintRect(ox + x1_s, oy + y_s, 1, 1, Blitbuffer.COLOR_BLACK)
                bb:paintRect(ox + x2_s - 1, oy + y_s, 1, 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end

    -- Draw the black edge dots in the vertical direction (white is not redrawn)
    for x_s = 0, W_s - 1 do
        local spans = cols[x_s]
        for _, span in ipairs(spans) do
            local y1_base, y2_base = span[1], span[2]
            local y1_s = floor(y1_base * s + 0.5)
            local y2_s = floor(y2_base * s + 0.5)
            if y2_s > y1_s then
                bb:paintRect(ox + x_s, oy + y1_s, 1, 1, Blitbuffer.COLOR_BLACK)
                bb:paintRect(ox + x_s, oy + y2_s - 1, 1, 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

-- ------------------------------------------------------------------- text --
local face_cache = {}

local function rawFace(which, size)
    size = px(size)
    if size < 6 then size = 6 end
    local key = which .. "/" .. size
    if face_cache[key] then return face_cache[key] end

    local font_name
    if which == "C" then
        font_name = "cfont"
    elseif which == "L" then
        font_name = "ffont"
    else
        font_name = "cfont"
    end

    local ok, face = pcall(Font.getFace, Font, font_name, size)
    if not ok or not face then
        logger.warn("read-receipt: failed to get built-in font", font_name, "- falling back to cfont")
        face = Font:getFace("cfont", size)
    end

    face_cache[key] = face
    return face
end

local function textWidth(face, s)
    local ok, w = pcall(function()
        return RenderText:sizeUtf8Text(0, 1e6, face, s, true, false).x
    end)
    return ok and w or 0
end

local FONT_SCALE = nil
local function calibrate()
    local probe, target, guess = "READ RECEIPT", 479.0, 72
    for _ = 1, 6 do
        local w = textWidth(rawFace("L", guess), probe)
        if w <= 0 then break end
        if math.abs(w - target) < 0.75 then break end
        guess = guess * target / w
    end
    FONT_SCALE = guess / 72
    logger.info("read-receipt: font scale calibrated to", FONT_SCALE)
end

local function getFace(which, size)
    if not FONT_SCALE then calibrate() end
    return rawFace(which, size * FONT_SCALE * current_scale)
end

local function utf8chars(s)
    local t = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end

local has_char_memo = {}
local function faceHasChar(face, ch)
    local memo_key = tostring(face) .. ch
    local memo = has_char_memo[memo_key]
    if memo ~= nil then return memo end
    local code
    local b1 = ch:byte(1)
    if not b1 then return true end
    if b1 < 0x80 then code = b1
    elseif b1 < 0xE0 then code = (b1 - 0xC0) * 0x40 + (ch:byte(2) or 0) - 0x80
    elseif b1 < 0xF0 then
        code = (b1 - 0xE0) * 0x10000 + ((ch:byte(2) or 0) - 0x80) * 0x40 + ((ch:byte(3) or 0) - 0x80)
    else return true end
    local has
    local ok = pcall(function() has = face.ftface:hasGlyph(code) end)
    if not ok or has == nil then has = true end
    has_char_memo[memo_key] = has
    return has
end

local function drawText(bb, x, baseline, face, alt_face, text, ls, c)
    local per_char = (ls and abs(ls) >= 0.4)
    if not per_char then
        for _, ch in ipairs(utf8chars(text)) do
            if not faceHasChar(face, ch) then
                per_char = true
                break
            end
        end
    end
    if not per_char then
        RenderText:renderUtf8Text(bb, px(x), px(baseline), face, text, true, false, c)
        return x + textWidth(face, text)
    end
    for _, ch in ipairs(utf8chars(text)) do
        local f = face
        if alt_face and not faceHasChar(face, ch) then f = alt_face end
        RenderText:renderUtf8Text(bb, px(x), px(baseline), f, ch, true, false, c)
        x = x + textWidth(f, ch) + (ls or 0) * current_scale
    end
    return x - (ls or 0) * current_scale
end

-- --------------------------------------------------------------- the data --
local function collectData(ui)
    local now = os.time()
    local wd_full = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
    local wd = tonumber(os.date("%w", now)) + 1
    local d = {
        date = os.date("%Y.%m.%d", now),
        weekday_full = wd_full[wd],
        no = "NO. D" .. os.date("%Y%m%d", now),
        id = "D" .. os.date("%Y%m%d", now),
        rating = 0,
        chapter = nil,
        total_pages = "0",
        total_time = "0 m",
    }
    if ui and ui.document then
        local props = ui.document:getProps() or {}
        if props.title and props.title ~= "" then
            d.title = props.title
        else
            d.title = ""
        end
        if props.authors and props.authors ~= "" then
            d.author = props.authors
        end
        local cur = ui.view and ui.view.state and ui.view.state.page or 1
        local total = ui.document:getPageCount() or 1
        d.pages = string.format("%d / %d", cur, total)
        d.progress = cur / total
        d.pct = string.format("%d%%", math.floor(d.progress * 100 + 0.5))

        local toc = ui.toc
        if toc and toc.getTocTitleByPage then
            local chapter = toc:getTocTitleByPage(cur) or ""
            if chapter ~= "" then
                d.chapter = chapter
            end
        end
    end

    d.status = "READING"
    if ui and ui.doc_settings then
        local ok, summary = pcall(function() return ui.doc_settings:readSetting("summary") end)
        if ok and summary then
            if summary.status == "complete" then
                d.status = "FINISHED"
            end
            if summary.rating then
                d.rating = normalizeRating(summary.rating)
            end
        end
    end
    if d.progress and d.progress >= 0.999 then d.status = "FINISHED" end

    d.s_pages, d.s_time, d.d_pages, d.d_time = "--", "--", "--", "--"
    d.total_time = "0 m"
    d.start_date = "--"

    local function hm(seconds)
        seconds = math.floor(tonumber(seconds) or 0)
        local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
        if h > 0 then
            if m == 0 then
                return string.format("%dh", h)
            else
                return string.format("%dh %02dm", h, m)
            end
        else
            return string.format("%d m", m)
        end
    end

    local stats = ui and ui.statistics
    local enabled = stats and stats.settings and stats.settings.is_enabled
    local dbg = {}

    if stats and stats.insertDB then pcall(function() stats:insertDB() end) end

    if not stats then
        d.debug = "no ui.statistics"
    elseif not enabled then
        d.debug = "statistics plugin disabled"
    else
        local id_book = stats.id_curr_book
        dbg[#dbg + 1] = "id=" .. tostring(id_book)

        if stats.getTodayBookStats then
            local ok, t, p = pcall(stats.getTodayBookStats, stats)
            dbg[#dbg + 1] = "today=" .. tostring(ok) .. ":" .. tostring(p) .. "/" .. tostring(t)
            if ok then
                if p then d.d_pages = tostring(p) end
                if t then d.d_time = hm(t) end
            end
        end

        if stats.getPageTimeTotalStats and id_book then
            local ok, pages, secs = pcall(stats.getPageTimeTotalStats, stats, id_book)
            dbg[#dbg + 1] = "total=" .. tostring(ok) .. ":" .. tostring(pages) .. "/" .. tostring(secs)
            if ok then
                if pages then d.total_pages = tostring(pages) end
                if secs then d.total_time = hm(secs) end
            end
        end

        if d.total_time == "0 m" and stats.book_read_time then
            d.total_time = hm(stats.book_read_time)
        end

        if stats.start_current_period then
            local since = tonumber((tostring(stats.start_current_period):gsub("[^%d]", ""))) or os.time()
            d.s_time = hm(os.time() - since)
        end

        if id_book then
            local ok_db, err = pcall(function()
                local SQ3 = require("lua-ljsqlite3/init")
                local DataStorage = require("datastorage")
                local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
                local function one(sql)
                    local ok, v = pcall(function() return conn:rowexec(sql) end)
                    if not ok or v == nil then return nil end
                    return tonumber((tostring(v):gsub("[^%-%d%.]", "")))
                end
                local first = one(string.format("SELECT min(start_time) FROM page_stat WHERE id_book = %d", id_book))
                if first then d.start_date = os.date("%Y.%m.%d", first) end
                local since = tonumber((tostring(stats.start_current_period or ""):gsub("[^%d]", ""))) or os.time()
                local sp = one(string.format("SELECT count(DISTINCT page) FROM page_stat WHERE id_book = %d AND start_time >= %d", id_book, since))
                local st = one(string.format("SELECT sum(duration) FROM page_stat WHERE id_book = %d AND start_time >= %d", id_book, since))
                if sp then d.s_pages = tostring(sp) end
                if st then d.s_time = hm(st) end
                dbg[#dbg + 1] = "sess=" .. tostring(sp) .. "/" .. tostring(st)
                conn:close()
            end)
            if not ok_db then dbg[#dbg + 1] = "dberr:" .. tostring(err):sub(-48) end
        end

        if d.s_time == "--" and stats.start_current_period then
            d.s_time = hm(os.time() - tonumber((tostring(stats.start_current_period):gsub("[^%d]", ""))))
        end
        d.debug = table.concat(dbg, " ")
    end

    local avg_time_per_page = stats and stats.avg_time
    if avg_time_per_page and avg_time_per_page > 0 and ui and ui.document then
        local total_pages = ui.document:getPageCount() or 0
        local current_page = ui.view and ui.view.state and ui.view.state.page or 1
        local page_left = math.max(total_pages - current_page, 0)
        d.est_time = hm(avg_time_per_page * page_left)
    else
        d.est_time = "--"
    end

    return d
end

-- the data of a book that is NOT open in the reader (used by the Library Card plugin).
-- Reads the book's sidecar (progress, rating, finished) and KOReader's statistics database.
-- book = { path, title, authors, pages }
local function hmText(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if h > 0 then
        if m == 0 then return string.format("%dh", h) end
        return string.format("%dh %02dm", h, m)
    end
    return string.format("%d m", m)
end

local book_id_cache = {} -- path -> statistics book id (the md5 of the file is only computed once)

local function collectDataForBook(book)
    local now = os.time()
    local wd_full = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
    local d = {
        date = os.date("%Y.%m.%d", now),
        weekday_full = wd_full[tonumber(os.date("%w", now)) + 1],
        no = "NO. D" .. os.date("%Y%m%d", now),
        id = "D" .. os.date("%Y%m%d", now),
        rating = 0,
        chapter = "",
        title = book.title or "",
        pages = "--",
        pct = "0%",
        progress = 0,
        status = "READING",
        s_pages = "--", s_time = "--",
        d_pages = "--", d_time = "--",
        total_pages = "0", total_time = "0 m",
        start_date = "--",
        est_time = "--",
    }
    if book.authors and book.authors ~= "" then d.author = book.authors end

    -- sidecar: progress, saved page count, rating, finished
    local total_pages = tonumber(book.pages)
    pcall(function()
        local DocSettings = require("docsettings")
        local ds = DocSettings:open(book.path)
        local pf = tonumber(ds:readSetting("percent_finished"))
        local dp = tonumber(ds:readSetting("doc_pages"))
        local summary = ds:readSetting("summary")
        if dp and dp > 0 then total_pages = dp end
        if pf then d.progress = math.max(0, math.min(1, pf)) end
        if type(summary) == "table" then
            if summary.status == "complete" then d.status = "FINISHED" end
            if summary.rating then d.rating = normalizeRating(summary.rating) end
        end
        if ds.close then pcall(ds.close, ds) end
    end)
    if d.progress >= 0.999 then d.status = "FINISHED" end
    d.pct = string.format("%d%%", math.floor(d.progress * 100 + 0.5))
    if total_pages and total_pages > 0 then
        local cur = math.max(1, math.min(total_pages, math.floor(d.progress * total_pages + 0.5)))
        d.pages = string.format("%d / %d", cur, total_pages)
    end

    -- statistics database
    pcall(function()
        local DataStorage = require("datastorage")
        local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        if lfs.attributes(db_path, "mode") ~= "file" then return end
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db_path)
        local function one(sql)
            local ok, v = pcall(function() return conn:rowexec(sql) end)
            if not ok or v == nil then return nil end
            return tonumber((tostring(v):gsub("[^%-%d%.]", "")))
        end

        local id_book = book_id_cache[book.path]
        if not id_book then
            local ok_md5, md5 = pcall(function() return require("util").partialMD5(book.path) end)
            if ok_md5 and md5 then
                id_book = one(string.format("SELECT id FROM book WHERE md5 = '%s'", md5))
            end
            if not id_book and book.title and book.title ~= "" then
                id_book = one(string.format("SELECT id FROM book WHERE title = '%s' ORDER BY last_open DESC LIMIT 1",
                    (book.title:gsub("'", "''"))))
            end
            if id_book then book_id_cache[book.path] = id_book end
        end

        if id_book then
            local pages = one(string.format("SELECT count(DISTINCT page) FROM page_stat WHERE id_book = %d", id_book))
            local secs = one(string.format("SELECT sum(duration) FROM page_stat WHERE id_book = %d", id_book))
            local first = one(string.format("SELECT min(start_time) FROM page_stat WHERE id_book = %d", id_book))
            if pages then d.total_pages = tostring(pages) end
            if secs then d.total_time = hmText(secs) end
            if first then d.start_date = os.date("%Y.%m.%d", first) end
            if pages and pages > 0 and secs and secs > 0 and total_pages and total_pages > 0 then
                local left = math.max(total_pages * (1 - d.progress), 0)
                d.est_time = hmText(secs / pages * left)
            end
        end

        -- today's reading (all books, like the receipt of the open book)
        local t = os.date("*t", now)
        local day_start = os.time{ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }
        local tp = one(string.format(
            "SELECT count(*) FROM (SELECT 1 FROM page_stat WHERE start_time >= %d GROUP BY id_book, page)", day_start))
        local ts = one(string.format("SELECT sum(duration) FROM page_stat WHERE start_time >= %d", day_start))
        d.d_pages = tostring(tp or 0)
        d.d_time = hmText(ts or 0)
        conn:close()
    end)

    return d
end

-- cover loading
local function loadCover(doc)
    if not doc then return nil end
    local file = doc.file
    local tries = {
        function()
            local BIM = require("bookinfomanager")
            local info = BIM:getBookInfo(file, true)
            return info and info.cover_bb
        end,
        function()
            local BIM = require("plugins/coverbrowser.koplugin/bookinfomanager")
            local info = BIM:getBookInfo(file, true)
            return info and info.cover_bb
        end,
        function()
            local DocSettings = require("docsettings")
            local path = DocSettings:findCustomCoverFile(file)
            if not path then return nil end
            return RenderImage:renderImageFile(path, false)
        end,
        function()
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            return BookInfo:getCoverImage(nil, file, true)
        end,
        function()
            local BookInfo = require("apps/filemanager/filemanagerbookinfo")
            return BookInfo:getCoverImage(doc)
        end,
        function() return doc:getCoverPageImage() end,
    }
    for i, fn in ipairs(tries) do
        local ok, res = pcall(fn)
        if ok and res then
            logger.info("read-receipt: cover loaded via strategy", i)
            return res
        end
        logger.warn("read-receipt: cover strategy", i, "->", tostring(res))
    end
    return nil
end

local function blitCoverInto(bb, img, dx, dy, dw, dh)
    if not img then return false end
    dx, dy, dw, dh = math.floor(dx), math.floor(dy), math.floor(dw), math.floor(dh)
    if dw < 1 or dh < 1 then return false end
    local ok, err = pcall(function()
        local ImageWidget = require("ui/widget/imagewidget")
        local w = ImageWidget:new{
            image = img,
            image_disposable = false,
            width = dw,
            height = dh,
            keep_aspect_ratio = false,
            scale_factor = nil,
        }
        w:paintTo(bb, dx, dy)
        w:free()
    end)
    if ok then return true end
    logger.warn("read-receipt: ImageWidget cover failed:", tostring(err))
    local scaled = RenderImage:scaleBlitBuffer(img, dw, dh, false)
    if scaled then
        bb:blitFrom(scaled, dx, dy, 0, 0, dw, dh)
        return true
    end
    return false
end

-- ------------------------------------------------------------- the widget --
local Receipt = InputContainer:extend{
    name = "read_receipt_view",
    covers_fullscreen = true,
    data = nil,
    document = nil,
    ui = nil,
    book_file = nil,  -- set when the receipt is for a book that is not open in the reader
    cover_file = nil, -- optional cover picture for such a book
    on_close = nil,   -- called once after the receipt is closed
    rating = 0,
    scale = 1,
    star_icons_full = nil,
    star_icons_half = nil,
    star_icons_empty = nil,
}

function Receipt:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        local back = Device.input and Device.input.group and Device.input.group.Back or { "Back" }
        self.key_events = { Close = { back } }
    end
    if not self.data then
        self.data = collectData(self.ui)
    end
    self.rating = normalizeRating(self.data and self.data.rating)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.scale = math.min(screen_w * 0.68 / BASE_W, screen_h * 0.90 / BASE_H)

    self.star_icons_full = {}
    self.star_icons_half = {}
    self.star_icons_empty = {}
    local star_size_px = math.max(MIN_STAR_SIZE, math.floor(STAR_SIZE * self.scale + 0.5))
    local star_gap_px = math.floor(STAR_GAP * self.scale + 0.5)

    for i = 1, STAR_COUNT do
        local ok_full, icon_full = pcall(IconWidget.new, IconWidget, {
            icon = "star.full",
            width = star_size_px,
            height = star_size_px,
            alpha = true,
        })
        if ok_full and icon_full then
            self.star_icons_full[i] = icon_full
        else
            logger.warn("read-receipt: failed to create full star icon #", i)
        end

        local ok_half, icon_half = pcall(IconWidget.new, IconWidget, {
            icon = "star.half",
            width = star_size_px,
            height = star_size_px,
            alpha = true,
        })
        if ok_half and icon_half then self.star_icons_half[i] = icon_half end

        local ok_empty, icon_empty = pcall(IconWidget.new, IconWidget, {
            icon = "star.empty",
            width = star_size_px,
            height = star_size_px,
            alpha = true,
        })
        if ok_empty and icon_empty then
            self.star_icons_empty[i] = icon_empty
        else
            logger.warn("read-receipt: failed to create empty star icon #", i)
        end
    end
end

function Receipt:onCloseWidget()
    if self.cover_owned and self.cover and self.cover.free then
        pcall(function() self.cover:free() end)
        self.cover = nil
    end
    if self.on_close then
        local cb = self.on_close
        self.on_close = nil
        UIManager:nextTick(function() pcall(cb) end)
    end
    if self.star_icons_full then
        for _, w in ipairs(self.star_icons_full) do
            if w then pcall(function() w:free() end) end
        end
    end
    if self.star_icons_half then
        for _, w in ipairs(self.star_icons_half) do
            if w then pcall(function() w:free() end) end
        end
    end
    if self.star_icons_empty then
        for _, w in ipairs(self.star_icons_empty) do
            if w then pcall(function() w:free() end) end
        end
    end
end

function Receipt:onTap(arg, ges)
    if self.is_screensaver then
        UIManager:close(self)
        return true
    end

    local pos = ges.pos
    local ox = px((Screen:getWidth() - BASE_W * self.scale) / 2)
    local oy = px((Screen:getHeight() - BASE_H * self.scale) / 2)

    local tx = (pos.x - ox) / self.scale
    local ty = (pos.y - oy) / self.scale

    -- Top title "READ RECEIPT" -> tap to jump to 2-calendar-reading-stats.lua
    -- That patch is not a module and cannot be required; we can only call the onCalendarStats it attaches to ReaderUI
    if tx >= 30 and tx <= 560 and ty >= 80 and ty <= 215 then
        UIManager:close(self)
        UIManager:scheduleIn(0.25, function()
            if self.ui and type(self.ui.onCalendarStats) == "function" then
                self.ui:onCalendarStats()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{ text = "2-calendar-reading-stats.lua not found" })
            end
        end)
        return true
    end

    -- Barcode area -> reading insights popup (original logic unchanged)
    if tx >= 30 and tx <= 810 and ty >= 1300 and ty <= 1360 then
        UIManager:close(self)
        UIManager:scheduleIn(0.25, function()
            if self.ui and self.ui.onShowReadingInsightsPopup then
                self.ui:onShowReadingInsightsPopup()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{ text = "Please install the reading statistics plugin first" })
            end
        end)
        return true
    end

    local star_total_w = STAR_COUNT * STAR_SIZE + (STAR_COUNT - 1) * STAR_GAP
    local star_x1 = STAR_X - STAR_TOUCH_EXPAND
    local star_x2 = STAR_X + star_total_w + RATING_TEXT_GAP + 100 + STAR_TOUCH_EXPAND
    local star_y1 = STAR_TOP - STAR_TOUCH_EXPAND
    local star_y2 = STAR_TOP + STAR_SIZE + STAR_TOUCH_EXPAND

    if tx >= star_x1 and tx <= star_x2 and ty >= star_y1 and ty <= star_y2 then
        local offset_x_inner = tx - STAR_X
        local star_idx = math.floor(offset_x_inner / (STAR_SIZE + STAR_GAP)) + 1
        local within_star = offset_x_inner - (star_idx - 1) * (STAR_SIZE + STAR_GAP)
        star_idx = math.max(1, math.min(STAR_COUNT, star_idx))
        local selected_rating = normalizeRating(star_idx
            - (within_star < STAR_SIZE / 2 and 0.5 or 0))
        if offset_x_inner < 0 then selected_rating = 0 end

        if selected_rating == self.rating and self.rating > 0 then
            self.rating = 0
        else
            self.rating = selected_rating
        end

        self:saveRating()
        UIManager:setDirty(self, "partial")
        return true
    end

    UIManager:close(self)
    return true
end

function Receipt:onClose()
    UIManager:close(self)
    return true
end

function Receipt:saveRating()
    local ui = self.ui
    -- the book is open in the reader: use its live settings
    local live = ui and ui.doc_settings
        and (not self.book_file or (ui.document and ui.document.file == self.book_file))
    local ok, err = pcall(function()
        local ds = live and ui.doc_settings
        if not ds then
            if not self.book_file then return end
            ds = require("docsettings"):open(self.book_file)
        end
        local summary = ds:readSetting("summary") or {}
        if self.rating > 0 then
            summary.rating = normalizeRating(self.rating)
        else
            summary.rating = nil
        end
        ds:saveSetting("summary", summary)
        ds:flush()
    end)
    if not ok then
        logger.warn("read-receipt: save rating failed:", tostring(err))
    end
end

function Receipt:getData()
    if not self.data then self.data = collectData(self.ui) end
    return self.data
end

function Receipt:getCover()
    if self.cover_checked then return self.cover end
    self.cover_checked = true
    if self.cover_file then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(self.cover_file, false) end)
        if ok and bb then
            self.cover = bb
            self.cover_owned = true
            return self.cover
        end
    end
    self.cover = loadCover(self.document)
    return self.cover
end

function Receipt:getSize() return self.dimen end

function Receipt:paintTo(bb, x, y)
    current_scale = self.scale

    -- receipt of a book opened from the Library Card: a plain white backdrop hides the window
    -- under it (that window stays open, so closing the receipt is instant)
    if self.book_file then
        bb:paintRect(x, y, Screen:getWidth(), Screen:getHeight(), Blitbuffer.COLOR_WHITE)
    end

    local ox = x + px((Screen:getWidth() - BASE_W * current_scale) / 2)
    local oy = y + px((Screen:getHeight() - BASE_H * current_scale) / 2)

    paintPaper(bb, ox, oy)

    dottedH(bb, ox, oy, 33.7, 815, 327.2, 2, 7, 2, COL.K)
    dottedH(bb, ox, oy, 33.7, 815, 418.6, 2, 7, 2, COL.K)
    rect(bb, ox, oy, 586.06, 53.52, 1, 259.9, COL.K)
    rect(bb, ox, oy, 273.3, 339.9, 1, 66, COL.K)
    rect(bb, ox, oy, 540.4, 339.9, 1, 66, COL.K)

    local function paintCover()
        local cx, cy, cw, ch = px(512.9), px(489.58), px(302.9), px(399.6)
        local abs_cx = ox + math.floor(cx * current_scale)
        local abs_cy = oy + math.floor(cy * current_scale)
        local abs_cw = math.floor(cw * current_scale)
        local abs_ch = math.floor(ch * current_scale)
        if not blitCoverInto(bb, self:getCover(), abs_cx, abs_cy, abs_cw, abs_ch) then
            bb:paintRect(abs_cx, abs_cy, abs_cw, abs_ch, COL.COVER)
        end
        rect(bb, ox, oy, cx, cy, cw, 1, COL.K)
        rect(bb, ox, oy, cx, cy + ch - 1, cw, 1, COL.K)
        rect(bb, ox, oy, cx, cy, 1, ch, COL.K)
        rect(bb, ox, oy, cx + cw - 1, cy, 1, ch, COL.K)
    end
    pcall(paintCover)

    rect(bb, ox, oy, 33.6, 816.68, 423.6, 14.6, COL.TRACK)
    local progress = (self.data and self.data.progress) or 0.1705
    rect(bb, ox, oy, 33.6, 816.68, 423.6 * progress, 14.6, COL.FILL)
    dottedH(bb, ox, oy, 33.2, 814.5, 972.85, 2, 9, 2, COL.K)
    rect(bb, ox, oy, 31.9, 1058.35, 785.8, 1, COL.K)
    rect(bb, ox, oy, 45.3, 1092.1, 120, 1, COL.K)
    rect(bb, ox, oy, 272, 1092.1, 119.3, 1, COL.K)
    rect(bb, ox, oy, 456.8, 1092.1, 120, 1, COL.K)
    rect(bb, ox, oy, 683, 1092.1, 119.3, 1, COL.K)
    -- Three vertical lines: restore the original hard-coded parameters
    rect(bb, ox, oy, 200.9, 1122.2, 1, 126.3, COL.K)
    rect(bb, ox, oy, 422.4, 1122.2, 1, 126.3, COL.K)
    rect(bb, ox, oy, 612.4, 1122.2, 1, 126.3, COL.K)
    dottedH(bb, ox, oy, 33.2, 814.5, 1277.35, 2, 9, 2, COL.K)
    for _, b in ipairs(BARS) do
        rect(bb, ox, oy, b[1], BARCODE_Y + 5, b[2], BARCODE_H, COL.K)
    end
    disc(bb, ox, oy, 383.28, 1446.84, 3.1, COL.K)
    for i, cx in ipairs({ 406.92, 427.8, 448.44, 469.32 }) do
        disc(bb, ox, oy, cx, 1446.84, 2.4, COL.K)
    end

    local data = self.data or {}
    local widths = {}
    for _, it in ipairs(ITEMS) do
        local text = it.t
        if it.key and data[it.key] then
            if it.prefix then
                text = it.prefix .. (data[it.key] or "")
            else
                text = data[it.key]
            end
        end
        if text ~= "" then
            local face = getFace(it.f, it.size)
            local tw = textWidth(face, text)
            widths[it] = tw
        else
            widths[it] = 0
        end
    end

    -- Right edge of the status value (used to right-align the "STATUS" label)
    local status_right_edge_base = nil
    for _, it in ipairs(ITEMS) do
        if it.key == "status" and widths[it] then
            status_right_edge_base = it.x
            break
        end
    end

    -- Baseline of "TODAY'S" (used to align SUMMARY)
    local summary_baseline = nil
    for _, it in ipairs(ITEMS) do
        if it.sum_anchor then
            summary_baseline = oy + (it.top + K_CN * it.size) * current_scale
            break
        end
    end

    local title_left_idx = 6
    local title_slash_idx = 7
    local title_right_indices = {8, 9, 10, 11, 12}
    local x_start = 34.36

    local left_item = ITEMS[title_left_idx]
    local left_face = getFace(left_item.f, left_item.size)
    local left_text = left_item.t
    local left_baseline = oy + (left_item.top + K_CN * left_item.size) * current_scale
    local end_x
    local x_pos = x_start
    if left_text ~= "" then
        end_x = drawText(bb, ox + x_start * current_scale, left_baseline, left_face, nil, left_text, left_item.ls * current_scale, COL.K)
        x_pos = (end_x - ox) / current_scale
    end

    local slash_item = ITEMS[title_slash_idx]
    local slash_face = getFace(slash_item.f, slash_item.size)
    local slash_text = slash_item.t
    local slash_baseline = oy + (slash_item.top + K_LA * slash_item.size) * current_scale
    local slash_x = x_pos
    if slash_text ~= "" then
        end_x = drawText(bb, ox + slash_x * current_scale, slash_baseline, slash_face, nil, slash_text, slash_item.ls * current_scale, COL.K)
        x_pos = (end_x - ox) / current_scale
    end

    for _, idx in ipairs(title_right_indices) do
        local item = ITEMS[idx]
        local face = getFace(item.f, item.size)
        local text = item.t
        local baseline = oy + (item.top + K_LA * item.size) * current_scale
        end_x = drawText(bb, ox + x_pos * current_scale, baseline, face, nil, text, item.ls * current_scale, COL.K)
        x_pos = (end_x - ox) / current_scale
    end

    local pen = 0
    for idx, it in ipairs(ITEMS) do
        if idx >= 6 and idx <= 12 then
            goto continue
        end

        local text = it.t
        if it.key and data[it.key] then
            if it.prefix then
                text = it.prefix .. (data[it.key] or "")
            else
                text = data[it.key]
            end
        end
        if text ~= "" then
            local face = getFace(it.f, it.size)
            local alt = getFace(it.f == "C" and "L" or "C", it.size)

            if it.maxw and textWidth(face, text) > it.maxw * current_scale then
                local chars = utf8chars(text)
                while #chars > 1 and textWidth(face, table.concat(chars) .. "…") > it.maxw * current_scale do
                    table.remove(chars)
                end
                text = table.concat(chars) .. "…"
            end

            local tw = textWidth(face, text)
            local sx

            -- Special handling: right-align the "STATUS" label
            if it.t == "STATUS" and status_right_edge_base then
                sx = ox + (status_right_edge_base - widths[it] / current_scale) * current_scale
            elseif it.t == "SUMMARY" then
                -- Follows "TODAY'S" directly, with one space of width in between
                local space_w = textWidth(face, " ")
                sx = pen + space_w
            elseif it.no_align then
                local state_item = ITEMS[1]
                local status_item = ITEMS[2]
                local state_width = widths[state_item] or 0
                local status_width = widths[status_item] or 0
                local right_state = ITEMS[2].x
                local right_status = ITEMS[2].x
                local max_right = math.max(right_state, right_status)
                sx = ox + max_right * current_scale - tw
            elseif it.cx then
                sx = ox + it.cx * current_scale - tw / 2
            elseif it.center then
                sx = ox + (BASE_W * current_scale - tw) / 2
            elseif it.right_align then
                sx = ox + it.x * current_scale - tw
            elseif it.dot_center then
                local left_item = ITEMS[idx-1]
                local right_item = ITEMS[idx+1]
                if left_item and right_item then
                    local left_x = left_item.x * current_scale
                    local left_width = widths[left_item] or 0
                    local right_x = right_item.x * current_scale
                    local mid = (left_x + left_width + right_x) / 2
                    sx = ox + mid - tw/2
                else
                    sx = ox + it.x * current_scale
                end
            else
                sx = it.follow and (pen + it.follow * current_scale) or (ox + it.x * current_scale)
            end

            local baseline
            if it.t == "SUMMARY" and summary_baseline then
                baseline = summary_baseline  -- force the CJK baseline
            else
                local k = it.f == "C" and K_CN or K_LA
                baseline = oy + (it.top + k * it.size) * current_scale
            end

            local ok, res = pcall(drawText, bb, sx, baseline,
                                  face, alt, text, it.ls * current_scale, COL[it.c])
            if ok then
                pen = res
            else
                logger.warn("read-receipt: draw failed", text, res)
            end
        end
        ::continue::
    end

    local rating = normalizeRating(self.rating)
    local star_x = ox + STAR_X * current_scale
    local star_y = oy + STAR_TOP * current_scale
    local star_size_scaled = math.max(MIN_STAR_SIZE, STAR_SIZE * current_scale)
    local star_gap_scaled = STAR_GAP * current_scale

    for i = 1, STAR_COUNT do
        local icon
        if rating >= i then
            icon = self.star_icons_full and self.star_icons_full[i]
        elseif rating == i - 0.5 then
            icon = self.star_icons_half and self.star_icons_half[i]
        else
            icon = self.star_icons_empty and self.star_icons_empty[i]
        end

        if icon then
            local ok_paint = pcall(function()
                icon:paintTo(bb, math.floor(star_x + 0.5), math.floor(star_y + 0.5))
            end)
            if not ok_paint then
                logger.warn("read-receipt: star paint failed for rating", rating, "icon", i)
            end
        else
            logger.warn("read-receipt: missing star icon for index", i)
        end

        star_x = star_x + star_size_scaled + star_gap_scaled
    end

    local rating_text = RATING_DEFAULT_TEXT
    if rating > 0 then
        local label_index = math.max(1, math.min(#RATING_LABELS,
            math.floor(rating / RATING_STEP + 0.5)))
        rating_text = string.format("%.1f stars · %s", rating, RATING_LABELS[label_index])
    end
    local full_text = "(" .. rating_text .. ")"
    local text_face = getFace("C", RATING_TEXT_SIZE)
    local text_baseline = star_y + (star_size_scaled - K_CN * RATING_TEXT_SIZE * current_scale) / 2 + K_CN * RATING_TEXT_SIZE * current_scale
    pcall(drawText, bb, star_x + RATING_TEXT_GAP * current_scale, text_baseline, text_face, nil, full_text, 0, COL.K)
end

-- ------------------------------------------------------------ integration --
local function showReceipt(ui, on_close)
    if not ui or not ui.document or not ui.view then
        logger.info("read-receipt: no active reading session, skip showing receipt")
        return
    end
    UIManager:show(Receipt:new{ ui = ui, data = collectData(ui), document = ui.document, on_close = on_close })
end

-- receipt of any book (used by the Library Card plugin when you tap the current read).
-- A book that is open in the reader gets the full live receipt; any other book gets one built
-- from its saved progress and the statistics database. on_close runs after the receipt is closed.
local function showReceiptForBook(ui, book, on_close)
    if not book or not book.path then error("read-receipt: no book given") end
    if ui and ui.document and ui.view and ui.document.file == book.path then
        return showReceipt(ui, on_close)
    end
    if lfs.attributes(book.path, "mode") ~= "file" then error("read-receipt: book file not found") end
    UIManager:show(Receipt:new{
        ui = ui,
        data = collectDataForBook(book),
        document = { file = book.path },
        book_file = book.path,
        cover_file = book.cover_file,
        on_close = on_close,
    })
end

-- the small interface other patches / plugins can use: require-free, read it from package.loaded
package.loaded["read_receipt_api"] = {
    version = 2,
    show = showReceiptForBook,
}

local ReceiptModule = WidgetContainer:extend{ name = "read_receipt" }

function ReceiptModule:init()
end

function ReceiptModule:onShowReadReceipt()
    showReceipt(self.ui)
    return true
end

local ReaderUI = require("apps/reader/readerui")
local orig_reader_init = ReaderUI.init
function ReaderUI:init()
    orig_reader_init(self)
    self:registerModule("read_receipt", ReceiptModule:new{
        ui = self, view = self.view, document = self.document,
    })
end

-- Gesture registration: reader context only; the general context was removed
local ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
if ok_dispatcher then
    pcall(Dispatcher.registerAction, Dispatcher, "show_read_receipt", {
        category = "none",
        event = "ShowReadReceipt",
        title = "Read Receipt",
        reader = true,
    })
end

-- ---------------------------------------------------------- sleep screen --
local ok_ss, Screensaver = pcall(require, "ui/screensaver")
if ok_ss then
    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local ImageWidget = require("ui/widget/imagewidget")
    local OverlapGroup = require("ui/widget/overlapgroup")

    local orig_screensaver_show = Screensaver.show
    Screensaver.show = function(self)
        if self.screensaver_type ~= "read_receipt" then
            return orig_screensaver_show(self)
        end
        local ui = self.ui or ReaderUI.instance
        if not (ui and ui.document) then
            self.screensaver_type = "disable"
            return orig_screensaver_show(self)
        end
        if self.screensaver_widget then
            UIManager:close(self.screensaver_widget)
            self.screensaver_widget = nil
        end
        Device.screen_saver_mode = true
        local rotation_mode = Screen:getRotationMode()
        Device.orig_rotation_mode = nil
        local is_odd = false
        if bit then
            is_odd = bit.band(rotation_mode, 1) == 1
        else
            is_odd = (rotation_mode % 2) == 1
        end
        if is_odd then
            Device.orig_rotation_mode = rotation_mode
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        end
        local receipt = Receipt:new{
            ui = ui,
            document = ui.document,
            data = collectData(ui),
            is_screensaver = true,
        }

        local show_cover = G_reader_settings:isTrue("read_receipt_show_cover")
        local background_widget = nil
        if show_cover and ui.document then
            local cover_bb = loadCover(ui.document)
            if cover_bb then
                local screen_size = Screen:getSize()
                background_widget = ImageWidget:new{
                    image = cover_bb,
                    width = screen_size.w,
                    height = screen_size.h,
                    keep_aspect_ratio = false,
                    alpha = true,
                }
            end
        end

        local widget_to_show = receipt
        if background_widget then
            widget_to_show = OverlapGroup:new{
                dimen = Screen:getSize(),
                background_widget,
                receipt,
            }
        end

        self.screensaver_widget = ScreenSaverWidget:new{
            widget = widget_to_show,
            background = nil,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
        pcall(function() UIManager:forceRePaint() end)
    end

    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, event, event_message)
        orig_setup(self, event, event_message)
        if G_reader_settings:readSetting("screensaver_type") == "read_receipt" then
            local ui = self.ui or ReaderUI.instance
            if ui and ui.document then
                self.screensaver_type = "read_receipt"
                self.show_message = false
            end
        end
    end

    local orig_close = Screensaver.close
    Screensaver.close = function(self, ...)
        return orig_close(self, ...)
    end

    local orig_dofile = dofile
    dofile = function(filepath)
        local result = orig_dofile(filepath)
        if filepath and filepath:match("screensaver_menu%.lua$")
                and result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table
            table.insert(wallpaper_submenu, 1, {
                text = "Read Receipt",
                radio = true,
                checked_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == "read_receipt"
                end,
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", "read_receipt")
                end,
            })
            table.insert(wallpaper_submenu, 2, {
                text = "Read Receipt settings",
                enabled_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == "read_receipt"
                end,
                sub_item_table = {
                    {
                        text = "Show book cover",
                        radio = true,
                        checked_func = function()
                            return G_reader_settings:isTrue("read_receipt_show_cover")
                        end,
                        callback = function()
                            if G_reader_settings:isTrue("read_receipt_show_cover") then
                                G_reader_settings:delSetting("read_receipt_show_cover")
                            else
                                G_reader_settings:saveSetting("read_receipt_show_cover", true)
                            end
                        end,
                    },
                },
            })
        end
        return result
    end
end

logger.info("read-receipt patch loaded (cached spans, transparent background, status right-aligned, summary baseline, settings disabled state, title tap -> onCalendarStats, gesture reader only)")
