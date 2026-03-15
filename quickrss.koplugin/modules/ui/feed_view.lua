-- QuickRSS: UI Module
-- Fullscreen article-list overlay. Fetches all configured feeds on open and
-- merges their articles into a single paginated list.
-- Tapping the settings icon (top-left) opens the feed management popup.

local Button          = require("ui/widget/button")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local InfoMessage     = require("ui/widget/infomessage")
local Config          = require("modules/data/config")
local Icons           = require("modules/ui/icons")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Cache           = require("modules/data/cache")
local lfs             = require("libs/libkoreader-lfs")
local Parser          = require("modules/data/parser")
local Size            = require("ui/size")
local T               = require("ffi/util").template
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")

-- ── Date-based sort helper ──────────────────────────────────────────────────
-- Month abbreviation → number lookup for RSS pubDate parsing.
local MONTHS = {
    Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}

-- Parse an RSS pubDate or Atom ISO-8601 date string into a Unix timestamp.
-- Returns nil for unparseable / missing dates.
local function parseDate(raw)
    if not raw or raw == "" then return nil end
    -- Atom ISO-8601: "2026-03-01T12:00:00Z" or "2026-03-01T12:00:00+00:00"
    local y, m, d, H, M, S = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if y then
        return os.time{ year=tonumber(y), month=tonumber(m), day=tonumber(d),
                         hour=tonumber(H), min=tonumber(M), sec=tonumber(S) }
    end
    -- RSS pubDate: "Mon, 01 Mar 2026 12:00:00 +0000"
    d, m, y, H, M, S = raw:match("(%d+)%s+(%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)")
    if d and MONTHS[m] then
        return os.time{ year=tonumber(y), month=MONTHS[m], day=tonumber(d),
                         hour=tonumber(H), min=tonumber(M), sec=tonumber(S) }
    end
    -- Date-only fallback: "2026-03-01"
    y, m, d = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if y then
        return os.time{ year=tonumber(y), month=tonumber(m), day=tonumber(d),
                         hour=0, min=0, sec=0 }
    end
    return nil
end

-- Sort articles newest-first by parsed date.  Articles without a parseable
-- date keep their original (fetch) order, placed after all dated articles.
local function sortByDate(articles)
    -- Tag each article with its original index so dateless articles stay stable.
    for i, art in ipairs(articles) do
        art._sort_idx = i
        art._sort_ts  = parseDate(art.date)
    end
    table.sort(articles, function(a, b)
        if a._sort_ts and b._sort_ts then return a._sort_ts > b._sort_ts end
        if a._sort_ts and not b._sort_ts then return true end
        if not a._sort_ts and b._sort_ts then return false end
        return a._sort_idx < b._sort_idx
    end)
    -- Clean up temporary keys
    for _, art in ipairs(articles) do
        art._sort_idx = nil
        art._sort_ts  = nil
    end
end

-- Pull in the card widget and the geometry constants it computed
local ArticleItemModule = require("modules/ui/article_item")
local ArticleItem       = ArticleItemModule.ArticleItem
local ITEM_HEIGHT       = ArticleItemModule.ITEM_HEIGHT
local PAD               = ArticleItemModule.PAD

local Screen = Device.screen

-- ─────────────────────────────────────────────────────────────────────────────
-- QuickRSSUI: fullscreen overlay.
--
-- Structure (top → bottom):
--   TitleBar  ("QuickRSS" + hamburger menu (left) + close button (right))
--   article_list  ← VerticalGroup rebuilt on every page turn
--   list_spacer   ← absorbs leftover pixels so footer stays at screen bottom
--   footer        (prev chevron | "Page N of M" | next chevron)
-- ─────────────────────────────────────────────────────────────────────────────
local QuickRSSUI = InputContainer:extend{
    name           = "quickrss_ui",
    show_page      = 1,
    articles       = {},     -- all articles (unfiltered)
    filtered       = nil,    -- filtered subset, or nil when showing all
    filter_feed    = nil,    -- name of the active feed filter, or nil for all
    filter_unread  = false,  -- when true, show only unread articles
}

