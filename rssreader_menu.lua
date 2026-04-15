local util = require("util")
local Menu = require("ui/widget/menu")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ffiUtil = require("ffi/util")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")

local Screen = Device.screen

local Commons = require("rssreader_commons")
local LocalStore = require("rssreader_local_store")
local StoryViewer = require("rssreader_story_viewer")
local FeedFetcher = require("rssreader_feed_fetcher")
local HtmlResources = require("rssreader_html_resources")
local InputDialog = require("ui/widget/inputdialog")
local OPMLHandler = require("rssreader_opml")
local QRMessage = require("ui/widget/qrmessage")

local utils = require("rssreader_menu_utils")
local backends = require("rssreader_menu_backends")
local Pool = require("rssreader_pool")

local LocalReadState

local MenuBuilder = {}
MenuBuilder.__index = MenuBuilder

function MenuBuilder:createTapCallback(stories, index, context)
    local reader = self.reader
    local tap_action = "preview"
    if reader and type(reader.getTapAction) == "function" then
        tap_action = reader:getTapAction()
    end
    
    local story = stories[index]
    
    if tap_action == "open" then
        return function()
            utils.normalizeStoryReadState(story)
            if utils.isUnread(story) then
                self:handleStoryAction(stories, index, "mark_read", story, context)
            end
            self:handleStoryAction(stories, index, "go_to_link", { story = story }, context)
        end
    elseif tap_action == "save" then
        return function()
            utils.normalizeStoryReadState(story)
            if utils.isUnread(story) then
                self:handleStoryAction(stories, index, "mark_read", story, context)
            end
            self:handleStoryAction(stories, index, "save_story", { story = story }, context)
        end
    else
        return function()
            self:showStory(stories, index, function(action, payload)
                self:handleStoryAction(stories, index, action, payload, context)
            end, nil, nil, context)
        end
    end
end

function MenuBuilder:showStory(stories, index, on_action, on_close, options, context)
    self.story_viewer = self.story_viewer or StoryViewer:new()
    local reader = self.reader
    if reader and type(reader.requestFeedStatePreservation) == "function" then
        reader:requestFeedStatePreservation()
    end
    local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
    local current_info = self.reader and self.reader.current_menu_info
    local history_snapshot
    if self.reader and self.reader.history then
        history_snapshot = {}
        for i, entry in ipairs(self.reader.history) do
            history_snapshot[i] = entry
        end
    end
    local story = stories and stories[index]
    if story then
        utils.normalizeStoryReadState(story)
        if utils.isUnread(story) then
            self:handleStoryAction(stories, index, "mark_read", story, context)
        end
    end
    local is_api_context = false
    if context and (context.feed_type == "newsblur" or context.feed_type == "commafeed" or context.feed_type == "freshrss" or context.feed_type == "fever" or context.feed_type == "miniflux") then
        is_api_context = true
    end

    local disable_mutators = false
    if options and options.disable_story_mutators and not is_api_context then
        disable_mutators = true
    end
    local allow_mark_unread = true
    if context then
        if context.feed_type == "local" then
            allow_mark_unread = true
        else
            local client = context.client
            if client and type(client.markStoryAsUnread) == "function" then
                allow_mark_unread = true
            else
                allow_mark_unread = false
            end
        end
    end
    local show_images_in_preview = false
    if self.accounts and self.accounts.config then
        local flag = util.tableGetValue(self.accounts.config, "features", "show_images_in_preview")
        show_images_in_preview = flag == true
    end

    self.story_viewer:showStory(story, function(action, payload)
        self:handleStoryAction(stories, index, action, payload, context)
    end, function()
        if self.reader and current_menu then
            if current_info and self.reader.current_menu_info ~= current_info then
                self.reader.current_menu_info = current_info
            end
            if history_snapshot and #history_snapshot > 0 and (not self.reader.history or #self.reader.history == 0) and not current_menu._rss_is_root_menu then
                self.reader.history = history_snapshot
            end
            self.reader:updateBackButton(current_menu)
        else
        end
        if context and type(context.refresh) == "function" then
            local should_refresh = context._needs_refresh or context.force_refresh_on_close
            if should_refresh then
                context._needs_refresh = nil
                context.force_refresh_on_close = nil
                context.refresh()
            end
        end
        if on_close then
            on_close()
        end
    end, {
        disable_story_mutators = disable_mutators,
        is_api_version = is_api_context,
        allow_mark_unread = allow_mark_unread,
        show_images_in_preview = show_images_in_preview,
    })
end

function MenuBuilder:_updateStoryEntry(context, stories, index)
    if not context or not stories or not index then
        return
    end
    local menu_instance = context.menu_instance
    local story = stories[index]
    if not menu_instance or not story or type(menu_instance) ~= "table" then
        return
    end
    if type(menu_instance.item_table) ~= "table" then
        return
    end
    local entry = menu_instance.item_table[index]
    if not entry then
        return
    end
    local view_mode = "compact"
    if self.reader and type(self.reader.getListViewMode) == "function" then
        view_mode = self.reader:getListViewMode()
    end
    entry.text = utils.buildStoryEntryText(story, true, view_mode)
    entry.bold = utils.isUnread(story)
    if type(menu_instance.updateItems) == "function" then
        menu_instance:updateItems(nil, true)
    end
end

function MenuBuilder:_updateFeedCache(context)
    if not context then
        return
    end
    local feed_node = context.feed_node
    if not feed_node then
        return
    end
    if context.menu_instance then
        utils.persistFeedState(context.menu_instance, feed_node)
        return
    end
    local reader = feed_node._rss_reader or self.reader
    if not reader or type(reader.updateFeedState) ~= "function" then
        return
    end
    local account_name = feed_node._account_name
        or (context.account and context.account.name)
        or context.account_name
        or "unknown"
    local stories_copy = feed_node._rss_stories and util.tableDeepCopy(feed_node._rss_stories) or {}
    local story_keys_copy = {}
    for key, value in pairs(feed_node._rss_story_keys or {}) do
        if value then
            story_keys_copy[key] = true
        end
    end
    reader:updateFeedState(account_name, feed_node.id, {
        stories = stories_copy,
        story_keys = story_keys_copy,
        menu_page = context.menu_instance and context.menu_instance.page or feed_node._rss_menu_page,
        current_page = feed_node._rss_page,
        has_more = feed_node._rss_has_more,
    })
end

