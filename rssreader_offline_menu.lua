--[[
Offline Mode menus: the Offline root (actions + downloaded feeds) and a
feed's downloaded stories, opened straight from disk. Works with no network.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local OfflineStore = require("rssreader_offline_store")
local OfflineDownload = require("rssreader_offline_download")
local OfflinePicker = require("rssreader_offline_picker")
local OfflineSync = require("rssreader_offline_sync")
local utils = require("rssreader_menu_utils")

local OfflineMenu = {}

-- The account name the navigation state uses for an offline story list, so
-- coming back from an article reopens it (see RSSReader:restoreNavigationState).
OfflineMenu.ACCOUNT_NAME = "__offline__"

local function unreadSuffix(count)
    if count > 0 then
        return " (" .. tostring(count) .. ")"
    end
    return ""
end

local function feedLabel(manifest)
    return T("%1  —  %2", manifest.feed_title or manifest.feed_id or _("Feed"), tostring(manifest.account or ""))
end

-- Local feeds keep their own read state; reading a downloaded copy counts.
local function syncLocalReadState(builder, manifest, story_entry)
    if manifest.account_type ~= "local" or not story_entry.key or not builder.local_read_state then
        return
    end
    local feed_identifier = manifest.feed_id
    local map = builder.local_read_state.load(feed_identifier)
    if type(map) ~= "table" then
        map = {}
    end
    if story_entry.read then
        builder.local_read_state.markRead(feed_identifier, story_entry.key, map)
    else
        builder.local_read_state.markUnread(feed_identifier, story_entry.key, map)
    end
end

-- Marks stories read or unread in the manifest; for a remote account the
-- change also waits in the queue for the server (rssreader_offline_sync).
local function setRead(builder, manifest, story_entries, is_read)
    local queue = manifest.account_type ~= "local" and OfflineStore.loadPending() or nil
    for _i, story_entry in ipairs(story_entries) do
        story_entry.read = is_read and true or false
        if queue and story_entry.key then
            local story = story_entry.story or {}
            OfflineStore.queueReadState(queue, {
                account = manifest.account,
                -- A story of an aggregated view (All Unread) knows its own feed.
                feed_id = utils.resolveStoryFeedId(nil, story) or manifest.feed_id,
                key = story_entry.key,
                read = story_entry.read,
                story = story,
            })
        else
            syncLocalReadState(builder, manifest, story_entry)
        end
    end
    OfflineStore.saveManifest(manifest.dir, manifest)
    if queue then
        OfflineStore.savePending(queue)
    end
end

-- The list shows a story through the usual helpers, which expect the
-- backend's own story fields plus a read flag.
local function displayStory(story_entry)
    local story = {}
    for key, value in pairs(story_entry.story or {}) do
        story[key] = value
    end
    story.title = story.title or story.story_title or story_entry.title
    utils.setStoryReadState(story, story_entry.read)
    return story
end

-- ────────────────────────────────────────────────────────────
-- Root
-- ────────────────────────────────────────────────────────────

function OfflineMenu.rowLabel()
    local unread = OfflineStore.totalUnread()
    return _("Offline") .. unreadSuffix(unread)
end

function OfflineMenu.show(builder)
    local menu
    local function refresh()
        if menu and UIManager:isWidgetShown(menu) and menu.switchItemTable then
            menu:switchItemTable(nil, OfflineMenu.buildRootItems(builder, refresh), -1)
        end
    end
    menu = Menu:new{
        title = _("Offline"),
        item_table = OfflineMenu.buildRootItems(builder, refresh),
    }
    menu.onMenuHold = utils.triggerHoldCallback
    builder:showMenu(menu, function()
        OfflineMenu.show(builder)
    end)
end

function OfflineMenu.buildRootItems(builder, refresh)
    local selection_count = #OfflineStore.getSelection()
    local items = {
        {
            text = T(_("Download last selection (%1 feeds)"), selection_count),
            keep_menu_open = true,
            callback = function()
                OfflineDownload.showDialog(builder, refresh)
            end,
        },
        {
            text = _("Choose feeds…"),
            callback = function()
                OfflinePicker.show(builder, refresh)
            end,
        },
    }

    local pending = OfflineSync.pendingCount()
    if pending > 0 then
        table.insert(items, {
            text = T(_("Sync read states (%1 pending)"), pending),
            keep_menu_open = true,
            callback = function()
                OfflineSync.run(builder, { on_done = refresh })
            end,
        })
    end
    table.insert(items, {
        text = T(_("Read-state sync: %1"), OfflineSync.isAuto() and _("automatic") or _("manual")),
        keep_menu_open = true,
        callback = function()
            OfflineStore.setSyncMode(OfflineSync.isAuto() and OfflineStore.SYNC_MANUAL or OfflineStore.SYNC_AUTO)
            refresh()
        end,
    })

    local feeds = OfflineStore.listFeeds()
    for _i, manifest in ipairs(feeds) do
        local unread = OfflineStore.unreadCount(manifest)
        local dir = manifest.dir
        table.insert(items, {
            text = feedLabel(manifest) .. unreadSuffix(unread),
            bold = unread > 0,
            callback = function()
                OfflineMenu.showFeed(builder, dir)
            end,
            hold_callback = function()
                OfflineMenu.showFeedHoldDialog(builder, manifest, refresh)
            end,
            hold_keep_menu_open = true,
        })
    end
    if #feeds == 0 then
        table.insert(items, {
            text = _("Nothing downloaded yet."),
            keep_menu_open = true,
            callback = function() end,
        })
    end
    return items
end

function OfflineMenu.showFeedHoldDialog(builder, manifest, refresh)
    local dialog
    local function close()
        UIManager:close(dialog)
    end
    local selected = OfflineStore.isSelected(OfflineStore.getSelection(), manifest.account, manifest.feed_id)
    local buttons = {
        {{
            text = _("Mark all as read"),
            align = "left",
            callback = function()
                close()
                local unread = {}
                for _i, story_entry in ipairs(manifest.stories) do
                    if not story_entry.read then
                        table.insert(unread, story_entry)
                    end
                end
                setRead(builder, manifest, unread, true)
                refresh()
            end,
        }},
        {{
            text = _("Delete this feed's downloads"),
            align = "left",
            callback = function()
                close()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete all downloaded stories of\n%1?"), manifest.feed_title or manifest.feed_id),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        OfflineStore.deleteFeedDir(manifest.dir)
                        refresh()
                    end,
                })
            end,
        }},
    }
    if selected then
        table.insert(buttons, {{
            text = _("Remove from selection"),
            align = "left",
            callback = function()
                close()
                local selection = OfflineStore.getSelection()
                local index = OfflineStore.selectionIndex(selection, manifest.account, manifest.feed_id)
                if index then
                    table.remove(selection, index)
                    OfflineStore.saveSelection(selection)
                end
                refresh()
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = manifest.feed_title or manifest.feed_id,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ────────────────────────────────────────────────────────────
-- Story list
-- ────────────────────────────────────────────────────────────

function OfflineMenu.showFeed(builder, dir, opts)
    opts = opts or {}
    local manifest = OfflineStore.loadManifest(dir)
    if not manifest or #manifest.stories == 0 then
        UIManager:show(InfoMessage:new{ text = _("No downloaded stories in this feed."), timeout = 3 })
        return
    end

    local view_mode = "compact"
    if builder.reader and type(builder.reader.getListViewMode) == "function" then
        view_mode = builder.reader:getListViewMode()
    end

    local menu
    local function buildItems()
        local items = {}
        for _i, story_entry in ipairs(manifest.stories) do
            table.insert(items, {
                text = utils.buildStoryEntryText(displayStory(story_entry), true, view_mode),
                bold = not story_entry.read,
                callback = function()
                    OfflineMenu.openStory(builder, manifest, story_entry, menu)
                end,
                hold_callback = function()
                    OfflineMenu.showStoryHoldDialog(builder, manifest, story_entry, menu, buildItems)
                end,
                hold_keep_menu_open = true,
            })
        end
        return items
    end

    menu = Menu:new{
        title = manifest.feed_title or _("Feed"),
        item_table = buildItems(),
        multilines_forced = true,
        items_max_lines = view_mode == "magazine" and 5 or nil,
    }
    menu.onMenuHold = utils.triggerHoldCallback
    -- Lets the navigation state remember this list, so the way back from an
    -- article reopens it. Stories stay out of it: the manifest has them.
    menu._rss_feed_node = {
        kind = "offline",
        id = dir,
        title = manifest.feed_title,
        _account_name = OfflineMenu.ACCOUNT_NAME,
        _rss_stories = {},
        _rss_story_keys = {},
    }
    -- For RSSReader:openAdjacentArticle ("Next" at the end of an article):
    -- the stories in list order, found by their manifest key, opened from disk.
    local adjacent_stories = {}
    for index, story_entry in ipairs(manifest.stories) do
        local story = displayStory(story_entry)
        story._rss_offline_key = story_entry.key
        adjacent_stories[index] = story
    end
    menu._rss_story_context = {
        feed_node = { _rss_stories = adjacent_stories },
        open_story = function(index)
            local story_entry = manifest.stories[index]
            if story_entry then
                OfflineMenu.openStory(builder, manifest, story_entry, menu)
            end
        end,
    }
    menu._rss_builder = builder
    builder:showMenu(menu, function()
        OfflineMenu.showFeed(builder, dir)
    end)
    -- After showMenu, which gives the menu its reader to save pages into.
    utils.restoreMenuPage(menu, menu._rss_feed_node, opts.menu_page)
end

function OfflineMenu.openStory(builder, manifest, story_entry, menu)
    local path = story_entry.path
    if not path or lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{ text = _("The downloaded file is missing."), timeout = 3 })
        return
    end
    if not story_entry.read then
        setRead(builder, manifest, { story_entry }, true)
    end

    local reader = builder.reader
    if reader then
        -- Remember the list (and its page) before it closes, for the way back.
        if type(reader.saveNavigationState) == "function" then
            reader:saveNavigationState()
        end
        if reader.current_menu_info and reader.current_menu_info.menu == menu then
            UIManager:close(menu)
            reader.current_menu_info = nil
        end
    end
    if utils.ReaderReturn then
        pcall(utils.ReaderReturn.markArticle, path, story_entry.key)
    end
    require("apps/filemanager/filemanager"):openFile(path)
end

function OfflineMenu.showStoryHoldDialog(builder, manifest, story_entry, menu, build_items)
    local dialog
    local function redraw()
        if menu and menu.switchItemTable then
            menu:switchItemTable(nil, build_items(), -1)
        end
    end
    dialog = ButtonDialog:new{
        title = story_entry.title,
        title_align = "center",
        buttons = {
            {{
                text = story_entry.read and _("Mark as unread") or _("Mark as read"),
                align = "left",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    setRead(builder, manifest, { story_entry }, not story_entry.read)
                    redraw()
                end,
            }},
            {{
                text = _("Delete this story"),
                align = "left",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    local _story, index = OfflineStore.findStory(manifest, story_entry.key)
                    if index then
                        table.remove(manifest.stories, index)
                        OfflineStore.saveManifest(manifest.dir, manifest)
                    end
                    if story_entry.path then
                        os.remove(story_entry.path)
                    end
                    redraw()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Coming back from an article: the Offline root, then the story list on top,
-- so Back still climbs up through them.
function OfflineMenu.restore(builder, feed_state)
    local dir = feed_state and feed_state.feed_id
    if type(dir) ~= "string" or lfs.attributes(dir, "mode") ~= "directory" then
        return false
    end
    OfflineMenu.show(builder)
    OfflineMenu.showFeed(builder, dir, { menu_page = feed_state.menu_page })
    return true
end

return OfflineMenu