function QuickRSSUI:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Hardware buttons: Back closes, page-turn keys navigate pages.
    -- Each key must be its own sequence entry — Key:match() requires ALL
    -- keys in a single sequence to be pressed simultaneously.
    self.key_events = {
        Close    = { { "Back" }, doc = "close QuickRSS" },
        NextPage = { { "RPgFwd" }, { "LPgFwd" }, doc = "next page" },
        PrevPage = { { "RPgBack" }, { "LPgBack" }, doc = "prev page" },
    }

    -- Swipe left/right to flip pages
    self.ges_events.Swipe = {
        GestureRange:new{
            ges   = "swipe",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        },
    }

    -- ── Title bar ─────────────────────────────────────────────────────────────
    self.title_bar = TitleBar:new{
        width                  = screen_w,
        title                  = Icons.FEEDS .. _(" QuickRSS"),
        with_bottom_line       = true,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:_openMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }
    local title_h = self.title_bar:getSize().h

    -- ── Pagination footer ────────────────────────────────────────────────────
    self.filter_button = Button:new{
        text       = Icons.FILTER .. "  " .. _("All Feeds"),
        callback   = function() self:_openFilterDialog() end,
        bordersize = 0,
    }
    self.prev_button = Button:new{
        icon      = "chevron.left",
        callback  = function() self:prevPage() end,
        bordersize = 0,
    }
    self.next_button = Button:new{
        icon      = "chevron.right",
        callback  = function() self:nextPage() end,
        bordersize = 0,
    }
    self.page_label = TextWidget:new{
        text = _("Page – of –"),
        face = Font:getFace("cfont", 16),
    }

    local btn_h = self.prev_button:getSize().h
    local footer_h = btn_h + PAD * 2

    -- Fixed-width center area so the label stays centred regardless of text length.
    local max_label = TextWidget:new{
        text = T(_("Page %1 of %2"), 99, 99),
        face = Font:getFace("cfont", 16),
    }
    local label_area_w = max_label:getSize().w + PAD * 3
    max_label:free()

    self.page_nav = HorizontalGroup:new{
        align = "center",
        self.prev_button,
        CenterContainer:new{
            dimen = Geom:new{ w = label_area_w, h = btn_h },
            self.page_label,
        },
        self.next_button,
    }

    -- Footer: filter button left-aligned, page nav right-aligned.
    local filter_pad = PAD
    local nav_w = self.page_nav:getSize().w
    local filter_w = self.filter_button:getSize().w
    local spacer_w = math.max(0, screen_w - filter_w - nav_w - filter_pad - PAD)
    self.footer_group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = filter_pad },
        self.filter_button,
        HorizontalSpan:new{ width = spacer_w },
        self.page_nav,
    }
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = footer_h },
        self.footer_group,
    }

    -- ── Article list area ────────────────────────────────────────────────────
    self.list_h         = screen_h - title_h - footer_h
    self.items_per_page = math.max(1, math.floor(self.list_h / ITEM_HEIGHT))
    self.item_width     = screen_w

    -- Spacer height is recalculated on every page turn in _populateItems() so
    -- the footer is always flush with the screen bottom regardless of how many
    -- items appear on the current page (the last page is often a partial page).
    -- Initialise to a full-page height; _populateItems() will correct it.
    self.list_spacer = VerticalSpan:new{ width = 0 }

    -- Populated and cleared by _populateItems() on every page turn
    self.article_list = VerticalGroup:new{ align = "left" }

    -- ── Outer frame: white canvas covering the whole screen ──────────────────
    self.outer_group = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.article_list,
        self.list_spacer,
        footer,
    }
    self[1] = FrameContainer:new{
        width     = screen_w,
        height    = screen_h,
        padding   = 0,
        margin    = 0,
        bordersize = 0,
        background = require("ffi/blitbuffer").COLOR_WHITE,
        self.outer_group,
    }

    -- Load from cache immediately (non-blocking).  If the cache is empty the
    -- user will see a prompt to tap the refresh button.
    self:_loadFromCache()