function MenuBuilder:handleStoryAction(stories, index, action, payload, context)
    local story = stories and stories[index]
    if action == "go_to_link" then
        local payload_table = type(payload) == "table" and payload or {}
        local target_story = payload_table.story or story
        utils.normalizeStoryLink(target_story)

        local function closeCurrentStory()
            if type(payload_table.close_story) == "function" then
                payload_table.close_story()
            end
        end

        local function closeActiveMenu()
            local reader = self.reader
            if reader and reader.current_menu_info and reader.current_menu_info.menu then
                UIManager:close(reader.current_menu_info.menu)
                reader.current_menu_info = nil
            end
        end

        closeCurrentStory()
        closeActiveMenu()

        utils.downloadStoryToCache(target_story, self, function(path, err)
            if err then
                local link = target_story and (target_story.permalink or target_story.href or target_story.link)
                if link then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Opening: %s"), link) })
                end
            end
        end)
        return
    end

    if action == "next_story" then
        local next_index = utils.findNextIndex(stories, index, function()
            return true
        end)
        if next_index then
            self:showStory(stories, next_index, function(next_action, next_payload)
                self:handleStoryAction(stories, next_index, next_action, next_payload, context)
            end, nil, nil, context)
        end
        return
    end

    if action == "next_unread" then
        local next_index = utils.findNextIndex(stories, index, function(story)
            return utils.isUnread(story)
        end)
        if next_index then
            self:showStory(stories, next_index, function(next_action, next_payload)
                self:handleStoryAction(stories, next_index, next_action, next_payload, context)
            end, nil, nil, context)
        else
            UIManager:show(InfoMessage:new{ text = _("No unread stories found.") })
        end
        return
    end

    if action == "open_link" then
        local link = payload
        if link and util.openFileWithCRE then
            util.openFileWithCRE(link)
        elseif link then
            UIManager:show(InfoMessage:new{ text = string.format(_("Opening: %s"), link) })
        end
        return
    end

    if action == "mark_read" then
        if story then
            utils.setStoryReadState(story, true)
            self:_updateStoryEntry(context, stories, index)
            self:_updateFeedCache(context)
            if context and context.feed_type == "local" then
                local feed_identifier = context.feed_identifier or (context.feed_node and (context.feed_node.url or context.feed_node.id))
                if feed_identifier then
                    local story_local_key = story._rss_local_key or utils.storyUniqueKey(story)
                    if story_local_key then
                        story._rss_local_key = story_local_key
                        context.local_read_map = context.local_read_map or {}
                        context.local_read_map = self.local_read_state.markRead(feed_identifier, story_local_key, context.local_read_map)
                        if context.feed_node then
                            context.feed_node._rss_local_read_map = context.local_read_map
                        end
                    end
                end
            end
            local remote_feed_id = utils.resolveStoryFeedId(context, story)
            if context and context.client and remote_feed_id and type(context.client.markStoryAsRead) == "function" then
                NetworkMgr:runWhenOnline(function()
                    local ok, err_or_data = context.client:markStoryAsRead(remote_feed_id, story)
                    if not ok then
                        utils.setStoryReadState(story, false)
                        self:_updateStoryEntry(context, stories, index)
                        self:_updateFeedCache(context)
                        UIManager:show(InfoMessage:new{ text = err_or_data or _("Failed to update story state."), timeout = 3 })
                    end
                end)
            end
        end
        return
    end

    if action == "mark_unread" then
        if story then
            local remote_feed_id = utils.resolveStoryFeedId(context, story)
            if context and context.feed_type ~= "local" and context.client and remote_feed_id and type(context.client.markStoryAsUnread) == "function" then
                NetworkMgr:runWhenOnline(function()
                    local ok, err_or_data = context.client:markStoryAsUnread(remote_feed_id, story)
                    if ok then
                        utils.setStoryReadState(story, false)
                        self:_updateStoryEntry(context, stories, index)
                        self:_updateFeedCache(context)
                    else
                        UIManager:show(InfoMessage:new{ text = err_or_data or _("Failed to update story state."), timeout = 3 })
                    end
                end)
                return
            end
            utils.setStoryReadState(story, false)
            if context and context.feed_type == "local" then
                local feed_identifier = context.feed_identifier or (context.feed_node and (context.feed_node.url or context.feed_node.id))
                if feed_identifier then
                    local story_local_key = story._rss_local_key or utils.storyUniqueKey(story)
                    if story_local_key then
                        story._rss_local_key = story_local_key
                        context.local_read_map = context.local_read_map or {}
                        context.local_read_map = self.local_read_state.markUnread(feed_identifier, story_local_key, context.local_read_map)
                        if context.feed_node then
                            context.feed_node._rss_local_read_map = context.local_read_map
                        end
                    end
                end
                self:_updateStoryEntry(context, stories, index)
                self:_updateFeedCache(context)
                return
            end
            self:_updateStoryEntry(context, stories, index)
            self:_updateFeedCache(context)
        end
        return
    end

    if action == "save_story" then
        local payload = type(payload) == "table" and payload or {}
        local target_story = payload.story or story
        if not target_story then
            UIManager:show(InfoMessage:new{ text = _("Could not save story."), timeout = 3 })
            return
        end

        utils.normalizeStoryLink(target_story)
        UIManager:show(InfoMessage:new{ text = _("Saving story..."), timeout = 1 })

        utils.fetchStoryContent(target_story, self, function(content, err, download_info)
            if not content then
                UIManager:show(InfoMessage:new{ text = _("Failed to download story."), timeout = 3 })
                return
            end

            local directory = utils.determineSaveDirectory(self)
            if not directory or directory == "" then
                UIManager:show(InfoMessage:new{ text = _("No target folder available."), timeout = 3 })
                return
            end
            util.makePath(directory)

            local filename = utils.safeFilenameFromStory(target_story)
            local metadata = type(download_info) == "table" and download_info or {}
            local include_images = metadata.images_requested and true or false
            local html_for_epub = metadata.html_for_epub
            local should_create_epub = include_images and type(html_for_epub) == "string" and html_for_epub ~= ""
            local assets_root = metadata.assets_root or (metadata.assets and metadata.assets.assets_root)
            local function cleanupAssets()
                if assets_root then
                    HtmlResources.cleanupAssets(assets_root)
                    assets_root = nil
                end
            end

            if should_create_epub and utils.EpubDownloadBackend then
                local base_name = filename:gsub("%.html$", "")
                local epub_path = utils.buildUniqueTargetPathWithExtension(directory, base_name, "epub")
                local story_url = metadata.original_url or target_story.permalink or target_story.href or target_story.link or ""
                local feed_title = target_story.feed_title or target_story.feedTitle
                local ok, result_or_err = pcall(function()
                    return utils.EpubDownloadBackend:createEpub(epub_path, html_for_epub, story_url, include_images, nil, nil, nil, feed_title)
                end)
                local success = ok and result_or_err ~= false
                if success then
                    cleanupAssets()
                    UIManager:show(InfoMessage:new{ text = string.format(_("Saved to: %s"), epub_path), timeout = 3 })
                    return
                else
                    logger.warn("RSSReader", "Failed to create EPUB", result_or_err)
                    cleanupAssets()
                    -- Fall back to HTML save below
                end
            end

            local target_path = utils.buildUniqueTargetPath(directory, filename)
            local story_url_for_html = metadata.original_url or target_story.permalink or target_story.href or target_story.link or ""
            if not utils.writeStoryHtmlFile(content, target_path, utils.resolveStoryDocumentTitle(target_story), story_url_for_html) then
                cleanupAssets()
                UIManager:show(InfoMessage:new{ text = _("Failed to save story."), timeout = 3 })
                return
            end

            cleanupAssets()
            UIManager:show(InfoMessage:new{ text = string.format(_("Saved to: %s"), target_path), timeout = 3 })
        end, { silent = true })
        return
    end

    if self.reader and type(self.reader.handleStoryAction) == "function" then
        self.reader:handleStoryAction(stories, index, action, payload, context)
    end
end

function MenuBuilder:collectFeedIdsForNode(node)
    local feed_ids = {}
    if not node then
        return feed_ids
    end

    local function collectFromNode(current_node)
        if current_node.kind == "feed" then
            -- Skip virtual feeds (CommaFeed, Fever, etc.)
            if current_node.id and not current_node._virtual and not current_node.is_virtual then
                table.insert(feed_ids, current_node.id)
            end
        elseif current_node.kind == "folder" or current_node.kind == "root" then
            if current_node.children then
                for _, child in ipairs(current_node.children) do
                    collectFromNode(child)
                end
            end
        end
    end

    collectFromNode(node)
    return feed_ids
end

