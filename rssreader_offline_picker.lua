--[[
Offline Mode feed picker: accounts → folders → feeds, where tapping a feed
ticks or unticks it. Opens with the last selection ticked, and saves the
selection on every tap, so leaving the picker never loses it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Commons = require("rssreader_commons")
local OfflineStore = require("rssreader_offline_store")
local OfflineDownload = require("rssreader_offline_download")
local backends = require("rssreader_menu_backends")
local utils = require("rssreader_menu_utils")

local OfflinePicker = {}

local CHECK = "✓ "

-- Only these fields of a tree node are needed to fetch its stories later.
local NODE_FIELDS = {
    "id", "url", "api_feed_id", "is_special_feed", "read_filter_override",
    "is_virtual", "virtual_type",
}

local function selectionEntry(account, node, parent)
    local title = node.title or tostring(node.id)
    -- "★ All Unread" means little on its own once it sits in the Offline
    -- list; name the folder it aggregates.
    if parent and parent.kind == "folder" and parent.title and (title:find("^★") or node._tag) then
        title = parent.title .. " · " .. title
    end
    local stored_node = {}
    for _i, field in ipairs(NODE_FIELDS) do
        stored_node[field] = node[field]
    end
    if node._tag then
        stored_node.tag_name = node.title
    end
    return {
        account = account.name,
        account_type = account.type,
        feed_id = tostring(node.id or node.url),
        title = title,
        node = stored_node,
    }
end

local function collectFeedIds(node, into)
    into = into or {}
    for _i, child in ipairs(node.children or {}) do
        if child.kind == "feed" then
            into[tostring(child.id or child.url)] = true
        elseif child.kind == "folder" then
            collectFeedIds(child, into)
        end
    end
    return into
end

-- Aggregated views (★ All Feeds / ★ All Unread, FreshRSS's special feeds)
-- repeat the stories of the real feeds next to them.
local function isVirtualFeed(node)
    return node._virtual or node.is_virtual or node.is_special_feed
        or (type(node.title) == "string" and node.title:find("^★") ~= nil)
end

-- Every feed under a folder, its subfolders included, with the folder each
-- one sits in. Virtual feeds only with include_virtual: ticking them along
-- with the real ones would download every story twice.
local function collectFeedNodes(node, include_virtual, into)
    into = into or {}
    for _i, child in ipairs(node.children or {}) do
        if child.kind == "feed" and (include_virtual or not isVirtualFeed(child)) then
            table.insert(into, { node = child, parent = node })
        elseif child.kind == "folder" and not child._tags_root then
            collectFeedNodes(child, include_virtual, into)
        end
    end
    return into
end

local function countSuffix(count)
    if count > 0 then
        return " (" .. tostring(count) .. ")"
    end
    return ""
end

-- Redraws the menu on screen in place, on the same page.
local function refreshMenu(menu, title, build_items)
    if menu and menu.switchItemTable then
        menu:switchItemTable(title, build_items(), -1)
    end
end

-- ────────────────────────────────────────────────────────────
-- Tree level (remote folders and local groups share this)
-- ────────────────────────────────────────────────────────────

function OfflinePicker.showNode(builder, account, node)
    local menu
    local function buildItems()
        local selection = OfflineStore.getSelection()
        local items = {}
        for _i, child in ipairs(node.children or {}) do
            if child.kind == "folder" and child._tags_root then
                -- CommaFeed's tags load on demand; count the picked ones by id.
                local count = 0
                for _j, entry in ipairs(selection) do
                    if entry.account == account.name and tostring(entry.feed_id):find("^__commafeed_tag__") then
                        count = count + 1
                    end
                end
                table.insert(items, {
                    text = (child.title or _("Tags")) .. countSuffix(count),
                    callback = function()
                        OfflinePicker.showTags(builder, account, child)
                    end,
                })
            elseif child.kind == "folder" then
                local count = OfflineStore.countSelectedIn(selection, account.name, collectFeedIds(child))
                table.insert(items, {
                    text = (child.title or _("Untitled folder")) .. countSuffix(count),
                    callback = function()
                        OfflinePicker.showNode(builder, account, child)
                    end,
                    hold_callback = function()
                        OfflinePicker.showFolderHoldDialog(account, child, function()
                            refreshMenu(menu, nil, buildItems)
                        end)
                    end,
                    hold_keep_menu_open = true,
                })
            elseif child.kind == "feed" then
                local feed_id = tostring(child.id or child.url)
                local selected = OfflineStore.isSelected(selection, account.name, feed_id)
                table.insert(items, {
                    text = (selected and CHECK or "") .. (child.title or _("Untitled feed")),
                    bold = selected,
                    keep_menu_open = true,
                    callback = function()
                        local current = OfflineStore.getSelection()
                        OfflineStore.toggleSelection(current, selectionEntry(account, child, node))
                        OfflineStore.saveSelection(current)
                        refreshMenu(menu, nil, buildItems)
                    end,
                })
            end
        end
        if #items == 0 then
            table.insert(items, { text = _("No feeds here."), keep_menu_open = true, callback = function() end })
        end
        return items
    end

    menu = Menu:new{
        title = node.title or Commons.accountTitle(account),
        item_table = buildItems(),
    }
    menu.onMenuHold = utils.triggerHoldCallback
    builder:showMenu(menu, function()
        OfflinePicker.showNode(builder, account, node)
    end)
end

-- Long-press on a folder: tick or untick every feed in it (subfolders too).
function OfflinePicker.showFolderHoldDialog(account, folder, on_change)
    local feeds = collectFeedNodes(folder, false)
    local all_feeds = collectFeedNodes(folder, true)
    local selection = OfflineStore.getSelection()
    local function countTicked(list)
        local count = 0
        for _i, feed in ipairs(list) do
            if OfflineStore.isSelected(selection, account.name, tostring(feed.node.id or feed.node.url)) then
                count = count + 1
            end
        end
        return count
    end
    local selected_count = countTicked(feeds)
    local any_ticked = countTicked(all_feeds) > 0

    local dialog
    local function apply(tick)
        UIManager:close(dialog)
        local current = OfflineStore.getSelection()
        for _i, feed in ipairs(tick and feeds or all_feeds) do
            local feed_id = tostring(feed.node.id or feed.node.url)
            local index = OfflineStore.selectionIndex(current, account.name, feed_id)
            if tick and not index then
                table.insert(current, selectionEntry(account, feed.node, feed.parent))
            elseif not tick and index then
                table.remove(current, index)
            end
        end
        OfflineStore.saveSelection(current)
        on_change()
    end

    dialog = ButtonDialog:new{
        title = T(_("%1\n%2 of %3 feeds ticked"), folder.title or _("Folder"), selected_count, #feeds),
        title_align = "center",
        buttons = {
            {{
                text = _("Tick all feeds"),
                enabled = selected_count < #feeds,
                callback = function()
                    apply(true)
                end,
            }},
            {{
                text = _("Untick all feeds"),
                enabled = any_ticked,
                callback = function()
                    apply(false)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- CommaFeed's ★ Tags folder: its tags are fetched when it is opened.
function OfflinePicker.showTags(builder, account, node)
    local client = OfflineDownload.getClient(builder, account)
    if not client or type(client.fetchTags) ~= "function" then
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, tags_or_err = client:fetchTags()
        if not ok then
            UIManager:show(InfoMessage:new{ text = tags_or_err or _("Failed to load tags.") })
            return
        end
        local folder = { kind = "folder", title = node.title or _("Tags"), children = {} }
        for _i, tag in ipairs(tags_or_err or {}) do
            local name = type(tag) == "table" and (tag.name or tag.tag) or tostring(tag)
            local count = type(tag) == "table" and (tag.count or tag.unreadCount) or nil
            if name and name ~= "" then
                table.insert(folder.children, client:getTagNode(name, count))
            end
        end
        OfflinePicker.showNode(builder, account, folder)
    end)
end

local function localTree(builder, account)
    local function feedNode(feed)
        return { kind = "feed", id = feed.url, url = feed.url, title = feed.title or feed.url }
    end
    local children = {}
    for _i, feed in ipairs(builder.local_store:listFeeds(account.name)) do
        if feed.url then
            table.insert(children, feedNode(feed))
        end
    end
    for _i, group in ipairs(builder.local_store:listGroups(account.name)) do
        local folder = { kind = "folder", title = group.title or _("Local Group"), children = {} }
        for _j, feed in ipairs(group.feeds or {}) do
            if feed.url then
                table.insert(folder.children, feedNode(feed))
            end
        end
        table.insert(children, folder)
    end
    return { kind = "root", title = Commons.accountTitle(account), children = children }
end

function OfflinePicker.showAccount(builder, account)
    if account.type == "local" then
        OfflinePicker.showNode(builder, account, localTree(builder, account))
        return
    end

    local client, err = OfflineDownload.getClient(builder, account)
    if not client then
        UIManager:show(InfoMessage:new{ text = err or _("Unable to open account.") })
        return
    end

    local function showTree(tree)
        local root = { kind = "root", title = Commons.accountTitle(account), children = {} }
        if account.type == "freshrss" then
            for _i, special in ipairs(backends.freshRSSSpecialChildren(account, client)) do
                table.insert(root.children, special)
            end
        end
        for _i, child in ipairs(tree.children or {}) do
            table.insert(root.children, child)
        end
        OfflinePicker.showNode(builder, account, root)
    end

    -- A tree already loaded this session is good enough for picking.
    if client.tree_cache then
        showTree(client.tree_cache)
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok or type(tree_or_err) ~= "table" then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load subscriptions."),
            })
            return
        end
        showTree(tree_or_err)
    end)
end

-- ────────────────────────────────────────────────────────────
-- Root: actions + accounts
-- ────────────────────────────────────────────────────────────

-- The feeds picked so far in one flat list; tapping one unticks it.
function OfflinePicker.showSelected(builder)
    local menu
    local function buildItems()
        local items = {}
        for _i, entry in ipairs(OfflineStore.getSelection()) do
            table.insert(items, {
                text = CHECK .. (entry.title or entry.feed_id) .. "  —  " .. tostring(entry.account),
                keep_menu_open = true,
                callback = function()
                    local current = OfflineStore.getSelection()
                    OfflineStore.toggleSelection(current, entry)
                    OfflineStore.saveSelection(current)
                    refreshMenu(menu, T(_("Selected feeds (%1)"), #current), buildItems)
                end,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("No feeds selected."), keep_menu_open = true, callback = function() end })
        end
        return items
    end
    menu = Menu:new{
        title = T(_("Selected feeds (%1)"), #OfflineStore.getSelection()),
        item_table = buildItems(),
    }
    builder:showMenu(menu, function()
        OfflinePicker.showSelected(builder)
    end)
end

-- on_download_done: passed to the download runner (refreshes the Offline list).
function OfflinePicker.show(builder, on_download_done)
    local menu
    local function title()
        return T(_("Choose feeds (%1 selected)"), #OfflineStore.getSelection())
    end
    local function buildItems()
        local selection = OfflineStore.getSelection()
        local items = {
            {
                text = T(_("Download… (%1 feeds)"), #selection),
                keep_menu_open = true,
                callback = function()
                    OfflineDownload.showDialog(builder, on_download_done)
                end,
            },
            {
                text = T(_("Selected feeds (%1)"), #selection),
                callback = function()
                    OfflinePicker.showSelected(builder)
                end,
            },
            {
                text = _("Clear all"),
                keep_menu_open = true,
                callback = function()
                    if #OfflineStore.getSelection() == 0 then
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = _("Untick all selected feeds?"),
                        ok_text = _("Clear all"),
                        ok_callback = function()
                            OfflineStore.saveSelection({})
                            refreshMenu(menu, title(), buildItems)
                        end,
                    })
                end,
            },
        }
        local accounts = builder.accounts and builder.accounts:getAccounts() or {}
        for _i, account in ipairs(accounts) do
            local count = OfflineStore.countSelectedForAccount(selection, account.name)
            table.insert(items, {
                text = Commons.accountTitle(account) .. countSuffix(count),
                callback = function()
                    OfflinePicker.showAccount(builder, account)
                end,
            })
        end
        return items
    end

    menu = Menu:new{
        title = title(),
        item_table = buildItems(),
    }
    builder:showMenu(menu, function()
        OfflinePicker.show(builder, on_download_done)
    end)
end

return OfflinePicker