end

-- Load articles from the on-disk cache and display them immediately.
-- Shows a prompt if the cache is empty.
function QuickRSSUI:_loadFromCache()
    local max_age = Config.getArticleSettings().max_cache_age_days
    local articles = Cache.loadArticles(max_age)
    if #articles == 0 then
        self:_showStatus(_("No articles yet.\nOpen the menu to fetch."))
    else
        sortByDate(articles)
        self.articles = articles
        self:_applyFilter()
    end
end

-- Fetch all configured feeds, save to cache, and repopulate the list.
-- Triggered by the ↻ button in the title bar.
function QuickRSSUI:_fetch()
    self:_showStatus(_("Loading…"))
    -- Force an immediate screen flush so "Loading…" is visible before the
    -- blocking HTTP calls begin (setDirty alone won't repaint until the
    -- main loop regains control, which never happens mid-fetch).
    UIManager:forceRePaint()

    -- Install custom DNS resolver if enabled (bypasses broken system DNS
    -- on some e-readers).  Uninstalled in both success and error callbacks.
    local dns_active = Config.getArticleSettings().custom_dns
    if dns_active then
        require("modules/lib/dns").install()
    end

    local feeds = Config.getFeeds()

    -- Build a lookup of previously cached articles so the parser can skip
    -- FiveFilters for articles it already enriched, and we can skip
    -- thumbnail/inline-image downloads for articles already processed.
    local old_articles = Cache.loadArticles(999999)  -- ignore age
    local cached_by_link = {}
    for _, art in ipairs(old_articles) do
        if art.link and art.link ~= "" then
            cached_by_link[art.link] = art
        end
    end

    Parser.fetchAll(
        feeds,
        function(articles, errors)
            -- Guard: if the user closed the UI while fetching, bail out.
            -- The cache is still saved so the next open picks up results.
            local AR = require("modules/data/images")
            local img_settings = Config.getArticleSettings()

            -- Carry over image_path from cached articles so we don't
            -- re-download thumbnails that are already on disk.
            -- Verify the file still exists — if it was deleted (e.g. by
            -- cleanOrphanedImages after an images-off fetch cycle), skip
            -- the carry-over so the image gets re-downloaded.
            for _, art in ipairs(articles) do
                local cached = cached_by_link[art.link]
                if cached and cached.image_path
                and lfs.attributes(cached.image_path, "mode") == "file" then
                    art.image_path = cached.image_path
                end
            end

            -- Force GC to close lingering SSL sockets from feed fetching
            -- and full-text enrichment.  On e-readers the file descriptor
            -- limit is low; without this, DNS lookups can fail with
            -- "No address associated with hostname" for later requests.
            collectgarbage("collect")

            if img_settings.thumbnails_enabled then
                -- Download thumbnails only for NEW articles (have image_url
                -- but no image_path yet from the cache merge above).
                local thumb_todo = {}
                for _, art in ipairs(articles) do
                    if art.image_url and not art.image_path then
                        table.insert(thumb_todo, art)
                    end
                end
                if #thumb_todo > 0 then
                    local thumb_msg = _("Downloading thumbnails… (%1/%2)")
                    for j, art in ipairs(thumb_todo) do
                        if not self._closed and (j == 1 or j % 5 == 0 or j == #thumb_todo) then
                            self:_showStatus(T(thumb_msg, j, #thumb_todo))
                            UIManager:forceRePaint()
                        end
                        local fname = AR.downloadImage(art.image_url)
                        if fname then
                            art.image_path = AR.IMAGE_DIR .. "/" .. fname
                        end
                    end
                end
            else
                -- Thumbnails disabled: clear image_path so article_item
                -- doesn't render stale thumbnails.
                for _, art in ipairs(articles) do
                    art.image_path = nil
                end
            end

            collectgarbage("collect")

            if img_settings.article_images_enabled then
                -- Pre-download inline images only for articles that still have
                -- remote URLs in their content (skip already-localized ones).
                local img_arts = {}
                for _, art in ipairs(articles) do
                    if art.content
                    and art.content:find("<[Ii][Mm][Gg]")
                    and art.content:find('src%s*=%s*["\']https?://') then
                        table.insert(img_arts, art)
                    end
                end
                if #img_arts > 0 then
                    local img_msg = _("Caching inline images… (%1/%2)")
                    for j, art in ipairs(img_arts) do
                        if not self._closed and (j == 1 or j % 5 == 0 or j == #img_arts) then
                            self:_showStatus(T(img_msg, j, #img_arts))
                            UIManager:forceRePaint()
                        end
                        art.content = AR.localizeImages(AR.constrainImages(art.content))
                    end
                end
            end

            sortByDate(articles)
            Cache.cleanOrphanedImages(articles)
            Cache.saveArticles(articles)

            if dns_active then
                require("modules/lib/dns").uninstall()
            end

            -- If the UI was closed mid-fetch, don't touch the widget tree.
            if self._closed then return end

            if #articles == 0 then
                self:_showStatus(_("No articles found.\nCheck your feeds."))
            else
                -- Preserve read state from old articles
                local old_read = {}
                for _, art in ipairs(self.articles) do
                    if art.read and art.link then old_read[art.link] = true end
                end
                for _, art in ipairs(articles) do
                    if old_read[art.link] then art.read = true end
                end
                -- Filter out dismissed articles
                local dismissed = Cache.loadDismissed()
                if next(dismissed) then
                    local kept = {}
                    for _, art in ipairs(articles) do
                        if not (art.link and dismissed[art.link]) then
                            table.insert(kept, art)
                        end
                    end
                    articles = kept
                end
                Cache.saveArticles(articles)
                self.articles = articles
                self:_applyFilter()

                -- Notify about partial failures (some feeds succeeded, some didn't)
                if errors and #errors > 0 then
                    local Notification = require("ui/widget/notification")
                    UIManager:show(Notification:new{
                        text = T(_("%1 feed(s) failed to load"), #errors),
                    })
                end
            end
        end,
        function(err)
            if dns_active then
                require("modules/lib/dns").uninstall()
            end
            if not self._closed then
                self:_showStatus(T(_("Could not load feeds:\n%1"), err))
            end
        end,
        function(name, i, total)
            self:_showStatus(T(_("Fetching %1…\n(%2 of %3)"), name, i, total))
            UIManager:forceRePaint()
        end,
        function(msg)
            self:_showStatus(msg)
            UIManager:forceRePaint()
        end,
        cached_by_link
    )
end

-- Show a centred status message (used for "Loading…" and error states).
-- Also disables the footer buttons since there are no pages to navigate.
function QuickRSSUI:_showStatus(message)
    self.article_list:clear()
    self.article_list:resetLayout()

    -- Use the full list area height so the placeholder is centred in the
    -- available space and the footer remains at the bottom of the screen.
    self.list_spacer.width = 0
    table.insert(self.article_list, CenterContainer:new{
        dimen = Geom:new{
            w = self.item_width,
            h = self.list_h,
        },
        TextBoxWidget:new{
            text      = message,
            face      = Font:getFace("cfont", 18),
            width     = self.item_width - Size.padding.large * 2,
            alignment = "center",
        },
    })

    self.page_label:setText("–")
    self.footer_group:resetLayout()
    self.prev_button:enableDisable(false)
    self.next_button:enableDisable(false)

    self.outer_group:resetLayout()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Show the hamburger dropdown menu.
function QuickRSSUI:_openMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            -- Primary action: full-width fetch button
            {{ text = Icons.FETCH .. "  " .. _("Fetch Articles"), callback = function()
                UIManager:close(dialog)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Fetch articles from all feeds?\nThis may take a moment."),
                    ok_text = _("Fetch"),
                    ok_callback = function()
                        -- Defer to next tick so the ConfirmBox visually
                        -- closes before the blocking fetch begins.
                        UIManager:nextTick(function() self:_fetch() end)
                    end,
                })
            end }},
            -- Config actions: two buttons side by side
            {
                { text = Icons.FEEDS    .. "  " .. _("Feeds"),    callback = function()
                    UIManager:close(dialog)
                    self:_openFeedList()
                end },
                { text = Icons.SETTINGS .. "  " .. _("Settings"), callback = function()
                    UIManager:close(dialog)
                    self:_openSettings()
                end },
            },
            -- Destructive actions side by side
            {
                { text = Icons.CLEAR .. "  " .. _("Clear Read"), callback = function()
                    UIManager:close(dialog)
                    self:_clearReadArticles()
                end },
                { text = Icons.CLEAR .. "  " .. _("Clear Cache"), callback = function()
                    UIManager:close(dialog)
                    self:_clearCache()
                end },
            },
            {{ text = Icons.INFO .. "  " .. _("About"), callback = function()
                UIManager:close(dialog)
                self:_openAbout()
            end }},
        },
    }
    UIManager:show(dialog)
end

-- Ask for confirmation, then wipe the article cache and images.
function QuickRSSUI:_clearCache()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Clear all cached articles and images?"),
        ok_text = _("Clear"),
        ok_callback = function()
            Cache.clearCache()
            self.articles      = {}
            self.filtered      = nil
            self.filter_feed   = nil
            self.filter_unread = false
            self.show_page     = 1
            self:_updateFilterButton()
            self:_showStatus(_("Cache cleared.\nOpen the menu to fetch."))
        end,
    })
end

-- Remove all read articles from the cache and remember their links so
-- they don't reappear on future fetches.
function QuickRSSUI:_clearReadArticles()
    local read_count = 0
    for _, art in ipairs(self.articles) do
        if art.read then read_count = read_count + 1 end
    end
    if read_count == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No read articles to clear."),
        })
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear %1 read article(s)?\nThey won't reappear on future fetches."), read_count),
        ok_text = _("Clear"),
        ok_callback = function()
            -- Add read article links to the dismissed set
            local dismissed = Cache.loadDismissed()
            local kept = {}
            for _, art in ipairs(self.articles) do
                if art.read and art.link then
                    dismissed[art.link] = true
                    if art.image_path then os.remove(art.image_path) end
                else
                    table.insert(kept, art)
                end
            end
            Cache.saveDismissed(dismissed)
            self.articles = kept
            Cache.saveArticles(self.articles)
            Cache.cleanOrphanedImages(self.articles)
            self:_applyFilter()
        end,
    })
