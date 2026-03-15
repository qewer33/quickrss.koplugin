-- QuickRSS: Shared article context menu
-- Shows article info (title, source, date, link) and action buttons.
-- Used by both feed_view (long-press on card) and article_reader (tap title).
--
-- Usage:
--   ArticleMenu.show(article, articles, on_change)
--     article   – the article table
--     articles  – full articles list (for saving/deleting)
--     on_change – callback after any modification (toggle read, delete)

local ButtonDialog   = require("ui/widget/buttondialog")
local Cache          = require("modules/data/cache")
local Device         = require("device")
local Font           = require("ui/font")
local Icons          = require("modules/ui/icons")
local Notification   = require("ui/widget/notification")
local QRMessage      = require("ui/widget/qrmessage")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local _              = require("gettext")

local Screen = require("device").screen

local ArticleMenu = {}

function ArticleMenu.show(article, articles, on_change)
    local meta_parts = {}
    if article.source and article.source ~= "" then
        table.insert(meta_parts, article.source)
    end
    if article.date and article.date ~= "" then
        local d = article.date:match("%a+,%s+(%d+%s+%a+%s+%d+)")
            or article.date:match("(%d%d%d%d%-%d%d%-%d%d)")
            or article.date
        table.insert(meta_parts, d)
    end
    local dialog
    dialog = ButtonDialog:new{
        title = article.title,
        use_info_style = false,
        buttons = {
            {{ text = Icons.SAVE .. "  " .. (article.saved and _("Unsave Article") or _("Save Article")), callback = function()
                UIManager:close(dialog)
                article.saved = not article.saved
                Cache.saveArticles(articles)
                if on_change then on_change() end
            end }},
            {{ text = Icons.COPY .. "  " .. _("Copy Link"), callback = function()
                UIManager:close(dialog)
                if article.link and article.link ~= "" then
                    Device.input.setClipboardText(article.link)
                    UIManager:show(Notification:new{
                        text = _("Link copied to clipboard"),
                    })
                end
            end }},
            {{ text = Icons.INFO .. "  " .. _("Show QR Code"), callback = function()
                UIManager:close(dialog)
                if article.link and article.link ~= "" then
                    UIManager:show(QRMessage:new{
                        text   = article.link,
                        width  = Screen:getWidth(),
                        height = Screen:getHeight(),
                    })
                end
            end }},
            {{ text = Icons.BOOK .. "  " .. (article.read and _("Mark as Unread") or _("Mark as Read")), callback = function()
                UIManager:close(dialog)
                article.read = not article.read
                Cache.saveArticles(articles)
                if on_change then on_change() end
            end }},
            {{ text = Icons.CLEAR .. "  " .. _("Delete From Cache"), callback = function()
                UIManager:close(dialog)
                for i = #articles, 1, -1 do
                    if articles[i] == article then
                        table.remove(articles, i)
                        break
                    end
                end
                if article.image_path then
                    os.remove(article.image_path)
                end
                Cache.saveArticles(articles)
                Cache.cleanOrphanedImages(articles)
                if on_change then on_change() end
            end }},
        },
    }
    local extra = VerticalGroup:new{ align = "left" }
    if #meta_parts > 0 then
        table.insert(extra, TextBoxWidget:new{
            text      = table.concat(meta_parts, " · "),
            face      = Font:getFace("cfont", 14),
            width     = dialog.title_group_width,
            alignment = "left",
        })
    end
    if article.link and article.link ~= "" then
        if #meta_parts > 0 then
            table.insert(extra, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        end
        table.insert(extra, TextBoxWidget:new{
            text      = article.link,
            face      = Font:getFace("cfont", 12),
            width     = dialog.title_group_width,
            alignment = "left",
        })
    end
    if #extra > 0 then
        dialog:addWidget(extra)
    end
    UIManager:show(dialog)
end

return ArticleMenu
