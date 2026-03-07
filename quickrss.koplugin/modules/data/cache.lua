-- QuickRSS: Article Cache
-- Persists the last-fetched article list to disk so the plugin opens
-- instantly without a network round-trip.
--
-- Public API:
--   Cache.loadArticles(max_age_days)    → articles table (empty if stale or missing)
--   Cache.saveArticles(articles)        persists articles + last_fetched_at timestamp
--   Cache.clearCache()                  wipes articles, timestamp, and all images
--   Cache.cleanOrphanedImages(articles) deletes cached images not in article list

local DataStorage = require("datastorage")
local Images      = require("modules/data/images")
local lfs         = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local logger      = require("logger")

local CACHE_FILE = DataStorage:getDataDir() .. "/quickrss/cache.lua"
local IMAGE_DIR  = Images.IMAGE_DIR

local _settings
local function settings()
    if not _settings then
        _settings = LuaSettings:open(CACHE_FILE)
    end
    return _settings
end

local Cache = {}

-- Returns the cached article list, filtering out articles older than
-- max_age_days on a per-article basis.  Pass 0 or nil to skip age filtering.
function Cache.loadArticles(max_age_days)
    local all = settings():readSetting("articles") or {}
    if not max_age_days or max_age_days <= 0 then return all end

    local cutoff = os.time() - max_age_days * 86400
    local fresh  = {}
    for _, art in ipairs(all) do
        if (art.fetched_at or 0) >= cutoff then
            table.insert(fresh, art)
        end
    end
    return fresh
end

-- Persists articles to disk.  Stamps any article that lacks a fetched_at
-- timestamp with the current time (new articles from this fetch cycle).
function Cache.saveArticles(articles)
    local now = os.time()
    for _, art in ipairs(articles) do
        if not art.fetched_at then
            art.fetched_at = now
        end
    end
    settings()
        :saveSetting("articles", articles)
        :flush()
end

-- Wipes the entire article cache and all cached images.
-- After this call loadArticles() returns {} until the next fetch.
function Cache.clearCache()
    settings()
        :saveSetting("articles", nil)
        :saveSetting("dismissed", nil)
        :flush()
    -- Reset the in-memory handle so next load re-reads from disk cleanly
    _settings = nil

    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return end
    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if not removed then
                logger.warn("QuickRSS: could not remove cached image:", path, err)
            end
        end
    end
end

-- Returns the set of dismissed article links (articles the user deleted after
-- reading).  These are excluded from future fetches so they don't reappear.
function Cache.loadDismissed()
    return settings():readSetting("dismissed") or {}
end

-- Persists the dismissed link set.
function Cache.saveDismissed(dismissed)
    settings()
        :saveSetting("dismissed", dismissed)
        :flush()
end

-- Deletes image files in IMAGE_DIR that are not referenced by any article.
-- Called after every fetch so the image cache doesn't grow unboundedly.
function Cache.cleanOrphanedImages(articles)
    -- Build a set of filenames still in use (thumbnails + inline images)
    local live = {}
    for _, art in ipairs(articles) do
        if art.image_path then
            local fname = art.image_path:match("([^/]+)$")
            if fname then live[fname] = true end
        end
        -- Inline images already localized into content HTML
        if art.content then
            for fname in art.content:gmatch('[Ss][Rr][Cc]%s*=%s*"([^"/]+)"') do
                live[fname] = true
            end
            for fname in art.content:gmatch("[Ss][Rr][Cc]%s*=%s*'([^'/]+)'") do
                live[fname] = true
            end
        end
    end

    -- Walk IMAGE_DIR and remove anything not in the live set
    local ok = lfs.attributes(IMAGE_DIR, "mode") == "directory"
    if not ok then return end

    for fname in lfs.dir(IMAGE_DIR) do
        if fname ~= "." and fname ~= ".." and not live[fname] then
            local path = IMAGE_DIR .. "/" .. fname
            local removed, err = os.remove(path)
            if removed then
                logger.dbg("QuickRSS: removed orphan image:", fname)
            else
                logger.warn("QuickRSS: could not remove orphan image:", path, err)
            end
        end
    end
end

return Cache
