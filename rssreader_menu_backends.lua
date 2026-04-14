local util = require("util")
local Menu = require("ui/widget/menu")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")

local Screen = Device.screen

local utils = require("rssreader_menu_utils")

local backends = {}

function backends.collectFeedsForCommaFeedVirtual(self, client, virtual_node)
    local feed_ids = {}
    if not virtual_node or not virtual_node._virtual then
        return feed_ids
    end

    local ok, tree = client:buildTree()
    if not ok or not tree then
        return feed_ids
    end

    local category_id = virtual_node._category_id
    
    local function collectFromNode(node)
        if node.kind == "feed" and not node._virtual and node.id then
            table.insert(feed_ids, node.id)
        elseif (node.kind == "folder" or node.kind == "root") and node.children then
            for _, child in ipairs(node.children) do
                collectFromNode(child)
            end
        end
    end
    
    if not category_id then
        -- Account-level virtual feed: collect all feeds recursively from entire tree
        collectFromNode(tree)
    else
        -- Category-level virtual feed: find the category and collect all feeds recursively
        local function findCategoryById(node, target_id)
            if node.kind == "folder" and tostring(node.id) == tostring(target_id) then
                return node
            end
            if node.children then
                for _, child in ipairs(node.children) do
                    local found = findCategoryById(child, target_id)
                    if found then
                        return found
                    end
                end
            end
            return nil
        end
        
        local category_node = findCategoryById(tree, category_id)
        if category_node then
            collectFromNode(category_node)
        end
    end
    
    return feed_ids
end

function backends.collectFeedsForFeverVirtual(self, client, virtual_node)
    local feed_ids = {}
    if not virtual_node or not virtual_node.is_virtual then
        return feed_ids
    end

    local ok, tree = client:buildTree()
    if not ok or not tree then
        return feed_ids
    end

    local function collectAllFeeds(node)
        if node.kind == "feed" and not node.is_virtual and node.id then
            table.insert(feed_ids, node.id)
        elseif node.kind == "folder" or node.kind == "root" then
            if node.children then
                for _, child in ipairs(node.children) do
                    collectAllFeeds(child)
                end
            end
        end
    end

    collectAllFeeds(tree)
    return feed_ids
end

function backends.collectFeedsForMinifluxVirtual(self, client, virtual_node)
    local feed_ids = {}
    if not virtual_node or not virtual_node._virtual then
        return feed_ids
    end

    local ok, tree = client:buildTree()
    if not ok or not tree then
        return feed_ids
    end

    local category_id = virtual_node._category_id
    
    local function collectFromNode(node)
        if node.kind == "feed" and not node._virtual and node.id then
            table.insert(feed_ids, node.id)
        elseif (node.kind == "folder" or node.kind == "root") and node.children then
            for _, child in ipairs(node.children) do
                collectFromNode(child)
            end
        end
    end
    
    if not category_id then
        collectFromNode(tree)
    else
        local function findCategoryById(node, target_id)
            if node.kind == "folder" and tostring(node.id) == tostring(target_id) then
                return node
            end
            if node.children then
                for _, child in ipairs(node.children) do
                    local found = findCategoryById(child, target_id)
                    if found then
                        return found
                    end
                end
            end
            return nil
        end
        
        local category_node = findCategoryById(tree, category_id)
        if category_node then
            collectFromNode(category_node)
        end
    end
    
    return feed_ids
end

