-- QuickRSS: Config Module
-- Persists the user's feed list and article-limit settings to a dedicated
-- settings file.
--
-- Feed list is stored as a standard OPML file (feeds.opml) so it
-- can be edited on a computer or imported from another RSS reader.
-- All other settings (article limits, reader prefs) live in settings.lua.
--
-- All data lives under <koreader data dir>/quickrss/
--
-- Public API:
--   Config.getFeeds()                    → { { name, url }, … }
--   Config.saveFeeds(feeds)              saves and flushes to disk
--   Config.getArticleSettings()          → { items_per_feed, max_cache_age_days }
--   Config.saveArticleSettings(s)        saves and flushes to disk
--   Config.getReaderSettings()           → { font_face, font_size, line_spacing }
--   Config.saveReaderSettings(s)         saves and flushes to disk

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local OPML        = require("modules/data/opml")

local BASE_DIR      = DataStorage:getDataDir() .. "/quickrss"
lfs.mkdir(BASE_DIR)  -- no-op if already exists
local SETTINGS_FILE = BASE_DIR .. "/settings.lua"

-- Shown the first time the plugin is opened before the user adds their own feeds
local DEFAULT_FEEDS = {
    { name = "Ars Technica", url = "feeds.arstechnica.com/arstechnica/index" },
}

local DEFAULT_ARTICLE_SETTINGS = {
    items_per_feed         = 20,    -- most-recent articles to keep per feed
    max_cache_age_days     = 10,    -- treat cache as empty after this many days (0 = never)
    thumbnails_enabled     = true,  -- download and display feed-list thumbnails
    article_images_enabled = true,  -- download and display images inside articles
    card_font_size         = 14,    -- base font size for article cards in feed list
    fulltext_enabled       = true,  -- fetch full article text for truncated feeds
    fulltext_url           = "https://ftr.fivefilters.net/makefulltextfeed.php",
    custom_dns             = false, -- use custom DNS resolver to bypass system DNS bugs
}

-- Lazily opened so require("modules/config") doesn't touch the filesystem
local _settings
local function settings()
    if not _settings then
        _settings = LuaSettings:open(SETTINGS_FILE)
    end
    return _settings
end

local Config = {}

function Config.getFeeds()
    -- Primary source: OPML file (editable on the computer)
    local feeds = OPML.read()
    if feeds and #feeds > 0 then return feeds end

    -- One-time migration: if the old quickrss.lua has feeds, move them to OPML
    -- and remove from the Lua settings so this path is never taken again.
    local old = settings():readSetting("feeds")
    if old and #old > 0 then
        OPML.write(nil, old)
        settings():saveSetting("feeds", nil):flush()
        return old
    end

    -- First-run defaults
    local copy = {}
    for _, f in ipairs(DEFAULT_FEEDS) do
        table.insert(copy, { name = f.name, url = f.url })
    end
    return copy
end

function Config.saveFeeds(feeds)
    OPML.write(nil, feeds)
end

function Config.getArticleSettings()
    local saved = settings():readSetting("article_settings")
    -- Merge with defaults so new keys always have a value even after upgrades.
    -- Booleans need explicit nil-check: `false or default` would use the default.
    local thumb = DEFAULT_ARTICLE_SETTINGS.thumbnails_enabled
    if saved and saved.thumbnails_enabled ~= nil then
        thumb = saved.thumbnails_enabled
    end
    local art_img = DEFAULT_ARTICLE_SETTINGS.article_images_enabled
    if saved and saved.article_images_enabled ~= nil then
        art_img = saved.article_images_enabled
    end
    local ft = DEFAULT_ARTICLE_SETTINGS.fulltext_enabled
    if saved and saved.fulltext_enabled ~= nil then
        ft = saved.fulltext_enabled
    end
    local cdns = DEFAULT_ARTICLE_SETTINGS.custom_dns
    if saved and saved.custom_dns ~= nil then
        cdns = saved.custom_dns
    end
    -- Numeric fields also need nil-checks: `0 or default` would use the default,
    -- which silently breaks max_cache_age_days = 0 ("Never expire").
    local function num(key)
        if saved and saved[key] ~= nil then return saved[key] end
        return DEFAULT_ARTICLE_SETTINGS[key]
    end
    return {
        items_per_feed         = num("items_per_feed"),
        max_cache_age_days     = num("max_cache_age_days"),
        thumbnails_enabled     = thumb,
        article_images_enabled = art_img,
        card_font_size         = num("card_font_size"),
        fulltext_enabled       = ft,
        fulltext_url           = (saved and saved.fulltext_url)       or DEFAULT_ARTICLE_SETTINGS.fulltext_url,
        custom_dns             = cdns,
    }
end

function Config.saveArticleSettings(s)
    settings():saveSetting("article_settings", s):flush()
end

local DEFAULT_READER_SETTINGS = {
    font_file    = "",   -- "" = let MuPDF use its default serif
    font_size    = 21.0, -- pt (matches KOReader's default)
    line_spacing = 15,   -- x10 (15 → 1.5)
}

function Config.getReaderSettings()
    local saved = settings():readSetting("reader_settings")
    local function val(key)
        if saved and saved[key] ~= nil then return saved[key] end
        return DEFAULT_READER_SETTINGS[key]
    end
    return {
        font_file    = val("font_file"),
        font_size    = val("font_size"),
        line_spacing = val("line_spacing"),
    }
end

function Config.saveReaderSettings(s)
    settings():saveSetting("reader_settings", s):flush()
end

return Config
