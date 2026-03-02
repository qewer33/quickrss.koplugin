local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Icons = require("modules/ui/icons")
local _ = require("gettext")

local QuickRSS = WidgetContainer:extend{
    name = "quickrss",
    is_doc_only = false,
}

function QuickRSS:init()
    self.ui.menu:registerToMainMenu(self)
end

function QuickRSS:addToMainMenu(menu_items)
    menu_items.quickrss = {
        text = Icons.FEEDS .. " " .. _("QuickRSS"),
        sorting_hint = "search",
        callback = function()
            local QuickRSSUI = require("modules/ui/feed_view")
            UIManager:show(QuickRSSUI:new{})
        end,
    }
end

return QuickRSS