function backends.performMarkAllAsReadForCommaFeedVirtual(self, account, client, virtual_node)
    local feed_ids = backends.collectFeedsForCommaFeedVirtual(self, client, virtual_node)
    
    if #feed_ids == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds found to mark as read."),
            timeout = 3,
        })
        return
    end
    
    local confirmation_text = string.format(
        _("All feeds will be marked as read one by one. This may take some time. Do you want to proceed?\n\nTotal feeds: %d"),
        #feed_ids
    )
    
    local dialog
    dialog = ButtonDialog:new{
        title = confirmation_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("OK"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    
                    NetworkMgr:runWhenOnline(function()
                        local success_count = 0
                        local error_messages = {}
                        
                        for index, feed_id in ipairs(feed_ids) do
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Marking feed %d/%d as read..."), index, #feed_ids),
                                timeout = 1,
                            })
                            
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
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function backends.performMarkAllAsReadForFeverVirtual(self, account, client, virtual_node)
    local feed_ids = backends.collectFeedsForFeverVirtual(self, client, virtual_node)
    
    if #feed_ids == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds found to mark as read."),
            timeout = 3,
        })
        return
    end
    
    local confirmation_text = string.format(
        _("All feeds will be marked as read one by one. This may take some time. Do you want to proceed?\n\nTotal feeds: %d"),
        #feed_ids
    )
    
    local dialog
    dialog = ButtonDialog:new{
        title = confirmation_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("OK"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    
                    NetworkMgr:runWhenOnline(function()
                        local success_count = 0
                        local error_messages = {}
                        
                        for index, feed_id in ipairs(feed_ids) do
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Marking feed %d/%d as read..."), index, #feed_ids),
                                timeout = 1,
                            })
                            
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
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function backends.performMarkAllAsReadForMinifluxVirtual(self, account, client, virtual_node)
    local feed_ids = backends.collectFeedsForMinifluxVirtual(self, client, virtual_node)
    
    if #feed_ids == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds found to mark as read."),
            timeout = 3,
        })
        return
    end
    
    local confirmation_text = string.format(
        _("All feeds will be marked as read one by one. This may take some time. Do you want to proceed?\n\nTotal feeds: %d"),
        #feed_ids
    )
    
    local dialog
    dialog = ButtonDialog:new{
        title = confirmation_text,
        buttons = {{
            {
                text = _("Cancel"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("OK"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                    
                    NetworkMgr:runWhenOnline(function()
                        local success_count = 0
                        local error_messages = {}
                        
                        for index, feed_id in ipairs(feed_ids) do
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Marking feed %d/%d as read..."), index, #feed_ids),
                                timeout = 1,
                            })
                            
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
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function backends.showNewsBlurAccount(self, account, opts)
    opts = opts or {}
    if not self.accounts or type(self.accounts.getNewsBlurClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("NewsBlur integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getNewsBlurClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open NewsBlur account."),
        })
        return
    end

    if not opts.force_refresh and client.tree_cache then
        backends.showNewsBlurNode(self, account, client, client.tree_cache)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load NewsBlur subscriptions."),
            })
            return
        end

        backends.showNewsBlurNode(self, account, client, tree_or_err)
    end)
end

function backends.showNewsBlurNode(self, account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local unread_count = self:calculateFolderUnreadCount(child)
            local display_title = child.title or _("Untitled folder")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            local normal_callback = function()
                backends.showNewsBlurNode(self, account, client, child)
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForFolder(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        elseif child.kind == "feed" then
            local unread_count = 0
            if child.feed then
                unread_count = (child.feed.ps or 0) + (child.feed.nt or 0)
            end
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            local normal_callback = function()
                backends.showNewsBlurFeed(self, account, client, child)
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("NewsBlur"),
        item_table = entries,
        onMenuHold = utils.triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        backends.showNewsBlurNode(self, account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = utils.triggerHoldCallback
    end
end

function backends.showNewsBlurFeed(self, account, client, feed_node, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
            end
            if type(stored_state.current_page) == "number" then
                feed_node._rss_page = stored_state.current_page
            end
            feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page = opts.page
    local has_cached_stories = feed_node._rss_stories and #feed_node._rss_stories > 0
    if not fetch_page and (not reuse_cached_stories or not has_cached_stories) then
        fetch_page = 1
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
            feed_type = "newsblur",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                backends.showNewsBlurFeed(self, account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryReadState(story)
            utils.normalizeStoryLink(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = utils.isUnread(story),
                callback = self:createTapCallback(stories, index, context),
                hold_callback = function()
                    self:createStoryLongPressMenu(stories, index, context, function()
                        self:showStory(stories, index, function(action, payload)
                            self:handleStoryAction(stories, index, action, payload, context)
                        end, nil, { disable_story_mutators = true }, context)
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
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("NewsBlur"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("NewsBlur"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                backends.showNewsBlurFeed(self, account, client, feed_node, { reuse = true })
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

        if menu_instance and menu_instance.page_info then
            local next_page = (feed_node._rss_page or 1) + 1
            local existing_button_index
            for idx = #menu_instance.page_info, 1, -1 do
                local widget = menu_instance.page_info[idx]
                if widget and widget._rss_is_more_button then
                    existing_button_index = idx
                    break
                end
            end
            if existing_button_index then
                table.remove(menu_instance.page_info, existing_button_index)
                table.remove(menu_instance.page_info, existing_button_index - 1)
            end
            if feed_node._rss_has_more then
                local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
                local load_more_button = Button:new{
                    text = _("More"),
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = 0,
                    show_parent = menu_instance.show_parent or menu_instance,
                    callback = function()
                        backends.showNewsBlurFeed(self, account, client, feed_node, { page = next_page })
                    end,
                }
                load_more_button._rss_is_more_button = true
                table.insert(menu_instance.page_info, spacer)
                table.insert(menu_instance.page_info, load_more_button)
            end
            if menu_instance.page_info.resetLayout then
                menu_instance.page_info:resetLayout()
            end
        end

        utils.restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)

        UIManager:setDirty(nil, "full")
    end

    if fetch_page then
        NetworkMgr:runWhenOnline(function()
            local ok, data_or_err = client:fetchStories(feed_node.id, { page = fetch_page })
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = data_or_err or _("Failed to load stories."),
                })
                return
            end
            local batch = (data_or_err and data_or_err.stories) or {}
            if fetch_page == 1 then
                feed_node._rss_stories = {}
                feed_node._rss_story_keys = {}
            end
            if #batch == 0 then
                if fetch_page == 1 and #feed_node._rss_stories == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No stories available."),
                    })
                    feed_node._rss_has_more = false
                    return
                end
                feed_node._rss_has_more = false
                if fetch_page > 1 then
                    UIManager:show(InfoMessage:new{
                        text = _("No more stories available."),
                    })
                end
            else
                feed_node._rss_page = fetch_page
                for _, story in ipairs(batch) do
                    utils.appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
                end
                local more = false
                if data_or_err and data_or_err.more_stories ~= nil then
                    more = data_or_err.more_stories and true or false
                else
                    more = #batch > 0
                end
                feed_node._rss_has_more = more
            end
            finalizeMenu()
        end)
        return
    end

    finalizeMenu()
end

function backends.showCommaFeedAccount(self, account, opts)
    opts = opts or {}
    if not self.accounts or type(self.accounts.getCommaFeedClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("CommaFeed integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getCommaFeedClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open CommaFeed account."),
        })
        return
    end

    if not opts.force_refresh and client.tree_cache then
        backends.showCommaFeedNode(self, account, client, client.tree_cache)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load CommaFeed subscriptions."),
            })
            return
        end

        backends.showCommaFeedNode(self, account, client, tree_or_err)
    end)
end

function backends.showCommaFeedNode(self, account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local normal_callback = function()
                backends.showCommaFeedNode(self, account, client, child)
            end
            table.insert(entries, {
                text = child.title or _("Untitled folder"),
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForFolder(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        elseif child.kind == "feed" then
            local normal_callback = function()
                backends.showCommaFeedFeed(self, account, client, child)
            end
            local unread_count = 0
            if child.feed then
                unread_count = child.feed.unreadCount or 0
            end
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("CommaFeed"),
        item_table = entries,
        onMenuHold = utils.triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        backends.showCommaFeedNode(self, account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = utils.triggerHoldCallback
    end
end

function backends.showCommaFeedFeed(self, account, client, feed_node, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name
    feed_node._rss_reader = self.reader

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
                feed_node._rss_page = stored_state.current_page or feed_node._rss_page
                feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = feed_node._rss_menu_page or stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page
    if opts.page then
        fetch_page = opts.page
    elseif not reuse_cached_stories then
        fetch_page = 1
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
            feed_type = "commafeed",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                backends.showCommaFeedFeed(self, account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryLink(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = utils.isUnread(story),
                callback = self:createTapCallback(stories, index, context),
                hold_callback = function()
                    self:createStoryLongPressMenu(stories, index, context, function()
                        self:showStory(stories, index, function(action, payload)
                            self:handleStoryAction(stories, index, action, payload, context)
                        end, nil, { disable_story_mutators = true }, context)
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
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("CommaFeed"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("CommaFeed"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                backends.showCommaFeedFeed(self, account, client, feed_node, { reuse = true })
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

        if menu_instance and menu_instance.page_info then
            local next_page = (feed_node._rss_page or 1) + 1
            local existing_button_index
            for idx = #menu_instance.page_info, 1, -1 do
                local widget = menu_instance.page_info[idx]
                if widget and widget._rss_is_more_button then
                    existing_button_index = idx
                    break
                end
            end
            if existing_button_index then
                table.remove(menu_instance.page_info, existing_button_index)
                table.remove(menu_instance.page_info, existing_button_index - 1)
            end
            if feed_node._rss_has_more then
                local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
                local load_more_button = Button:new{
                    text = _("More"),
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = 0,
                    show_parent = menu_instance.show_parent or menu_instance,
                    callback = function()
                        backends.showCommaFeedFeed(self, account, client, feed_node, { page = next_page })
                    end,
                }
                load_more_button._rss_is_more_button = true
                table.insert(menu_instance.page_info, spacer)
                table.insert(menu_instance.page_info, load_more_button)
            end
            if menu_instance.page_info.resetLayout then
                menu_instance.page_info:resetLayout()
            end
        end

        utils.restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)

        UIManager:setDirty(nil, "full")
    end

    if fetch_page then
        NetworkMgr:runWhenOnline(function()
            local ok, data_or_err = client:fetchStories(feed_node.id, { page = fetch_page })
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = data_or_err or _("Failed to load stories."),
                })
                return
            end
            local batch = (data_or_err and data_or_err.stories) or {}
            if fetch_page == 1 then
                feed_node._rss_stories = {}
                feed_node._rss_story_keys = {}
            end
            if #batch == 0 then
                if fetch_page == 1 and #feed_node._rss_stories == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No stories available."),
                    })
                    feed_node._rss_has_more = false
                    return
                end
                feed_node._rss_has_more = false
                if fetch_page > 1 then
                    UIManager:show(InfoMessage:new{
                        text = _("No more stories available."),
                    })
                end
            else
                feed_node._rss_page = fetch_page
                for _, story in ipairs(batch) do
                    utils.appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
                end
                local more = false
                if data_or_err and data_or_err.more_stories ~= nil then
                    more = data_or_err.more_stories and true or false
                else
                    more = #batch > 0
                end
                feed_node._rss_has_more = more
            end
            finalizeMenu()
        end)
        return
    end

    finalizeMenu()
end

function backends.showFreshRSSAccount(self, account, opts)
    opts = opts or {}
    if not self.accounts or type(self.accounts.getFreshRSSClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("FreshRSS integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getFreshRSSClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open FreshRSS account."),
        })
        return
    end

    local function buildSpecialChildren()
        local children = {}

        table.insert(children, {
            kind = "feed",
            id = "freshrss_today_unread",
            title = _("Today (Unread)"),
            api_feed_id = "user/-/state/com.google/reading-list",
            is_special_feed = true,
            feed = { unreadCount = 0 },
        })

        table.insert(children, {
            kind = "feed",
            id = "freshrss_all",
            title = _("All Unread"),
            api_feed_id = "user/-/state/com.google/reading-list",
            is_special_feed = true,
            feed = { unreadCount = 0 },
        })

        if account.special_feeds and type(account.special_feeds) == "table" then
            for _, special_feed in ipairs(account.special_feeds) do
                if special_feed.id then
                    local internal_id = "freshrss_" .. special_feed.id:gsub("/", "_") .. "_unread"

                    table.insert(children, {
                        kind = "feed",
                        id = internal_id,
                        title = special_feed.title or special_feed.id,
                        api_feed_id = special_feed.id,
                        is_special_feed = true,
                        feed = { unreadCount = 0 },
                    })
                end
            end
        end

        return children
    end

    local function showWithTree(tree)
        local base_children = (tree and tree.children) or {}
        local merged_children = {}

        local special_children = buildSpecialChildren()
        for _, node in ipairs(special_children) do
            table.insert(merged_children, node)
        end

        for _, node in ipairs(base_children) do
            table.insert(merged_children, node)
        end

        local decorated_tree = {
            kind = "root",
            title = (tree and tree.title) or account.name or "FreshRSS",
            children = merged_children,
            feeds = tree and tree.feeds or nil,
        }

        backends.showFreshRSSNode(self, account, client, decorated_tree)
    end

    if not opts.force_refresh and client.tree_cache then
        showWithTree(client.tree_cache)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load FreshRSS subscriptions."),
            })
            return
        end

        showWithTree(tree_or_err)
    end)
end

function backends.showFreshRSSNode(self, account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local normal_callback = function()
                backends.showFreshRSSNode(self, account, client, child)
            end
            table.insert(entries, {
                text = child.title or _("Untitled folder"),
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForFolder(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        elseif child.kind == "feed" then
            local normal_callback = function()
                backends.showFreshRSSFeed(self, account, client, child)
            end
            local unread_count = child.feed.unreadCount or 0
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("FreshRSS"),
        item_table = entries,
        onMenuHold = utils.triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        backends.showFreshRSSNode(self, account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = utils.triggerHoldCallback
    end
end

function backends.showFreshRSSFeed(self, account, client, feed_node, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name
    feed_node._rss_reader = self.reader

    -- Check if this is our special "Today" feed
    local is_special_feed = feed_node.is_special_feed and true or false
    -- Use the real API feed ID if provided, otherwise default to the node's ID
    local api_fetch_id = feed_node.api_feed_id or feed_node.id
    local fetch_options = {}
 
    if is_special_feed then  
        -- Apply unread filter for all special feeds  
        fetch_options.read_filter = "unread_only"  
        fetch_options.n = 15
        
        -- Only apply time filter for the "Today" feed  
        if feed_node.id == "freshrss_today_unread" then  
            fetch_options.published_since = utils.getStartOfTodayTimestamp() * 1000000  
        end  
        
        if not opts.page then  
            opts.page = 1  
        end  
    end

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
                feed_node._rss_page = stored_state.current_page or feed_node._rss_page
                feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = feed_node._rss_menu_page or stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page
    if opts.page then
        fetch_page = opts.page
        -- Make sure our options table includes the page
        fetch_options.page = opts.page 
    elseif not reuse_cached_stories then
        fetch_page = 1
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
            feed_type = "freshrss",
            account = account,
            client = client,
            feed_node = feed_node,
            -- Use the API feed ID for context actions like "mark as read"
            feed_id = api_fetch_id, 
            refresh = function()
                backends.showFreshRSSFeed(self, account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryLink(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = utils.isUnread(story),
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
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("FreshRSS"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("FreshRSS"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                backends.showFreshRSSFeed(self, account, client, feed_node, { reuse = true })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
        end

        if menu_instance and menu_instance.page_info then
            local next_page = (feed_node._rss_page or 1) + 1
            local existing_button_index
            for idx = #menu_instance.page_info, 1, -1 do
                local widget = menu_instance.page_info[idx]
                if widget and widget._rss_is_more_button then
                    existing_button_index = idx
                    break
                end
            end
            if existing_button_index then
                table.remove(menu_instance.page_info, existing_button_index)
                table.remove(menu_instance.page_info, existing_button_index - 1)
            end
            if feed_node._rss_has_more then
                local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
                local load_more_button = Button:new{
                    text = _("More"),
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = 0,
                    show_parent = menu_instance.show_parent or menu_instance,
                    callback = function()
                        backends.showFreshRSSFeed(self, account, client, feed_node, { page = next_page })
                    end,
                }
                load_more_button._rss_is_more_button = true
                table.insert(menu_instance.page_info, spacer)
                table.insert(menu_instance.page_info, load_more_button)
            end
            if menu_instance.page_info.resetLayout then
                menu_instance.page_info:resetLayout()
            end
        end

        utils.restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)

        UIManager:setDirty(nil, "full")
    end

    if fetch_page then
        NetworkMgr:runWhenOnline(function()
            -- Pass the full fetch_options table
            if not fetch_options.page then
                fetch_options.page = fetch_page
            end
            -- Make sure to use api_fetch_id and pass fetch_options
            local ok, data_or_err = client:fetchStories(api_fetch_id, fetch_options)
            
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = data_or_err or _("Failed to load stories."),
                })
                return
            end
            local batch = (data_or_err and data_or_err.stories) or {}
            if fetch_page == 1 then
                feed_node._rss_stories = {}
                feed_node._rss_story_keys = {}
            end
            if #batch == 0 then
                if fetch_page == 1 and #feed_node._rss_stories == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No stories available."),
                    })
                    feed_node._rss_has_more = false
                    return
                end
                feed_node._rss_has_more = false
                if fetch_page > 1 then
                    UIManager:show(InfoMessage:new{
                        text = _("No more stories available."),
                    })
                end
            else
                feed_node._rss_page = fetch_page
                for _, story in ipairs(batch) do
                    utils.appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
                end
                local more = false
                if data_or_err and data_or_err.more_stories ~= nil then
                    more = data_or_err.more_stories and true or false
                else
                    more = #batch > 0
                end
                feed_node._rss_has_more = more
            end
            finalizeMenu()
        end)
        return
    end

    finalizeMenu()
end

function backends.showFeverAccount(self, account, opts)
    opts = opts or {}
    if not self.accounts or type(self.accounts.getFeverClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("Fever API integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getFeverClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open Fever API account."),
        })
        return
    end

    if not opts.force_refresh and client.tree_cache then
        backends.showFeverNode(self, account, client, client.tree_cache)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load Fever API subscriptions."),
            })
            return
        end

        backends.showFeverNode(self, account, client, tree_or_err)
    end)
end

function backends.showFeverNode(self, account, client, node)
    local children = node and node.children or {}
    local entries = {}
    
    for _, child in ipairs(children) do
        if child.kind == "feed" and child.is_virtual then
            local normal_callback = function()
                backends.showFeverFeed(self, account, client, child)
            end
            table.insert(entries, {
                text = child.title or _("Virtual feed"),
                callback = normal_callback,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("Fever API"),
        item_table = entries,
        onMenuHold = utils.triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        backends.showFeverNode(self, account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = utils.triggerHoldCallback
    end
end

function backends.showFeverFeed(self, account, client, feed_node, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name
    feed_node._rss_reader = self.reader

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
                feed_node._rss_page = stored_state.current_page or feed_node._rss_page
                feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = feed_node._rss_menu_page or stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
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
            feed_type = "fever",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                backends.showFeverFeed(self, account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryLink(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = utils.isUnread(story),
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
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("Fever API"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("Fever API"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                backends.showFeverFeed(self, account, client, feed_node, { reuse = true })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
        end
    end

    if reuse_cached_stories and #feed_node._rss_stories > 0 then
        finalizeMenu()
        return
    end

    NetworkMgr:runWhenOnline(function()
        local fetch_options = {}
        
        if feed_node.is_virtual and feed_node.virtual_type == "unread" then
            fetch_options.read_filter = "unread_only"
        end
        
        local ok, data = client:fetchStories(feed_node.id, fetch_options)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = data or _("Failed to fetch stories."),
            })
            return
        end

        local stories = data.stories or {}
        feed_node._rss_stories = stories
        feed_node._rss_story_keys = {}
        for _, story in ipairs(stories) do
            local key = story.story_hash or story.hash or story.guid or story.story_id or story.id
            if key then
                feed_node._rss_story_keys[key] = true
            end
        end
        feed_node._rss_page = 1
        feed_node._rss_has_more = data.more_stories or false

        finalizeMenu()
    end)
end

function backends.showMinifluxAccount(self, account, opts)
    opts = opts or {}
    if not self.accounts or type(self.accounts.getMinifluxClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("Miniflux integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getMinifluxClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open Miniflux account."),
        })
        return
    end

    if not opts.force_refresh and client.tree_cache then
        backends.showMinifluxNode(self, account, client, client.tree_cache)
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load Miniflux subscriptions."),
            })
            return
        end

        backends.showMinifluxNode(self, account, client, tree_or_err)
    end)
end

function backends.showMinifluxNode(self, account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local normal_callback = function()
                backends.showMinifluxNode(self, account, client, child)
            end
            table.insert(entries, {
                text = child.title or _("Untitled folder"),
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForFolder(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        elseif child.kind == "feed" then
            local normal_callback = function()
                backends.showMinifluxFeed(self, account, client, child)
            end
            local unread_count = 0
            if child.feed then
                unread_count = child.feed.unreadCount or 0
            end
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("Miniflux"),
        item_table = entries,
        onMenuHold = utils.triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        backends.showMinifluxNode(self, account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = utils.triggerHoldCallback
    end
end

function backends.showMinifluxFeed(self, account, client, feed_node, opts)
    opts = opts or {}
    local reuse_cached_stories = opts.reuse and true or false
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name
    feed_node._rss_reader = self.reader

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
                feed_node._rss_page = stored_state.current_page or feed_node._rss_page
                feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = feed_node._rss_menu_page or stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page
    if opts.page then
        fetch_page = opts.page
    elseif not reuse_cached_stories then
        fetch_page = 1
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
            feed_type = "miniflux",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                backends.showMinifluxFeed(self, account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local view_mode = "compact"
        if self.reader and type(self.reader.getListViewMode) == "function" then
            view_mode = self.reader:getListViewMode()
        end

        local entries = {}
        for index, story in ipairs(stories) do
            utils.normalizeStoryLink(story)
            table.insert(entries, {
                text = utils.buildStoryEntryText(story, true, view_mode),
                bold = utils.isUnread(story),
                callback = self:createTapCallback(stories, index, context),
                hold_callback = function()
                    self:createStoryLongPressMenu(stories, index, context, function()
                        self:showStory(stories, index, function(action, payload)
                            self:handleStoryAction(stories, index, action, payload, context)
                        end, nil, { disable_story_mutators = true }, context)
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
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("Miniflux"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
            menu_instance.onMenuHold = utils.triggerHoldCallback
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("Miniflux"),
                item_table = entries,
                multilines_forced = true,
                items_max_lines = view_mode == "magazine" and 5 or nil,
            }
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                backends.showMinifluxFeed(self, account, client, feed_node, { reuse = true })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            menu_instance.onMenuHold = utils.triggerHoldCallback
            utils.ensureMenuCloseHook(menu_instance)
            utils.trackMenuPage(menu_instance, feed_node)
        end
    end

    if reuse_cached_stories and #feed_node._rss_stories > 0 then
        finalizeMenu()
        return
    end

    NetworkMgr:runWhenOnline(function()
        local fetch_options = {
            page = fetch_page or 1,
        }

        local ok, data = client:fetchStories(feed_node.id, fetch_options)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = data or _("Failed to fetch stories."),
            })
            return
        end

        local stories = data.stories or {}
        feed_node._rss_stories = stories
        feed_node._rss_story_keys = {}
        for _, story in ipairs(stories) do
            local key = story.story_hash or story.hash or story.guid or story.story_id or story.id
            if key then
                feed_node._rss_story_keys[key] = true
            end
        end
        feed_node._rss_page = fetch_page or 1
        feed_node._rss_has_more = data.more_stories or false

        finalizeMenu()
    end)
end

return backends