function MenuBuilder:createLongPressMenuForNode(account, client, node, normal_callback)
    if not node or node.kind ~= "feed" then
        return
    end

    local account_type = account and account.type
    if account_type ~= "newsblur" and account_type ~= "commafeed" and account_type ~= "fever" and account_type ~= "freshrss" and account_type ~= "miniflux" then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = node.title or _("Feed"),
        buttons = {{
            {
                text = _("Open"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsRead(account, client, node)
                end,
            },
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:createLongPressMenuForFolder(account, client, node, normal_callback)
    if not node or node.kind ~= "folder" then
        return
    end

    local account_type = account and account.type
    if account_type ~= "newsblur" and account_type ~= "commafeed" and account_type ~= "fever" and account_type ~= "freshrss" and account_type ~= "miniflux" then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = node.title or _("Category"),
        buttons = {{
            {
                text = _("Open"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:showMarkAllAsReadDialog(account, client, node)
                end,
            },
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:createLongPressMenuForLocalGroup(group, account_name, normal_callback)
    if not group then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = group.title or _("Group"),
        buttons = {{
            {
                text = _("Open"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:showMarkAllAsReadDialogForLocalGroup(group, account_name)
                end,
            },
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:createStoryLongPressMenu(stories, index, context, open_callback)
    local story = stories and stories[index]
    if not story then
        return
    end

    utils.normalizeStoryReadState(story)
    local dialog
    local is_unread = utils.isUnread(story)

    local function closeDialog()
        if dialog then
            UIManager:close(dialog)
        end
    end

    local function markStoryReadIfNeeded()
        if is_unread then
            self:handleStoryAction(stories, index, "mark_read", story, context)
            is_unread = false
        end
    end

    local story_link = story.permalink or story.href or story.link

    local buttons = {{
        {
            text = _("Preview"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                markStoryReadIfNeeded()
                if type(open_callback) == "function" then
                    open_callback()
                end
            end,
        },
        {
            text = _("Open"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                markStoryReadIfNeeded()
                self:handleStoryAction(stories, index, "go_to_link", { story = story }, context)
            end,
        },
        {
            text = _("Save"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                markStoryReadIfNeeded()
                self:handleStoryAction(stories, index, "save_story", { story = story }, context)
            end,
        },
    }}

    table.insert(buttons, {
        {
            text = _("Add to List"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                local ok, err = Pool.addStory(story)
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Added to List."), timeout = 1 })
                    markStoryReadIfNeeded()
                    -- Refresh list after a short delay to avoid timing conflict
                    if context and type(context.refresh) == "function" then
                        UIManager:scheduleIn(0.1, function()
                            context.refresh()
                        end)
                    end
                elseif err == "duplicate" then
                    UIManager:show(InfoMessage:new{ text = _("Already in List."), timeout = 1 })
                elseif err == "pool_full" then
                    UIManager:show(InfoMessage:new{ text = _("List is full."), timeout = 1 })
                else
                    UIManager:show(InfoMessage:new{ text = _("Could not add to List."), timeout = 1 })
                end
            end,
        },
    })

    local mark_text
    local mark_action
    if is_unread then
        mark_text = _("Mark as read")
        mark_action = "mark_read"
    else
        mark_text = _("Mark as unread")
        mark_action = "mark_unread"
    end

    table.insert(buttons, {
        {
            text = mark_text,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                self:handleStoryAction(stories, index, mark_action, story, context)
            end,
        },
        {
            text = _("Show QR Code"),
            background = Blitbuffer.COLOR_WHITE,
            enabled = story_link ~= nil,
            callback = function()
                closeDialog()
                local qr_size = math.min(Screen:getWidth(), Screen:getHeight()) * 0.6
                UIManager:show(QRMessage:new{
                    text = story_link,
                    width = qr_size,
                    height = qr_size,
                })
            end,
        },
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
            end,
        },
    })

    local menu_title = story.story_title or story.title or _("Story")
    if (story._from_virtual_feed or story._is_from_virtual_feed) and story.feed_title and story.feed_title ~= "" then
        menu_title = string.format("%s\n[%s]", menu_title, story.feed_title)
    end
    
    local snippet = utils.storySnippet(story, 500)
    if snippet then
        menu_title = menu_title .. "\n" .. string.rep("─", 20) .. "\n" .. snippet
    end
    
    dialog = ButtonDialog:new{
        title = menu_title,
        buttons = buttons,
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:createLongPressMenuForLocalFeed(feed, account_name, normal_callback)
    if not feed then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = feed.title or feed.url or _("Feed"),
        buttons = {{
            {
                text = _("Open"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:performLocalMarkAllAsRead(feed, account_name)
                end,
            },
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:performLocalMarkAllAsRead(feed, account_name)
    if not feed or not feed.url then
        UIManager:show(InfoMessage:new{
            text = _("Feed URL is missing."),
            timeout = 3,
        })
        return
    end

    local title = feed.title or feed.url or _("Feed")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Marking feed '%s' as read..."), title),
        timeout = 1,
    })

    local feed_identifier = feed.url or feed.id or feed.title or "local_feed"
    account_name = account_name or feed._rss_account_name or "local"

    NetworkMgr:runWhenOnline(function()
        local ok, items_or_err = FeedFetcher.fetch(feed.url)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to load feed: %s"), items_or_err or _("unknown")),
                timeout = 3,
            })
            return
        end

        local items = items_or_err or {}
        if type(items) ~= "table" then
            items = {}
        end

        local read_map = self.local_read_state.load(feed_identifier)
        if type(read_map) ~= "table" then
            read_map = {}
        end

        local new_marks = 0
        for _, story in ipairs(items) do
            utils.normalizeStoryReadState(story)
            local key = utils.storyUniqueKey(story)
            if key then
                if not read_map[key] then
                    new_marks = new_marks + 1
                end
                read_map[key] = true
            end
        end

        self.local_read_state.save(feed_identifier, read_map)

        local feed_node = feed._rss_feed_node
        if feed_node then
            feed_node._rss_local_read_map = read_map
            for _, story in ipairs(feed_node._rss_stories or {}) do
                local key = story._rss_local_key or utils.storyUniqueKey(story)
                if key then
                    story._rss_local_key = key
                    utils.setStoryReadState(story, true)
                end
            end
            self:_updateFeedCache({ feed_node = feed_node })
        end

        UIManager:show(InfoMessage:new{
            text = string.format(_("Marked %d item(s) as read."), new_marks),
            timeout = 3,
        })
    end)
end

function MenuBuilder:performLocalGroupMarkAllAsRead(group, account_name)
    if not group or not group.feeds then
        UIManager:show(InfoMessage:new{
            text = _("Group has no feeds."),
            timeout = 3,
        })
        return
    end

    local title = group.title or _("Group")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Marking group '%s' as read..."), title),
        timeout = 1,
    })

    account_name = account_name or "local"
    local feeds = group.feeds or {}
    local total_new_marks = 0
    local feeds_processed = 0
    local total_feeds = #feeds

    local function processFeed(feed_index)
        if feed_index > total_feeds then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Marked %d item(s) in %d feed(s) as read."), total_new_marks, feeds_processed),
                timeout = 3,
            })
            return
        end

        local feed = feeds[feed_index]
        if not feed or not feed.url then
            processFeed(feed_index + 1)
            return
        end

        NetworkMgr:runWhenOnline(function()
            local ok, items_or_err = FeedFetcher.fetch(feed.url)
            if not ok then
                processFeed(feed_index + 1)
                return
            end

            local items = items_or_err or {}
            if type(items) ~= "table" then
                items = {}
            end

            local feed_identifier = feed.url or feed.id or feed.title or "local_feed"
            local read_map = self.local_read_state.load(feed_identifier)
            if type(read_map) ~= "table" then
                read_map = {}
            end

            local new_marks = 0
            for _, story in ipairs(items) do
                utils.normalizeStoryReadState(story)
                local key = utils.storyUniqueKey(story)
                if key then
                    if not read_map[key] then
                        new_marks = new_marks + 1
                    end
                    read_map[key] = true
                end
            end

            self.local_read_state.save(feed_identifier, read_map)
            
            local feed_node = feed._rss_feed_node
            if feed_node then
                feed_node._rss_local_read_map = read_map
                for _, story in ipairs(feed_node._rss_stories or {}) do
                    local key = story._rss_local_key or utils.storyUniqueKey(story)
                    if key then
                        story._rss_local_key = key
                        if read_map[key] then
                            utils.setStoryReadState(story, true)
                        end
                    end
                end
                self:_updateFeedCache({ feed_node = feed_node })
            end
            
            total_new_marks = total_new_marks + new_marks
            feeds_processed = feeds_processed + 1

            processFeed(feed_index + 1)
        end)
    end

    processFeed(1)
end

function MenuBuilder:showMarkAllAsReadDialogForLocalGroup(group, account_name)
    if not group or not group.feeds then
        UIManager:show(InfoMessage:new{
            text = _("Group has no feeds."),
            timeout = 3,
        })
        return
    end

    local title = group.title or _("Group")
    local title_text = string.format(_("Mark all stories in group '%s' as read?"), title)

    local dialog
    dialog = ButtonDialog:new{
        title = title_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:performLocalGroupMarkAllAsRead(group, account_name)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function MenuBuilder:showMarkAllAsReadDialogForAccount(account)
    local title_text = string.format(_("Mark all stories in account '%s' as read?"), account.name or _("Account"))

    local dialog
    dialog = ButtonDialog:new{
        title = title_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsReadForAccount(account)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function MenuBuilder:performMarkAllAsReadForAccount(account)
    local account_type = account and account.type
    if account_type ~= "newsblur" and account_type ~= "commafeed" then
        UIManager:show(InfoMessage:new{
            text = _("Account type not supported."),
            timeout = 3,
        })
        return
    end

    if not self.accounts or type(self.accounts.getNewsBlurClient) ~= "function" and type(self.accounts.getCommaFeedClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("Account integration is not available."),
            timeout = 3,
        })
        return
    end

    local client
    if account_type == "newsblur" then
        client = self.accounts:getNewsBlurClient(account)
    elseif account_type == "commafeed" then
        client = self.accounts:getCommaFeedClient(account)
    end

    if not client then
        UIManager:show(InfoMessage:new{
            text = _("Unable to access account."),
            timeout = 3,
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load account structure."),
                timeout = 3,
            })
            return
        end

        local feed_ids = self:collectFeedIdsForNode(tree_or_err)
        if #feed_ids == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No feeds found in account."),
                timeout = 3,
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking %d feed(s) as read..."), #feed_ids),
            timeout = 1,
        })

        local success_count = 0
        local error_messages = {}

        for _, feed_id in ipairs(feed_ids) do
            local mark_ok, err = client:markFeedAsRead(feed_id)
            if mark_ok then
                success_count = success_count + 1
            else
                table.insert(error_messages, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
            end
        end

        if success_count > 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Marked %d feed(s) as read."), success_count),
                timeout = 3,
            })
        end

        if #error_messages > 0 then
            local error_text = table.concat(error_messages, "\n")
            UIManager:show(InfoMessage:new{
                text = string.format(_("Errors occurred:\n%s"), error_text),
                timeout = 5,
            })
        end
    end)
end

function MenuBuilder:showMarkAllAsReadDialog(account, client, node)
    local node_type = node and node.kind or "root"
    local title_text
    if node_type == "feed" then
        title_text = string.format(_("Mark all stories in '%s' as read?"), node.title or _("Feed"))
    elseif node_type == "folder" then
        title_text = string.format(_("Mark all stories in '%s' and subfolders as read?"), node.title or _("Folder"))
    else
        title_text = string.format(_("Mark all stories in account '%s' as read?"), account.name or _("Account"))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = title_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsRead(account, client, node)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function MenuBuilder:performMarkAllAsRead(account, client, node)
    local node_type = node and node.kind
    local account_type = account and account.type

    if node_type == "feed" then
        if node._virtual or node.is_virtual then
            -- Handle virtual feeds for different account types
            if account_type == "commafeed" then
                backends.performMarkAllAsReadForCommaFeedVirtual(self, account, client, node)
                return
            elseif account_type == "fever" then
                backends.performMarkAllAsReadForFeverVirtual(self, account, client, node)
                return
            elseif account_type == "miniflux" then
                backends.performMarkAllAsReadForMinifluxVirtual(self, account, client, node)
                return
            end
            
            UIManager:show(InfoMessage:new{
                text = _("Mark all as read is not supported for virtual feeds. Please use individual feeds."),
                timeout = 3,
            })
            return
        end
        
        -- Mark single feed as read
        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking feed '%s' as read..."), node.title or _("Feed")),
            timeout = 1,
        })

        NetworkMgr:runWhenOnline(function()
            local ok, err = client:markFeedAsRead(node.id)
            if ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Marked feed '%s' as read."), node.title or _("Feed")),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Failed to mark feed as read: %s"), err or _("Unknown error")),
                    timeout = 3,
                })
            end
        end)
        return
    elseif node_type == "folder" then
        -- Mark folder as read - try specific API first, fallback to marking all feeds
        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking folder '%s' as read..."), node.title or _("Folder")),
            timeout = 1,
        })

        NetworkMgr:runWhenOnline(function()
            local success = false
            local error_msg = nil

            -- Try folder-specific API call first
            if account_type == "newsblur" and client.markFolderAsRead then
                success, error_msg = client:markFolderAsRead(node.title)
            elseif account_type == "commafeed" and node_type == "folder" then
                -- CommaFeed doesn't support category mark all as read, fall back to individual feeds
                success = false
            elseif account_type == "commafeed" and client.markCategoryAsRead then
                success, error_msg = client:markCategoryAsRead(node.id)
            elseif account_type == "miniflux" and client.markCategoryAsRead then
                success, error_msg = client:markCategoryAsRead(node.id)
            end

            -- If folder-specific API failed or not available, mark all feeds in folder
            if not success then
                local feed_ids = self:collectFeedIdsForNode(node)
                if #feed_ids == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No feeds found in folder."),
                        timeout = 3,
                    })
                    return
                end

                local success_count = 0
                local errors = {}

                for _, feed_id in ipairs(feed_ids) do
                    local ok, err = client:markFeedAsRead(feed_id)
                    if ok then
                        success_count = success_count + 1
                    else
                        table.insert(errors, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
                    end
                end

                if success_count > 0 then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Marked %d feed(s) in folder as read."), success_count),
                        timeout = 3,
                    })
                end

                if #errors > 0 then
                    local error_text = table.concat(errors, "\n")
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Errors occurred:\n%s"), error_text),
                        timeout = 5,
                    })
                end
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Marked folder '%s' as read."), node.title or _("Folder")),
                    timeout = 3,
                })
            end
        end)
        return
    end

    -- Fallback for account-level or unknown node types
    local feed_ids = self:collectFeedIdsForNode(node)
    if #feed_ids == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds found to mark as read."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Marking %d feed(s) as read..."), #feed_ids),
        timeout = 1,
    })

    NetworkMgr:runWhenOnline(function()
        local success_count = 0
        local error_messages = {}

        for _, feed_id in ipairs(feed_ids) do
            local ok, err = client:markFeedAsRead(feed_id)
            if ok then
                success_count = success_count + 1
            else
                table.insert(error_messages, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
            end
        end

        if success_count > 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Marked %d feed(s) as read."), success_count),
                timeout = 3,
            })
        end

        if #error_messages > 0 then
            local error_text = table.concat(error_messages, "\n")
            UIManager:show(InfoMessage:new{
                text = string.format(_("Errors occurred:\n%s"), error_text),
                timeout = 5,
            })
        end
    end)
