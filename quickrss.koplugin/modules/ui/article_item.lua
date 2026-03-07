-- QuickRSS: ArticleItem widget
-- One tappable card in the article list.
--
-- Visual layout (left → right):
--   [landscape thumbnail]  [2-line bold title]
--                          [3-line snippet excerpt]
--
-- Also exports the shared layout constants (ITEM_HEIGHT, PAD) so that
-- ui.lua can drive pagination without duplicating the geometry math.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local lfs             = require("libs/libkoreader-lfs")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Screen = Device.screen

-- Font faces are computed per-card in init() based on Config.card_font_size.

-- Module-level cache: image_path → precomputed cover_scale.
-- Persists across page turns so the expensive probe decode is only done once
-- per image per session, not twice per card on every page turn.
local _cover_scale_cache = {}

-- Extract a short human-readable date from RSS pubDate or Atom ISO-8601.
local function formatDate(raw)
    if not raw or raw == "" then return nil end
    local d = raw:match("%a+,%s+(%d+%s+%a+%s+%d+)")
    if d then return d end
    d = raw:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d then return d end
    return raw  -- fallback: return as-is
end

-- ── Shared layout constants (exported so ui.lua can use them) ─────────────────
local PAD     = Screen:scaleBySize(10)   -- general-purpose padding unit
-- Heights sized to hold the desired line count (font size × ~1.4 leading)
local TITLE_H    = Screen:scaleBySize(44)   -- ceiling for 2-line title
local SNIPPET_H  = Screen:scaleBySize(60)   -- 3 lines of snippet
local TEXT_COL_H = TITLE_H + math.floor(PAD / 2) + SNIPPET_H
-- Thumbnail: full card height, 16:9 width
local THUMB_H    = TEXT_COL_H
local THUMB_W    = math.floor(THUMB_H * 16 / 9)
local ITEM_HEIGHT = PAD + TEXT_COL_H + PAD

-- ─────────────────────────────────────────────────────────────────────────────
-- ArticleItem
-- ─────────────────────────────────────────────────────────────────────────────
local ArticleItem = InputContainer:extend{
    width         = nil,
    height        = ITEM_HEIGHT,
    article       = nil,   -- { title = string, snippet = string }
    callback      = nil,   -- function(article) called on tap
    hold_callback = nil,   -- function(article) called on long press
    art_settings  = nil,   -- optional: pre-fetched Config.getArticleSettings()
}