end

-- Open the settings popup.  When it closes, re-render the feed list so
-- toggling images takes effect immediately without a re-fetch.
function QuickRSSUI:_openSettings()
    local SettingsUI = require("modules/ui/settings")
    UIManager:show(SettingsUI:new{
        on_close = function()
            if #self.articles > 0 then
                self:_populateItems()
            end
        end,
    })
end

-- Open the feed management popup.
function QuickRSSUI:_openFeedList()
    local FeedListUI = require("modules/ui/feed_list")
    UIManager:show(FeedListUI:new{
        reload_callback = function() self:_loadFromCache() end,
    })
end

-- Show a brief about dialog.
function QuickRSSUI:_openAbout()
    UIManager:show(InfoMessage:new{
        text = "QuickRSS v0.2.1\n"
            .. "by qewer33\n\n"
            .. "A fast, standalone RSS reader for KOReader.\n\n"
            .. "Feeds are stored in quickrss/feeds.opml in your KOReader "
            .. "data directory. Edit or replace it on "
            .. "your computer to manage subscriptions, or import a file "
            .. "exported from another RSS reader.",
    })
end

-- Apply the current feed + unread filters and rebuild the displayed list.
function QuickRSSUI:_applyFilter(keep_page)
    local list = self.articles
    if self.filter_feed then
        local by_feed = {}
        for _, art in ipairs(list) do
            if art.source == self.filter_feed then
                table.insert(by_feed, art)
            end
        end
        list = by_feed
    end
    if self.filter_unread then
        local unread = {}
        for _, art in ipairs(list) do
            if not art.read then
                table.insert(unread, art)
            end
        end
        list = unread
    end
    self.filtered = (list ~= self.articles) and list or nil
    if not keep_page then
        self.show_page = 1
    end
    self:_populateItems()