end


function MenuBuilder:new(opts)
    local options = opts or {}
    local instance = setmetatable({}, MenuBuilder)
    instance.local_store = options.local_store or LocalStore:new()
    if not instance.local_read_state then
        LocalReadState = LocalReadState or require("rssreader_local_readstate")
    end
    instance.local_read_state = LocalReadState
    instance.accounts = options.accounts
    instance.reader = options.reader
    instance.story_viewer = options.story_viewer or StoryViewer:new()
    return instance
end

function MenuBuilder:calculateFolderUnreadCount(node)
    if not node or not node.children then
        return 0
    end
    local total = 0
    for _, child in ipairs(node.children) do
        if child.kind == "feed" and child.feed then
            total = total + ((child.feed.ps or 0) + (child.feed.nt or 0))
        elseif child.kind == "folder" then
            total = total + self:calculateFolderUnreadCount(child)
        end
    end
    return total
end

function MenuBuilder:showMenu(menu_instance, reopen_func, opts)
    if menu_instance and self.reader then
        menu_instance._rss_reader = self.reader
    end
    if self.reader and type(self.reader.showMenu) == "function" then
        self.reader:showMenu(menu_instance, reopen_func, opts)
    else
        UIManager:show(menu_instance)
    end
end

function MenuBuilder:showLocalFeed(feed, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    local account_name = opts.account_name or (feed and feed._rss_account_name) or "local"
    if feed then
        feed._rss_account_name = account_name
    end
    if not feed or not feed.url then
        UIManager:show(InfoMessage:new{
            text = _("Feed URL is missing."),
        })
        return
    end

    local feed_id = feed.id or feed.url or feed.title or tostring(feed)
    local feed_node = feed._rss_feed_node or {
        id = feed_id,
        title = feed.title,
        url = feed.url,
        _account_name = account_name,
        _rss_stories = {},
        _rss_story_keys = {},
        _rss_page = 1,
        _rss_has_more = false,
    }
    feed._rss_feed_node = feed_node
    feed_node.url = feed.url
    feed_node._rss_reader = self.reader
    feed_node._account_name = account_name

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account_name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local feed_identifier = feed_node.url or feed.url or feed_node.id or feed_node.title or "local_feed"
    local read_map = feed_node._rss_local_read_map
    if not read_map then
        local loaded_map = self.local_read_state.load(feed_identifier)
        if type(loaded_map) ~= "table" then
            read_map = {}
        else
            read_map = loaded_map
        end
        feed_node._rss_local_read_map = read_map
    end

    local function applyLocalReadState()
        local stories = feed_node._rss_stories or {}
        if type(read_map) ~= "table" then
            read_map = {}
        end
        local valid_keys = {}
        for _, story in ipairs(stories) do
            utils.normalizeStoryReadState(story)
            local key = utils.storyUniqueKey(story)
            if key then
                story._rss_local_key = key
                if read_map[key] then
                    utils.setStoryReadState(story, true)
                else
                    utils.setStoryReadState(story, false)
                end
                table.insert(valid_keys, key)
            else
                story._rss_local_key = nil
                utils.setStoryReadState(story, false)
            end
        end
        read_map = self.local_read_state.prune(feed_identifier, read_map, valid_keys)
        feed_node._rss_local_read_map = read_map
        self.local_read_state.save(feed_identifier, read_map)
    end

    local function finalizeMenu()
        local stories = feed_node._rss_stories or {}
        if #stories == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local context = {
            feed_type = "local",
            feed = feed,
            feed_node = feed_node,
            feed_identifier = feed_identifier,
            local_read_map = read_map,
            refresh = function()
                self:showLocalFeed(feed, {
                    account_name = account_name,
                    menu_page = feed_node._rss_menu_page,
                    reuse = true,
                })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        applyLocalReadState()
        for index, story in ipairs(stories) do
            utils.normalizeStoryReadState(story)
            utils.normalizeStoryLink(story)
            local entry_is_unread = utils.isUnread(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = entry_is_unread,
                callback = self:createTapCallback(stories, index, context),
                hold_callback = function()
                    self:createStoryLongPressMenu(stories, index, context, function()
                        self:showStory(stories, index, function(action, payload)
                            self:handleStoryAction(stories, index, action, payload, context)
                        end, nil, nil, context)
                    end)
                end,
                hold_keep_menu_open = true,
            })
        end

        local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
        local menu_instance
        if current_menu and current_menu._rss_feed_node == feed_node then
            menu_instance = current_menu
            if menu_instance.setTitle then
                menu_instance:setTitle(feed_node.title or _("Feed"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or _("Feed"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                self:showLocalFeed(feed, {
                    account_name = account_name,
                })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            utils.persistFeedState(menu_instance, feed_node)
        end

        utils.restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)

        UIManager:setDirty(nil, "full")
    end

    local has_cached_stories = feed_node._rss_stories and #feed_node._rss_stories > 0

    if reuse_cached_stories and has_cached_stories then
        finalizeMenu()
        if not opts.force_refresh then
            return
        end
    end

    NetworkMgr:runWhenOnline(function()
        local ok, items_or_err = FeedFetcher.fetch(feed.url)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to load feed: %s"), items_or_err or _("unknown")),
            })
            if self.reader and type(self.reader.goBack) == "function" then
                self.reader:goBack()
            end
            return
        end

        local items = items_or_err or {}
        if type(items) ~= "table" then
            items = {}
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local previous_menu_page = feed_node._rss_menu_page
        feed_node._rss_stories = {}
        feed_node._rss_story_keys = {}
        feed_node._rss_page = 1
        feed_node._rss_has_more = false
        for _, story in ipairs(items) do
            utils.appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
        end
        feed_node._rss_menu_page = previous_menu_page
        feed_node.title = feed.title or _("Feed")

        applyLocalReadState()
        finalizeMenu()
    end)