function ArticleItem:init()
    -- Pre-initialise dimen now so the GestureRange below has a valid table
    -- reference. InputContainer updates dimen.x / dimen.y in-place during
    -- paintTo(), keeping the range accurate without re-registering.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }

    self.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self.ges_events.Hold = {
        GestureRange:new{ ges = "hold", range = self.dimen },
    }

    -- ── Dynamic font faces based on card_font_size setting ──────────────────
    local s = self.art_settings
        or require("modules/data/config").getArticleSettings()
    local sz = s.card_font_size
    local title_face   = self.article.read
        and Font:getFace("smallinfofont", sz + 1)
        or  Font:getFace("smallinfofontbold", sz + 1)
    local snippet_face = Font:getFace("smallinfofont", sz)
    local meta_face    = Font:getFace("smallinfofont", math.max(8, sz - 2))

    -- ── Left column: thumbnail image (only when available) ────────────────────
    -- Cover/crop approach: probe with scale_factor=0 (fit) to learn the fitted
    -- dimensions, then compute a cover scale so the scaled image fills at least
    -- THUMB_W × THUMB_H.  ImageWidget's default center_x/y_ratio = 0.5 makes it
    -- automatically crop to the centre when the bb exceeds the declared width/height.
    local thumbnails_enabled = s.thumbnails_enabled
    local has_thumb = thumbnails_enabled and self.article.image_path
        and lfs.attributes(self.article.image_path, "mode") == "file"
    local thumb
    if has_thumb then
        -- Look up the precomputed cover_scale; only probe if this is the
        -- first time we've seen this image this session.
        local cover_scale = _cover_scale_cache[self.article.image_path]
        if not cover_scale then
            local ok, result = pcall(function()
                local probe = ImageWidget:new{
                    file          = self.article.image_path,
                    width         = THUMB_W,
                    height        = THUMB_H,
                    scale_factor  = 0,
                    file_do_cache = false,
                }
                probe:getSize()
                local fitted_w  = probe:getCurrentWidth()
                local fitted_h  = probe:getCurrentHeight()
                local fit_scale = probe:getScaleFactor()
                probe:free()
                if fitted_w > 0 and fitted_h > 0 then
                    return fit_scale * math.max(THUMB_W / fitted_w, THUMB_H / fitted_h)
                end
                return nil
            end)
            if ok and result then
                cover_scale = result
                _cover_scale_cache[self.article.image_path] = cover_scale
            else
                has_thumb = false
            end
        end

        thumb = FrameContainer:new{
            padding    = 0,
            margin     = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            ImageWidget:new{
                file          = self.article.image_path,
                width         = THUMB_W,
                height        = THUMB_H,
                scale_factor  = cover_scale,
                file_do_cache = false,
            },
        }
    end

    -- ── Right column: meta · title · snippet ─────────────────────────────────
    -- When there's no thumbnail the text column spans the full card width.
    local text_w = has_thumb
        and (self.width - THUMB_W - PAD * 3)   -- thumb + left/mid/right gaps
        or  (self.width - PAD * 2)              -- just left/right padding

    -- Meta line: "Source · Date" in small font above the title
    local meta_parts = {}
    if self.article.source and self.article.source ~= "" then
        table.insert(meta_parts, self.article.source)
    end
    local fmt_date = formatDate(self.article.date)
    if fmt_date then table.insert(meta_parts, fmt_date) end

    local meta_widget = nil
    local meta_h      = 0
    if #meta_parts > 0 then
        meta_widget = TextWidget:new{
            text      = table.concat(meta_parts, " · "),
            face      = meta_face,
            max_width = text_w,
        }
        meta_h = meta_widget:getSize().h + math.floor(PAD / 4)
    end

    -- height_adjust = true snaps the widget height DOWN to the actual number of
    -- rendered lines, so a one-line title doesn't leave a blank second-line gap.
    -- TITLE_H is still the ceiling — long titles are capped at 2 lines.
    local title_widget = TextBoxWidget:new{
        text          = self.article.title,
        face          = title_face,
        width         = text_w,
        height        = TITLE_H,
        height_adjust = true,
        alignment     = "left",
    }

    -- Give the snippet whatever vertical space the title + meta didn't use.
    -- meta_h already includes PAD/4 below the meta line; the other PAD/4 is
    -- the gap between title and meta (or PAD/2 when there is no meta).
    local actual_title_h = title_widget:getSize().h
    local gap_h = meta_widget and math.floor(PAD / 4) or math.floor(PAD / 2)
    local adj_snippet_h  = TEXT_COL_H - actual_title_h - gap_h - meta_h

    local snippet_widget = TextBoxWidget:new{
        text      = self.article.snippet,
        face      = snippet_face,
        width     = text_w,
        height    = math.max(0, adj_snippet_h),
        alignment = "left",
    }

    local text_column = VerticalGroup:new{ align = "left" }
    table.insert(text_column, title_widget)
    if meta_widget then
        table.insert(text_column, VerticalSpan:new{ width = math.floor(PAD / 4) })
        table.insert(text_column, meta_widget)
        table.insert(text_column, VerticalSpan:new{ width = math.floor(PAD / 4) })
    else
        table.insert(text_column, VerticalSpan:new{ width = math.floor(PAD / 2) })
    end
    table.insert(text_column, snippet_widget)

    -- ── Full row: thumbnail (if any) anchored top-left, text column beside it ─
    local row_content = HorizontalGroup:new{ align = "top" }
    if thumb then
        table.insert(row_content, thumb)
        table.insert(row_content, HorizontalSpan:new{ width = PAD })
    end
    table.insert(row_content, text_column)

    self[1] = FrameContainer:new{
        width     = self.width,
        height    = self.height,
        padding   = PAD,
        margin    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        row_content,
    }
end

function ArticleItem:onTap()
    if self.callback then
        self.callback(self.article)
    end
    return true
end

function ArticleItem:onHold()
    if self.hold_callback then
        self.hold_callback(self.article)
    end
    return true
end

return {
    ArticleItem = ArticleItem,
    ITEM_HEIGHT = ITEM_HEIGHT,
    PAD         = PAD,
}
