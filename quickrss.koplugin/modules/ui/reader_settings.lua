-- QuickRSS: Reader Settings UI
-- Popup for configuring article-reader appearance (font, size, line spacing).
-- Opened from the settings icon in ArticleReader's TitleBar.
-- Calls on_change(prefs) immediately on each change so the reader re-renders.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Config          = require("modules/data/config")
local Icons           = require("modules/ui/icons")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Size            = require("ui/size")
local SpinWidget      = require("ui/widget/spinwidget")
local SR              = require("modules/ui/settings_row")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local FontList        = require("fontlist")
local _               = require("gettext")

local Screen = Device.screen

local PAD        = SR.PAD
local ROW_H      = SR.ROW_H
local VALUE_FACE = SR.VALUE_FACE

-- ── Font list ─────────────────────────────────────────────────────────────────
-- Uses KOReader's own FontList module (the same source the built-in font picker
-- uses) so we see every font KOReader can see, including user-installed ones.
-- Bold/italic faces are filtered out to keep the list to one entry per family.
-- The first entry is always the "Default" option (path = "").
local function scanFonts()
    FontList:getFontList()  -- populates FontList.fontinfo (no-op if already cached)
    local fonts = {}
    for font_file, font_info_arr in pairs(FontList.fontinfo) do
        local info = font_info_arr and font_info_arr[1]
        if info and not info.bold and not info.italic then
            local name = FontList:getLocalizedFontName(font_file, 0) or info.name or font_file
            table.insert(fonts, { name = name, path = font_file })
        end
    end
    table.sort(fonts, function(a, b) return a.name < b.name end)
    table.insert(fonts, 1, { name = _("Default (Serif)"), path = "" })
    return fonts
end

-- Short display name for a stored font path.
local function fontDisplayName(font_file)
    if not font_file or font_file == "" then
        return _("Default (Serif)")
    end
    local arr = FontList.fontinfo and FontList.fontinfo[font_file]
    if arr and arr[1] then
        return FontList:getLocalizedFontName(font_file, 0) or arr[1].name or font_file
    end
    -- Fallback: derive from filename (used before getFontList() has been called)
    local base = font_file:match("([^/]+)$") or font_file
    return base:gsub("%-Regular", ""):gsub("%.[^%.]+$", ""):gsub("%-", " ")
end

-- ─────────────────────────────────────────────────────────────────────────────
local ReaderSettingsUI = InputContainer:extend{
    name      = "quickrss_reader_settings",
    on_change = nil,   -- function(prefs) – called when any setting changes
}

local function spacingText(v) return string.format("%.1f", v / 10) end

function ReaderSettingsUI:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.key_events = {
        Close = { { "Back" }, doc = "close reader settings" },
    }

    self.s = Config.getReaderSettings()

    local popup_w = math.floor(screen_w * 0.9)
    local inner_w = popup_w - PAD * 2

    -- ── Title bar ─────────────────────────────────────────────────────────────
    local title_bar = TitleBar:new{
        width            = popup_w,
        title            = Icons.SETTINGS .. "  " .. _("Reader Settings"),
        with_bottom_line = true,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }
    local title_bar_h = title_bar:getSize().h

    -- ── Value TextWidgets ──────────────────────────────────────────────────────
    self.font_val    = TextWidget:new{
        text = fontDisplayName(self.s.font_file),
        face = VALUE_FACE,
    }
    self.size_val    = TextWidget:new{
        text = string.format("%.1f pt", self.s.font_size),
        face = VALUE_FACE,
    }
    self.spacing_val = TextWidget:new{
        text = spacingText(self.s.line_spacing),
        face = VALUE_FACE,
    }

    -- ── Row builder (shared) ────────────────────────────────────────────────
    local function makeRow(label, val_widget, on_tap)
        return SR.makeRow(inner_w, label, val_widget, on_tap)
    end

    -- ── Three rows ────────────────────────────────────────────────────────────
    local row_font = makeRow(_("Font"), self.font_val, function()
        local fonts = scanFonts()
        local buttons = {}
        for _, font in ipairs(fonts) do
            local is_current = font.path == (self.s.font_file or "")
            local label = is_current and ("✓  " .. font.name) or font.name
            local path  = font.path   -- capture for closure
            local name  = font.name
            table.insert(buttons, {{ text = label, callback = function()
                UIManager:close(font_dialog)  -- luacheck: ignore (forward ref)
                self.s.font_file = path
                Config.saveReaderSettings(self.s)
                self.font_val:setText(name)
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end }})
        end
        font_dialog = ButtonDialog:new{ buttons = buttons }
        UIManager:show(font_dialog)
    end)

    local row_size = makeRow(_("Font size"), self.size_val, function()
        UIManager:show(SpinWidget:new{
            title_text      = _("Font size"),
            value           = self.s.font_size,
            value_min       = 12,
            value_max       = 255,
            value_step      = 0.5,
            value_hold_step = 4,
            default_value   = 21,
            precision       = "%.1f",
            unit            = _("pt"),
            callback = function(spin)
                self.s.font_size = spin.value
                Config.saveReaderSettings(self.s)
                self.size_val:setText(string.format("%.1f pt", spin.value))
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end,
        })
    end)

    local row_spacing = makeRow(_("Line spacing"), self.spacing_val, function()
        UIManager:show(SpinWidget:new{
            title_text      = _("Line spacing"),
            value           = self.s.line_spacing,
            value_min       = 10,
            value_max       = 25,
            value_step      = 1,
            value_hold_step = 5,
            default_value   = 15,
            callback = function(spin)
                self.s.line_spacing = spin.value
                Config.saveReaderSettings(self.s)
                self.spacing_val:setText(spacingText(spin.value))
                self.rows_group:resetLayout()
                UIManager:setDirty(self, function() return "ui", self.dimen end)
                if self.on_change then self.on_change(self.s) end
            end,
        })
    end)

    local function sep()
        return LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen      = Geom:new{ w = inner_w, h = Size.line.thin },
            style      = "solid",
        }
    end

    self.rows_group = VerticalGroup:new{
        align = "left",
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_font },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_size },
        sep(),
        CenterContainer:new{ dimen = Geom:new{ w = popup_w, h = ROW_H }, row_spacing },
    }

    -- ── Popup frame (height computed from content) ─────────────────────────────
    local rows_content_h = ROW_H * 3 + Size.line.thin * 2
    local popup_h        = title_bar_h + rows_content_h + 2 * Size.border.window

    local popup = FrameContainer:new{
        width      = popup_w,
        height     = popup_h,
        padding    = 0,
        margin     = 0,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            self.rows_group,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        popup,
    }

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function ReaderSettingsUI:onClose()
    UIManager:close(self)
end

function ReaderSettingsUI:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

return ReaderSettingsUI