end

function MenuBuilder:buildAccountEntries(accounts, open_callback)
    local entries = {}
    for index, account in ipairs(accounts or {}) do
        local title = Commons.accountTitle(account)
        local holds_items = {}
        
        -- Add account info for all accounts
        table.insert(holds_items, {
            text = _("Account info"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = string.format("%s\n(%s)", title, account.type or "unknown"),
                })
            end,
        })
        
        -- Add Open option for local accounts
        if account.type == "local" then
            table.insert(holds_items, {
                text = _("Open"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    if open_callback then
                        open_callback(account)
                    end
                end,
            })
        end
        
        -- Add Mark all as read for API accounts
        if account.type == "newsblur" or account.type == "commafeed" or account.type == "freshrss" or account.type == "miniflux" then
            table.insert(holds_items, {
                text = _("Mark all as read"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    self:showMarkAllAsReadDialogForAccount(account)
                end,
            })
        elseif account.type == "local" then
            -- Keep the existing delete feed placeholder for local accounts
            table.insert(holds_items, {
                text = _("Delete feed (future feature)"),
                background = Blitbuffer.COLOR_WHITE,
                keep_menu_open = true,
                callback = function()
                    -- TODO: Implement feed deletion for local accounts
                    UIManager:show(InfoMessage:new{
                        text = _("Feed deletion not yet implemented for local accounts."),
                        timeout = 3,
                    })
                end,
            })
        end
        
        table.insert(entries, {
            text = title,
            callback = function()
                if open_callback then
                    open_callback(account)
                end
            end,
            holds = holds_items,
        })
    end
    local pool_count = Pool.count()
    local pool_label = pool_count > 0
        and string.format(_("List (%d)"), pool_count)
        or _("List")
    table.insert(entries, {
        text = pool_label,
        keep_menu_open = true,
        callback = function()
            self:showPoolPopup()
        end,
    })
    table.insert(entries, {
        text = _("Settings"),
        keep_menu_open = true,
        callback = function()
            self:showSettingsPopup()
        end,
    })
    return entries
end

function MenuBuilder:showSettingsPopup()
    local show_newsblur_all = G_reader_settings:nilOrTrue("rssreader_newsblur_show_all_feeds")
    
    local dialog
    dialog = ButtonDialog:new{
        title = _("Settings"),
        buttons = {
            {{
                text = _("Tap action on feed items"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showTapActionPopup()
                end,
            }},
            {{
                text = _("List view mode"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showListViewPopup()
                end,
            }},
            {{
                text = show_newsblur_all and "✓ " .. _("Show NewsBlur 'All Feeds'") or _("Show NewsBlur 'All Feeds'"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local new_value = not show_newsblur_all
                    G_reader_settings:saveSetting("rssreader_newsblur_show_all_feeds", new_value)
                    
                    if self.accounts and type(self.accounts.getAccounts) == "function" then
                        local all_accounts = self.accounts:getAccounts()
                        for _, account in ipairs(all_accounts or {}) do
                            if account.type == "newsblur" then
                                local client = self.accounts:getNewsBlurClient(account)
                                if client and client.buildTree then
                                    client.tree_cache = nil
                                    client.subscriptions_cache = nil
                                end
                            end
                        end
                    end
                    
                    UIManager:show(InfoMessage:new{
                        text = new_value and _("NewsBlur 'All Feeds' enabled. Please reopen NewsBlur accounts.") or _("NewsBlur 'All Feeds' disabled. Please reopen NewsBlur accounts."),
                    })
                end,
            }},
            {{
                text = _("Clear cache"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:clearCacheDirectory()
                end,
            }},
            {{
                text = _("Import from OPML"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showOPMLImport()
                end,
            }},
            {{
                text = _("Export to OPML"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:performOPMLExport()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function MenuBuilder:showTapActionPopup()
    local reader = self.reader
    local current_action = "preview"
    if reader and type(reader.getTapAction) == "function" then
        current_action = reader:getTapAction()
    end
    
    local dialog
    dialog = ButtonDialog:new{
        title = _("Tap action on feed items"),
        buttons = {
            {{
                text = current_action == "preview" and "✓ " .. _("Show preview") or _("Show preview"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    if reader and type(reader.setTapAction) == "function" then
                        reader:setTapAction("preview")
                    end
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = current_action == "open" and "✓ " .. _("Open directly") or _("Open directly"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    if reader and type(reader.setTapAction) == "function" then
                        reader:setTapAction("open")
                    end
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = current_action == "save" and "✓ " .. _("Save only") or _("Save only"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    if reader and type(reader.setTapAction) == "function" then
                        reader:setTapAction("save")
                    end
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function MenuBuilder:showListViewPopup()
    local reader = self.reader
    local current_mode = "compact"
    if reader and type(reader.getListViewMode) == "function" then
        current_mode = reader:getListViewMode()
    end

    local function label(mode_key, display)
        if current_mode == mode_key then
            return "✓ " .. display
        end
        return display
    end

    local dialog
    dialog = ButtonDialog:new{
        title = _("List view mode"),
        buttons = {
            {{
                text = label("compact", _("Title only")),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    if reader and type(reader.setListViewMode) == "function" then
                        reader:setListViewMode("compact")
                    end
                    UIManager:close(dialog)
                end,
            }},
            {{
                text = label("magazine", _("Title and snippet")),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    if reader and type(reader.setListViewMode) == "function" then
                        reader:setListViewMode("magazine")
                    end
                    UIManager:close(dialog)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function MenuBuilder:showOPMLImport()
    local files = OPMLHandler.findOPMLFiles()
    if #files == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No OPML/XML files found in plugin directory.\n\nPlace an .opml or .xml file in:\n") .. OPMLHandler.getPluginDir(),
        })
        return
    end

    if #files == 1 then
        self:showOPMLImportNameDialog(files[1].path, files[1].name)
    else
        local entries = {}
        for _, file in ipairs(files) do
            table.insert(entries, {
                text = file.name,
                callback = function()
                    UIManager:close(self._opml_file_menu)
                    self._opml_file_menu = nil
                    self:showOPMLImportNameDialog(file.path, file.name)
                end,
            })
        end
        self._opml_file_menu = Menu:new{
            title = _("Select OPML file to import"),
            item_table = entries,
        }
        self:showMenu(self._opml_file_menu)
    end
end

function MenuBuilder:showOPMLImportNameDialog(opml_path, filename)
    -- Suggest account name from filename (strip extension)
    local suggested = filename:gsub("%.opml$", ""):gsub("%.xml$", "")
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Account name for imported feeds"),
        input = suggested,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(input_dialog)
                end,
            },
            {
                text = _("Import"),
                is_enter_default = true,
                callback = function()
                    local name = input_dialog:getInputText()
                    UIManager:close(input_dialog)
                    if not name or name == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("Account name cannot be empty."),
                        })
                        return
                    end
                    self:executeOPMLImport(opml_path, name)
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function MenuBuilder:executeOPMLImport(opml_path, account_name)
    local ok, result = OPMLHandler.performImport(opml_path, account_name)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Import failed: ") .. tostring(result),
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = string.format(
            _("Successfully imported %d feeds into account '%s'.\n\nPlease restart KOReader for changes to take effect."),
            result, account_name
        ),
    })
end

function MenuBuilder:performOPMLExport()
    local export_path = OPMLHandler.getDefaultExportPath()
    local ok, result = OPMLHandler.performExport(export_path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Export failed: ") .. tostring(result),
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = string.format(
            _("Successfully exported %d feeds to:\n%s"),
            result, export_path
        ),
    })
end

function MenuBuilder:clearCacheDirectory()
    local cache_dir = utils.buildCacheDirectory()
    local active_dir = utils.pickActiveDirectory(cache_dir)
    if active_dir then
        utils.ensureActiveDirectory(active_dir)
    end
    local ok, err = ffiUtil.purgeDir(cache_dir)
    if not ok then
        logger.warn("RSSReader", "Failed to clear cache directory", err)
        UIManager:show(InfoMessage:new{
            text = _("Failed to clear cache."),
        })
        return
    end

    util.makePath(cache_dir)
    UIManager:show(InfoMessage:new{
        text = _("Cache cleared."),
    })
end

function MenuBuilder:openAccount(reader, account)
    local account_type = account and account.type
    if account_type == "local" then
        self:showLocalAccount(account)
        return
    elseif account_type == "newsblur" then
        backends.showNewsBlurAccount(self, account, { force_refresh = true })
        return
    elseif account_type == "commafeed" then
        backends.showCommaFeedAccount(self, account, { force_refresh = true })
        return
    elseif account_type == "freshrss" then
        backends.showFreshRSSAccount(self, account, { force_refresh = true })
        return
    elseif account_type == "fever" then
        backends.showFeverAccount(self, account, { force_refresh = true })
        return
    elseif account_type == "miniflux" then
        backends.showMinifluxAccount(self, account, { force_refresh = true })
        return
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Account '%s' is not implemented yet."), Commons.accountTitle(account)),
    })
end

function MenuBuilder:showLocalAccount(account)
    local groups = {}
    local feeds = {}
    local account_name = (account and account.name) or "local"
    if account and account.name then
        groups = self.local_store:listGroups(account_name)
        feeds = self.local_store:listFeeds(account_name)
    else
        logger.warn("RSSReader", "Account or account.name is nil")
    end
    local entries = {}
    for feed_index, feed in ipairs(feeds) do
        local feed_title = feed.title or (feed.url or _("Unnamed feed"))
        local function openFeed()
            self:showLocalFeed(feed, {
                account_name = account_name,
            })
        end
        table.insert(entries, {
            text = feed_title,
            callback = openFeed,
            hold_callback = function()
                self:createLongPressMenuForLocalFeed(feed, account_name, openFeed)
            end,
            hold_keep_menu_open = true,
        })
    end
    for group_index, group in ipairs(groups) do
        local title = group.title or string.format(_("Local Group %d"), group_index)
        local normal_callback = function()
            self:showLocalGroup(group, account and account.name)
        end
        table.insert(entries, {
            text = string.format(_("%s (group)"), title),
            callback = normal_callback,
            hold_callback = function()
                self:createLongPressMenuForLocalGroup(group, account_name, normal_callback)
            end,
            hold_keep_menu_open = true,
        })
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No local feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = Commons.accountTitle(account),
        item_table = entries,
    }
    menu_instance.onMenuHold = utils.triggerHoldCallback
    self:showMenu(menu_instance, function()
        self:showLocalAccount(account)
    end)
end

function MenuBuilder:showLocalGroup(group, account_name)
    local feeds = (group and group.feeds) or {}
    local entries = {}
    for feed_index, feed in ipairs(feeds) do
        local function openFeed()
            self:showLocalFeed(feed, {
                account_name = account_name,
            })
        end
        table.insert(entries, {
            text = feed.title or (feed.url or _("Unnamed feed")),
            callback = openFeed,
            hold_callback = function()
                self:createLongPressMenuForLocalFeed(feed, account_name, openFeed)
            end,
            hold_keep_menu_open = true,
        })
    end

    if #entries == 0 then
        entries = {
            {
                text = _("No feeds in this group."),
                keep_menu_open = true,
                callback = function()
                    if self.reader and type(self.reader.goBack) == "function" then
                        self.reader:goBack()
                    end
                end,
            },
        }
    end

    local menu_instance = Menu:new{
        title = group and (group.title or _("Local Group")) or _("Local Group"),
        item_table = entries,
    }
    menu_instance.onMenuHold = utils.triggerHoldCallback
    self:showMenu(menu_instance, function()
        self:showLocalGroup(group, account_name)
    end)
end

-- ────────────────────────────────────────────────────────────
-- Reading List (Pool)
-- ────────────────────────────────────────────────────────────

function MenuBuilder:showPoolPopup()
    local pool_count = Pool.count()
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(_("List (%d)"), pool_count),
        buttons = {
            {{
                text = _("Story List"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showPoolStoryList()
                end,
            }},
            {{
                text = _("Clear List"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:showPoolClearConfirm()
                end,
            }},
            {{
                text = _("Save All"),
                background = Blitbuffer.COLOR_WHITE,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:poolSaveAll()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function MenuBuilder:showPoolStoryList()
    local stories = Pool.getStories()
    if #stories == 0 then
        UIManager:show(InfoMessage:new{
            text = _("List is empty."),
            timeout = 3,
        })
        return
    end

    local view_mode = "compact"
    if self.reader and type(self.reader.getListViewMode) == "function" then
        view_mode = self.reader:getListViewMode()
    end

    local tap_action = "preview"
    if self.reader and type(self.reader.getTapAction) == "function" then
        tap_action = self.reader:getTapAction()
    end

    local entries = {}
    for index, story in ipairs(stories) do
        utils.normalizeStoryReadState(story)
        utils.normalizeStoryLink(story)
        local is_unread = not (story._pool_read == true)
        if is_unread then
            story._rss_is_read = false
        end
        
        local tap_callback
        if tap_action == "save" then
            tap_callback = function()
                self:poolSaveSingleStory(story, index)
            end
        elseif tap_action == "open" then
            tap_callback = function()
                if not story._pool_read then
                    Pool.markRead(index)
                    story._pool_read = true
                    story._rss_is_read = true
                end
                self:handlePoolStoryAction(stories, index, "go_to_link", { story = story })
            end
        else
            tap_callback = function()
                self:poolShowStoryPreview(stories, index)
            end
        end
        
        table.insert(entries, {
            text = utils.buildStoryEntryText(story, true, view_mode),
            bold = is_unread,
            callback = tap_callback,
            hold_callback = function()
                self:poolStoryLongPress(stories, index)
            end,
            hold_keep_menu_open = true,
        })
    end

    local menu_instance
    menu_instance = Menu:new{
        title = string.format(_("List (%d)"), #stories),
        item_table = entries,
        multilines_forced = true,
        items_max_lines = view_mode == "magazine" and 5 or nil,
    }
    menu_instance.onMenuHold = utils.triggerHoldCallback
    
    -- Mark this as a pool menu for state restoration
    menu_instance._rss_feed_node = {
        kind = "pool",
        id = "pool",
        title = string.format(_("List (%d)"), #stories),
        _account_name = "pool",
        _rss_stories = stories,
        _rss_story_keys = {},
        _rss_page = 1,
        _rss_has_more = false,
    }
    
    self:showMenu(menu_instance, function()
        self:showPoolStoryList()
    end)
end

function MenuBuilder:poolShowStoryPreview(stories, index)
    local story = stories and stories[index]
    if not story then
        return
    end

    -- Mark as read in pool
    if not story._pool_read then
        Pool.markRead(index)
        story._pool_read = true
        story._rss_is_read = true
    end

    self.story_viewer = self.story_viewer or StoryViewer:new()

    local show_images_in_preview = false
    if self.accounts and self.accounts.config then
        local flag = util.tableGetValue(self.accounts.config, "features", "show_images_in_preview")
        show_images_in_preview = flag == true
    end

    self.story_viewer:showStory(story, function(action, payload)
        self:handlePoolStoryAction(stories, index, action, payload)
    end, function()
        -- Refresh list on close
        if self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu then
            self.reader:updateBackButton(self.reader.current_menu_info.menu)
        end
        self:refreshPoolMenu()
    end, {
        include_save = true,
        disable_story_mutators = false,
        is_api_version = false,
        allow_mark_unread = true,
        show_images_in_preview = show_images_in_preview,
        is_pool = true,
        pool_index = index,
    })
end

function MenuBuilder:handlePoolStoryAction(stories, index, action, payload)
    local story = stories and stories[index]
    if not story then
        return
    end

    if action == "go_to_link" then
        local payload_table = type(payload) == "table" and payload or {}
        local target_story = payload_table.story or story
        utils.normalizeStoryLink(target_story)

        local function closeCurrentStory()
            if type(payload_table.close_story) == "function" then
                payload_table.close_story()
            end
        end

        local function closeActiveMenu()
            local reader = self.reader
            if reader and reader.current_menu_info and reader.current_menu_info.menu then
                UIManager:close(reader.current_menu_info.menu)
                reader.current_menu_info = nil
            end
        end

        -- Mark as read in pool
        if not story._pool_read then
            Pool.markRead(index)
            story._pool_read = true
            story._rss_is_read = true
        end

        closeCurrentStory()
        closeActiveMenu()

        utils.downloadStoryToCache(target_story, self, function(path, err)
            if err then
                local link = target_story and (target_story.permalink or target_story.href or target_story.link)
                if link then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Opening: %s"), link) })
                end
            end
        end)
        return
    end

    if action == "save_story" then
        local payload_table = type(payload) == "table" and payload or {}
        local target_story = payload_table.story or story
        self:poolSaveSingleStory(target_story, index)
        return
    end

    if action == "mark_read" then
        if story then
            Pool.markRead(index)
            story._pool_read = true
            story._rss_is_read = true
            utils.setStoryReadState(story, true)
        end
        return
    end

    if action == "mark_unread" then
        if story then
            Pool.markUnread(index)
            story._pool_read = false
            story._rss_is_read = false
            utils.setStoryReadState(story, false)
        end
        return
    end

    if action == "next_story" then
        local next_index = index + 1
        if next_index <= #stories then
            self:poolShowStoryPreview(stories, next_index)
        else
            UIManager:show(InfoMessage:new{ text = _("No more stories."), timeout = 2 })
        end
        return
    end

    if action == "next_unread" then
        for i = index + 1, #stories do
            if not stories[i]._pool_read then
                self:poolShowStoryPreview(stories, i)
                return
            end
        end
        UIManager:show(InfoMessage:new{ text = _("No unread stories found."), timeout = 2 })
        return
    end
end

function MenuBuilder:poolStoryLongPress(stories, index)
    local story = stories and stories[index]
    if not story then
        return
    end

    utils.normalizeStoryReadState(story)
    local dialog
    local is_read = story._pool_read == true
    local story_link = story.permalink or story.href or story.link

    local function closeDialog()
        if dialog then
            UIManager:close(dialog)
        end
    end

    local buttons = {{
        {
            text = _("Preview"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                self:poolShowStoryPreview(stories, index)
            end,
        },
        {
            text = _("Open"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                if not story._pool_read then
                    Pool.markRead(index)
                    story._pool_read = true
                    story._rss_is_read = true
                end
                self:handlePoolStoryAction(stories, index, "go_to_link", { story = story })
            end,
        },
        {
            text = _("Save"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                self:poolSaveSingleStory(story, index)
            end,
        },
    }}

    local mark_text = is_read and _("Mark as unread") or _("Mark as read")
    table.insert(buttons, {
        {
            text = mark_text,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                if is_read then
                    Pool.markUnread(index)
                    story._pool_read = false
                    story._rss_is_read = false
                else
                    Pool.markRead(index)
                    story._pool_read = true
                    story._rss_is_read = true
                end
                self:refreshPoolMenu()
            end,
        },
        {
            text = _("Remove from list"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
                Pool.removeStory(index)
                UIManager:show(InfoMessage:new{ text = _("Removed from List."), timeout = 2 })
                self:refreshPoolMenu()
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Show QR Code"),
            background = Blitbuffer.COLOR_WHITE,
            enabled = story_link ~= nil,
            callback = function()
                closeDialog()
                local qr_size = math.min(Screen:getWidth(), Screen:getHeight()) * 0.6
                UIManager:show(QRMessage:new{
                    text = story_link,
                    width = qr_size,
                    height = qr_size,
                })
            end,
        },
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                closeDialog()
            end,
        },
    })

    local menu_title = story.story_title or story.title or _("Story")
    local snippet = utils.storySnippet(story, 500)
    if snippet then
        menu_title = menu_title .. "\n" .. string.rep("─", 20) .. "\n" .. snippet
    end

    dialog = ButtonDialog:new{
        title = menu_title,
        buttons = buttons,
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:refreshPoolMenu()
    local stories = Pool.getStories()
    if self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu then
        local menu = self.reader.current_menu_info.menu
        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local tap_action = "preview"
        if self.reader and type(self.reader.getTapAction) == "function" then
            tap_action = self.reader:getTapAction()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryReadState(story)
            utils.normalizeStoryLink(story)
            local is_unread = not (story._pool_read == true)
            if is_unread then
                story._rss_is_read = false
            end
            
            local tap_callback
            if tap_action == "save" then
                tap_callback = function()
                    self:poolSaveSingleStory(story, index)
                end
            elseif tap_action == "open" then
                tap_callback = function()
                    if not story._pool_read then
                        Pool.markRead(index)
                        story._pool_read = true
                        story._rss_is_read = true
                    end
                    self:handlePoolStoryAction(stories, index, "go_to_link", { story = story })
                end
            else
                tap_callback = function()
                    self:poolShowStoryPreview(stories, index)
                end
            end
            
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = is_unread,
                callback = tap_callback,
                hold_callback = function()
                    self:poolStoryLongPress(stories, index)
                end,
                hold_keep_menu_open = true,
            })
        end

        if menu.switchItemTable then
            menu:switchItemTable(
                string.format(_("List (%d)"), #stories),
                entries
            )
        end
    end
end

function MenuBuilder:poolSaveSingleStory(story, pool_index)
    if not story then
        UIManager:show(InfoMessage:new{ text = _("Could not save story."), timeout = 3 })
        return
    end

    utils.normalizeStoryLink(story)
    UIManager:show(InfoMessage:new{ text = _("Saving story..."), timeout = 1 })

    utils.fetchStoryContent(story, self, function(content, err, download_info)
        if not content then
            UIManager:show(InfoMessage:new{ text = _("Failed to download story."), timeout = 3 })
            return
        end

        local directory = utils.determineSaveDirectory(self)
        if not directory or directory == "" then
            UIManager:show(InfoMessage:new{ text = _("No target folder available."), timeout = 3 })
            return
        end
        util.makePath(directory)

        local filename = utils.safeFilenameFromStory(story)
        local metadata = type(download_info) == "table" and download_info or {}
        local include_images = metadata.images_requested and true or false
        local html_for_epub = metadata.html_for_epub
        local should_create_epub = include_images and type(html_for_epub) == "string" and html_for_epub ~= ""
        local assets_root = metadata.assets_root or (metadata.assets and metadata.assets.assets_root)
        local function cleanupAssets()
            if assets_root then
                HtmlResources.cleanupAssets(assets_root)
                assets_root = nil
            end
        end

        if should_create_epub and utils.EpubDownloadBackend then
            local base_name = filename:gsub("%.html$", "")
            local epub_path = utils.buildUniqueTargetPathWithExtension(directory, base_name, "epub")
            local story_url = metadata.original_url or story.permalink or story.href or story.link or ""
            local feed_title = story.feed_title or story.feedTitle
            local ok, result_or_err = pcall(function()
                return utils.EpubDownloadBackend:createEpub(epub_path, html_for_epub, story_url, include_images, nil, nil, nil, feed_title)
            end)
            local success = ok and result_or_err ~= false
            if success then
                cleanupAssets()
                -- Remove from pool after save
                if pool_index then
                    Pool.removeStory(pool_index)
                    self:refreshPoolMenu()
                end
                UIManager:show(InfoMessage:new{ text = string.format(_("Saved to: %s"), epub_path), timeout = 3 })
                return
            else
                logger.warn("RSSReader Pool", "Failed to create EPUB", result_or_err)
                cleanupAssets()
            end
        end

        local target_path = utils.buildUniqueTargetPath(directory, filename)
        local story_url_for_html = metadata.original_url or story.permalink or story.href or story.link or ""
        if not utils.writeStoryHtmlFile(content, target_path, utils.resolveStoryDocumentTitle(story), story_url_for_html) then
            cleanupAssets()
            UIManager:show(InfoMessage:new{ text = _("Failed to save story."), timeout = 3 })
            return
        end

        cleanupAssets()
        -- Remove from pool after save
        if pool_index then
            Pool.removeStory(pool_index)
            self:refreshPoolMenu()
        end
        UIManager:show(InfoMessage:new{ text = string.format(_("Saved to: %s"), target_path), timeout = 3 })
    end, { silent = true })
end

function MenuBuilder:showPoolClearConfirm()
    local pool_count = Pool.count()
    if pool_count == 0 then
        UIManager:show(InfoMessage:new{ text = _("List is already empty."), timeout = 3 })
        return
    end

    local confirm_dialog
    confirm_dialog = ButtonDialog:new{
        title = string.format(_("Clear all %d items from the List?"), pool_count),
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(confirm_dialog)
                end,
            },
            {
                text = _("Clear All"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(confirm_dialog)
                    Pool.clear()
                    UIManager:show(InfoMessage:new{ text = _("List cleared."), timeout = 2 })
                    
                    -- Close pool story list if open, return to main menu
                    if self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu then
                        local menu = self.reader.current_menu_info.menu
                        if menu._rss_feed_node and menu._rss_feed_node.kind == "pool" then
                            UIManager:close(menu)
                            self.reader.current_menu_info = nil
                        end
                    end
                end,
            },
        }},
    }
    UIManager:show(confirm_dialog)
end

function MenuBuilder:poolSaveAll()
    local stories = Pool.getStories()
    if #stories == 0 then
        UIManager:show(InfoMessage:new{ text = _("List is empty."), timeout = 3 })
        return
    end

    local total = #stories
    local current = 0
    local cancelled = false
    local progress_widget

    local function showProgress(idx, title)
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
        local text = string.format(_("Saving %d of %d...\n%s\n\nTap outside to cancel."), idx, total, title or "")
        progress_widget = InfoMessage:new{
            text = text,
            timeout = nil,
        }
        progress_widget.dismiss_callback = function()
            if not cancelled then
                cancelled = true
            end
        end
        UIManager:show(progress_widget)
        UIManager:forceRePaint()
    end

    local function closeProgress()
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
    end

    local function saveNext()
        if cancelled then
            closeProgress()
            UIManager:show(InfoMessage:new{
                text = string.format(_("Cancelled. Saved %d of %d stories."), current, total),
                timeout = 3,
            })
            self:refreshPoolMenu()
            return
        end

        -- Re-read pool because indices shift after removal
        local remaining = Pool.getStories()
        if #remaining == 0 then
            closeProgress()
            UIManager:show(InfoMessage:new{
                text = string.format(_("All %d stories saved successfully."), current),
                timeout = 3,
            })
            if self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu then
                UIManager:close(self.reader.current_menu_info.menu)
                self.reader.current_menu_info = nil
            end
            if self.reader and type(self.reader.openAccountList) == "function" then
                self.reader:openAccountList()
            end
            return
        end

        current = current + 1
        local story = remaining[1]
        local title = story.story_title or story.title or _("Untitled")
        showProgress(current, title)

        utils.normalizeStoryLink(story)
        utils.fetchStoryContent(story, self, function(content, err, download_info)
            if cancelled then
                closeProgress()
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Cancelled. Saved %d of %d stories."), current - 1, total),
                    timeout = 3,
                })
                self:refreshPoolMenu()
                return
            end

            if not content then
                logger.warn("RSSReader Pool", "Failed to fetch content for", title)
                -- Skip this story, move to next without removing
                Pool.removeStory(1)
                UIManager:scheduleIn(0.1, saveNext)
                return
            end

            local directory = utils.determineSaveDirectory(self)
            if not directory or directory == "" then
                closeProgress()
                UIManager:show(InfoMessage:new{ text = _("No target folder available."), timeout = 3 })
                return
            end
            util.makePath(directory)

            local filename = utils.safeFilenameFromStory(story)
            local metadata = type(download_info) == "table" and download_info or {}
            local include_images = metadata.images_requested and true or false
            local html_for_epub = metadata.html_for_epub
            local should_create_epub = include_images and type(html_for_epub) == "string" and html_for_epub ~= ""
            local assets_root = metadata.assets_root or (metadata.assets and metadata.assets.assets_root)
            local function cleanupAssets()
                if assets_root then
                    HtmlResources.cleanupAssets(assets_root)
                    assets_root = nil
                end
            end

            local saved = false
            if should_create_epub and utils.EpubDownloadBackend then
                local base_name = filename:gsub("%.html$", "")
                local epub_path = utils.buildUniqueTargetPathWithExtension(directory, base_name, "epub")
                local story_url = metadata.original_url or story.permalink or story.href or story.link or ""
                local feed_title = story.feed_title or story.feedTitle
                local ok, result_or_err = pcall(function()
                    return utils.EpubDownloadBackend:createEpub(epub_path, html_for_epub, story_url, include_images, nil, nil, nil, feed_title)
                end)
                saved = ok and result_or_err ~= false
                if not saved then
                    logger.warn("RSSReader Pool", "EPUB creation failed", result_or_err)
                end
            end

            if not saved then
                local target_path = utils.buildUniqueTargetPath(directory, filename)
                local story_url_for_html = metadata.original_url or story.permalink or story.href or story.link or ""
                saved = utils.writeStoryHtmlFile(content, target_path, utils.resolveStoryDocumentTitle(story), story_url_for_html)
            end

            cleanupAssets()

            if saved then
                Pool.removeStory(1)
            end

            UIManager:scheduleIn(0.1, saveNext)
        end, { silent = true })
    end

    saveNext()
end

return MenuBuilder