end

-- Open a dialog to pick feed filter and unread toggle.
function QuickRSSUI:_openFilterDialog()
    -- Collect unique feed names from articles
    local seen = {}
    local feed_names = {}
    for _, art in ipairs(self.articles) do
        if art.source and not seen[art.source] then
            seen[art.source] = true
            table.insert(feed_names, art.source)
        end
    end
    table.sort(feed_names)

    local check = "\u{f00c}  "  -- NerdFont check mark prefix
    local dialog
    local buttons = {
        -- Unread toggle at the top
        {{ text = Icons.BOOK .. "  " .. (self.filter_unread
                and _("Showing Unread Only")
                or  _("Show Unread Only")),
           callback = function()
               UIManager:close(dialog)
               self.filter_unread = not self.filter_unread
               self:_updateFilterButton()
               self:_applyFilter()
           end
        }},
        -- All Feeds
        {{ text = (self.filter_feed == nil and check or "") .. _("All Feeds"),
           callback = function()
               UIManager:close(dialog)
               self.filter_feed = nil
               self:_updateFilterButton()
               self:_applyFilter()
           end
        }},
    }
    for _, name in ipairs(feed_names) do
        table.insert(buttons, {
            { text = (self.filter_feed == name and check or "") .. name,
              callback = function()
                  UIManager:close(dialog)
                  self.filter_feed = name
                  self:_updateFilterButton()
                  self:_applyFilter()
              end
            }
        })
    end

    dialog = ButtonDialog:new{
        title = _("Filter Articles"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Update the filter button text to reflect current feed + unread state.
function QuickRSSUI:_updateFilterButton()
    local label = Icons.FILTER .. "  "
    if self.filter_feed then
        label = label .. self.filter_feed
    else
        label = label .. _("All Feeds")
    end
    if self.filter_unread then
        label = label .. " (" .. _("Unread") .. ")"
    end
    self.filter_button:setText(label)
    self:_rebuildFooter()
end

-- Rebuild footer layout after filter button text changes.
function QuickRSSUI:_rebuildFooter()
    local screen_w = Screen:getWidth()
    local filter_pad = PAD
    local nav_w = self.page_nav:getSize().w
    local filter_w = self.filter_button:getSize().w
    local spacer_w = math.max(0, screen_w - filter_w - nav_w - filter_pad - PAD)

    self.footer_group:clear()
    self.footer_group:resetLayout()
    table.insert(self.footer_group, HorizontalSpan:new{ width = filter_pad })
    table.insert(self.footer_group, self.filter_button)
    table.insert(self.footer_group, HorizontalSpan:new{ width = spacer_w })
    table.insert(self.footer_group, self.page_nav)
end

-- Long-press context menu for a single article.
function QuickRSSUI:_showArticleMenu(article)
    local ArticleMenu = require("modules/ui/article_menu")
    ArticleMenu.show(article, self.articles, function()
        self:_applyFilter(true)
    end)
end

-- Rebuild article_list for the current page and request a display refresh.
function QuickRSSUI:_populateItems()
    local articles = self.filtered or self.articles
    local total    = #articles

    self.pages     = math.max(1, math.ceil(total / self.items_per_page))
    self.show_page = math.min(self.show_page, self.pages)

    -- Clear stale widgets and invalidate the cached layout size
    self.article_list:clear()
    self.article_list:resetLayout()

    local start_idx   = (self.show_page - 1) * self.items_per_page + 1
    local end_idx     = math.min(start_idx + self.items_per_page - 1, total)
    local page_count  = end_idx - start_idx + 1
    local sep_h       = Size.line.thin
    local content_h   = page_count * ITEM_HEIGHT
                      + math.max(0, page_count - 1) * sep_h
    local remaining   = math.max(0, self.list_h - content_h)
    local gap_count   = math.max(1, page_count - 1)
    local gap         = (page_count > 1) and math.floor(remaining / gap_count) or 0
    local extra_px    = (page_count > 1) and (remaining - gap * gap_count) or remaining
    self.list_spacer.width = extra_px

    local art_settings = require("modules/data/config").getArticleSettings()
    for i = start_idx, end_idx do
        local item = ArticleItem:new{
            width        = self.item_width,
            height       = ITEM_HEIGHT,
            article      = articles[i],
            art_settings = art_settings,
            -- Tap opens the article in the HTML reader.
            callback = function(article)
                if not article.read then
                    article.read = true
                    Cache.saveArticles(self.articles)
                    if self.filter_unread then
                        self:_applyFilter(true)
                    else
                        self:_populateItems()
                    end
                end
                local InfoMessage = require("ui/widget/infomessage")
                local msg = InfoMessage:new{
                    text = _("Opening ") .. article.title,
                    timeout = 30,
                }
                UIManager:show(msg)
                UIManager:nextTick(function()
                    local ArticleReader = require("modules/ui/article_reader")
                    UIManager:show(ArticleReader:new{
                        article       = article,
                        articles      = articles,
                        article_index = i,
                        on_close      = function()
                            Cache.saveArticles(self.articles)
                            if self.filter_unread then
                                self:_applyFilter(true)
                            else
                                self:_populateItems()
                            end
                        end,
                    })
                    UIManager:close(msg)
                end)
            end,
            hold_callback = function(article)
                self:_showArticleMenu(article)
            end,
        }
        table.insert(self.article_list, item)

        -- Dynamic-height separator between rows (omitted after the last item)
        if i < end_idx then
            local pad_top    = math.floor(gap / 2)
            local pad_bottom = gap - pad_top
            if pad_top > 0 then
                table.insert(self.article_list, VerticalSpan:new{ width = pad_top })
            end
            table.insert(self.article_list, LineWidget:new{
                background = require("ffi/blitbuffer").COLOR_LIGHT_GRAY,
                dimen      = Geom:new{ w = self.item_width, h = sep_h },
                style      = "solid",
            })
            if pad_bottom > 0 then
                table.insert(self.article_list, VerticalSpan:new{ width = pad_bottom })
            end
        end
    end

    -- Update footer controls
    self.page_label:setText(T(_("Page %1 of %2"), self.show_page, self.pages))
    self.footer_group:resetLayout()
    self.prev_button:enableDisable(self.show_page > 1)
    self.next_button:enableDisable(self.show_page < self.pages)

    self.outer_group:resetLayout()

    -- Full e-ink flash every 3 page turns to clear ghosting; fast partial
    -- update ("ui") on the others for snappy navigation.
    self._page_turn_count = (self._page_turn_count or 0) + 1
    local refresh_mode = (self._page_turn_count % 3 == 0) and "full" or "ui"
    UIManager:setDirty(self, function()
        return refresh_mode, self.dimen
    end)
end

function QuickRSSUI:nextPage()
    if self.show_page < self.pages then
        self.show_page = self.show_page + 1
        self:_populateItems()
    end
end

function QuickRSSUI:prevPage()
    if self.show_page > 1 then
        self.show_page = self.show_page - 1
        self:_populateItems()
    end
end

function QuickRSSUI:onSwipe(_, ges_ev)
    if ges_ev.direction == "west" then
        self:nextPage()
        return true
    elseif ges_ev.direction == "east" then
        self:prevPage()
        return true
    elseif ges_ev.direction == "northeast"
        or ges_ev.direction == "northwest"
        or ges_ev.direction == "southeast"
        or ges_ev.direction == "southwest" then
        UIManager:setDirty(nil, "full", nil, true)
        return false
    end
end

function QuickRSSUI:onNextPage()
    self:nextPage()
    return true
end

function QuickRSSUI:onPrevPage()
    self:prevPage()
    return true
end

function QuickRSSUI:onClose()
    self._closed = true
    UIManager:close(self)
end

return QuickRSSUI
