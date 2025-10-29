local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local Button = require("ui/widget/button")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Device = require("device")
local _ = require("gettext")
local json = require("common/json")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local Screen = Device.screen

local Accounts = require("rssreader_accounts")
local MenuBuilder = require("rssreader_menu")

local FEED_STATE_MAX_AGE_SECONDS = 30 * 60

local RSSReader = WidgetContainer:extend{
    name = "rssreader",
    is_doc_only = false,
}

function RSSReader:init()
    self.accounts = Accounts:new()
    self.history = {}
    self.current_menu_info = nil
    self.closing_for_navigation = false
    self.feed_states = {}
    self.last_feed_key = nil
    self.root_reopen = nil
    self._preserve_feed_state = false
    self.state_file = DataStorage:getSettingsDir() .. "/rssreader_state.json"
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function RSSReader:getStateFilePath()
    return self.state_file
end

function RSSReader:getFeedKey(account_name, feed_id)
    if not account_name or feed_id == nil then
        return nil
    end
    return tostring(account_name) .. "::" .. tostring(feed_id)
end

function RSSReader:updateFeedState(account_name, feed_id, fields)
    if type(fields) ~= "table" then
        return
    end
    local key = self:getFeedKey(account_name, feed_id)
    if not key then
        return
    end
    local target = self.feed_states[key]
    if not target then
        target = {}
        self.feed_states[key] = target
    end
    for k, v in pairs(fields) do
        if type(v) == "table" then
            target[k] = util.tableDeepCopy(v)
        else
            target[k] = v
        end
    end
end

function RSSReader:getFeedState(account_name, feed_id)
    local key = self:getFeedKey(account_name, feed_id)
    if not key then
        return nil
    end
    return self.feed_states[key]
end

function RSSReader:clearFeedState(account_name, feed_id)
    local key = self:getFeedKey(account_name, feed_id)
    if not key then
        return
    end
    self.feed_states[key] = nil
end

function RSSReader:resetFeedNodeCache(feed_node)
    if not feed_node then
        return
    end
    feed_node._rss_stories = nil
    feed_node._rss_story_keys = nil
    feed_node._rss_page = nil
    feed_node._rss_has_more = nil
    feed_node._rss_menu_page = nil
end

function RSSReader:requestFeedStatePreservation()
    self._preserve_feed_state = true
end

function RSSReader:handleFeedMenuExit(menu_instance)
    if not menu_instance then
        self._preserve_feed_state = false
        return
    end
    local feed_node = menu_instance._rss_feed_node
    if not feed_node then
        self._preserve_feed_state = false
        return
    end
    local account_name = feed_node._account_name or "unknown"
    if self._preserve_feed_state then
        self._preserve_feed_state = false
        return
    end
    self:clearFeedState(account_name, feed_node.id)
    self:resetFeedNodeCache(feed_node)
    local key = self:getFeedKey(account_name, feed_node.id)
    if self.last_feed_key == key then
        self.last_feed_key = nil
    end
    self._preserve_feed_state = false
end

function RSSReader:saveNavigationState()
    local state = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        menu_stack = {},
        current_feed_state = nil,
    }
    local now = os.time()

    -- Build menu stack from history
    for i, reopen_func in ipairs(self.history) do
        table.insert(state.menu_stack, {
            index = i,
            type = "history_entry"
        })
    end

    -- Add current menu if exists
    if self.current_menu_info then
        table.insert(state.menu_stack, {
            index = #self.history + 1,
            type = "current_menu"
        })
    end

    -- Capture feed state if current menu has feed node
    local current_menu = self.current_menu_info and self.current_menu_info.menu
    local feed_node = current_menu and current_menu._rss_feed_node
    if not feed_node and self.last_feed_key then
        feed_node = self.feed_states[self.last_feed_key]
    end
    if current_menu and current_menu._rss_feed_node then
        feed_node = current_menu._rss_feed_node
    end
    if feed_node and feed_node.id then
        local menu_page
        if current_menu and type(current_menu.page) == "number" then
            menu_page = current_menu.page
        elseif type(feed_node._rss_menu_page) == "number" then
            menu_page = feed_node._rss_menu_page
        end
        if menu_page then
            local account_name = feed_node._account_name or "unknown"
            local current_page = feed_node._rss_page or 0
            local has_more = feed_node._rss_has_more or false
            local stories_copy = feed_node._rss_stories and util.tableDeepCopy(feed_node._rss_stories) or {}
            local story_keys_copy = {}
            for key, value in pairs(feed_node._rss_story_keys or {}) do
                story_keys_copy[key] = value and true or nil
            end

            self:updateFeedState(account_name, feed_node.id, {
                menu_page = menu_page,
                stories = stories_copy,
                story_keys = story_keys_copy,
                current_page = current_page,
                has_more = has_more,
                feed_url = feed_node.url,
                feed_title = feed_node.title,
            })

            state.current_feed_state = {
                account_name = account_name,
                feed_id = feed_node.id,
                feed_title = feed_node.title,
                feed_url = feed_node.url,
                stories = stories_copy,
                story_keys = story_keys_copy,
                current_page = current_page,
                next_fetch_index = current_page + 1,
                has_more = has_more,
                menu_page = menu_page,
            }
            state.current_feed_state_timestamp = now
        end
    end

    -- Save to file
    local file = io.open(self.state_file, "w")
    if file then
        file:write(json.encode(state))
        file:close()
    end
end

function RSSReader:loadNavigationState()
    local file = io.open(self.state_file, "r")
    if not file then
        return nil
    end

    local content = file:read("*all")
    file:close()

    if content and content ~= "" then
        local ok, state = pcall(function() return json.decode(content) end)
        if ok and state then
            return state
        end
    end

    return nil
end

function RSSReader:isFeedStateRecent(state, current_time)
    if not state or not state.current_feed_state then
        return false
    end
    local last_timestamp = state.current_feed_state_timestamp
    if type(last_timestamp) == "string" then
        last_timestamp = tonumber(last_timestamp)
    end
    if type(last_timestamp) ~= "number" then
        return false
    end
    local now = current_time or os.time()
    return (now - last_timestamp) <= FEED_STATE_MAX_AGE_SECONDS
end

function RSSReader:restoreNavigationState(state)
    if not state or not state.current_feed_state then
        return false
    end

    -- Try to restore feed list state
    local feed_state = state.current_feed_state
    local accounts = self.accounts:getAccounts()

    -- Find matching account
    local target_account = nil
    for _, account in ipairs(accounts) do
        if account.name == feed_state.account_name then
            target_account = account
            break
        end
    end

    if not target_account then
        return false
    end

    -- Restore feed list
    self:restoreFeedState(target_account, feed_state)
    return true
end

function RSSReader:restoreFeedState(account, feed_state)
    local builder = MenuBuilder:new{ accounts = self.accounts, reader = self }

    if account.type == "newsblur" then
        self:restoreNewsBlurFeed(builder, account, feed_state)
    elseif account.type == "commafeed" then
        self:restoreCommaFeedFeed(builder, account, feed_state)
    elseif account.type == "local" then
        self:restoreLocalFeed(builder, account, feed_state)
    end
end

function RSSReader:restoreLocalFeed(builder, account, feed_state)
    if not builder or not account or not feed_state then
        return
    end

    local account_name = account.name or "local"
    local feed
    if builder.local_store and account_name then
        local feeds = builder.local_store:listFeeds(account_name)
        for _, candidate in ipairs(feeds) do
            if (feed_state.feed_url and candidate.url == feed_state.feed_url)
                or (candidate.id and feed_state.feed_id and candidate.id == feed_state.feed_id) then
                feed = util.tableDeepCopy(candidate)
                break
            end
        end
    end

    if not feed then
        feed = {
            id = feed_state.feed_id,
            title = feed_state.feed_title,
            url = feed_state.feed_url,
        }
    end

    feed.id = feed.id or feed_state.feed_id or feed.url or feed.title
    feed.title = feed.title or feed_state.feed_title
    feed.url = feed.url or feed_state.feed_url

    local feed_node = {
        id = feed.id,
        title = feed.title,
        _account_name = account_name,
        _rss_reader = self,
        _rss_stories = util.tableDeepCopy(feed_state.stories or {}),
        _rss_story_keys = {},
        _rss_page = feed_state.current_page or 1,
        _rss_has_more = feed_state.has_more or false,
        _rss_menu_page = feed_state.menu_page,
    }

    for _, story in ipairs(feed_node._rss_stories) do
        local key = story.story_hash or story.hash or story.guid or story.story_id or story.id
        if key then
            feed_node._rss_story_keys[key] = true
        end
    end

    self:updateFeedState(account_name, feed_node.id, {
        menu_page = feed_node._rss_menu_page,
        stories = feed_node._rss_stories,
        story_keys = feed_node._rss_story_keys,
        current_page = feed_node._rss_page,
        has_more = feed_node._rss_has_more,
        feed_url = feed.url,
        feed_title = feed.title,
    })

    feed._rss_feed_node = feed_node
    feed._rss_account_name = account_name

    builder:showLocalFeed(feed, {
        account_name = account_name,
        reuse = true,
    })
end

function RSSReader:restoreNewsBlurFeed(builder, account, feed_state)
    if not self.accounts or type(self.accounts.getNewsBlurClient) ~= "function" then
        return
    end

    local client, err = self.accounts:getNewsBlurClient(account)
    if not client then
        return
    end

    -- Create a mock feed node with restored state
    local feed_node = {
        id = feed_state.feed_id,
        title = feed_state.feed_title,
        account_name = feed_state.account_name,
        _rss_stories = feed_state.stories,
        _rss_story_keys = {},
        _rss_page = feed_state.current_page,
        _rss_has_more = feed_state.has_more,
        _rss_menu_page = feed_state.menu_page,
    }
    self:updateFeedState(feed_state.account_name, feed_state.feed_id, {
        menu_page = feed_state.menu_page,
    })

    -- Rebuild story keys
    for _, story in ipairs(feed_state.stories) do
        local key = story.story_hash or story.hash or story.guid or story.story_id or story.id
        if key then
            feed_node._rss_story_keys[key] = true
        end
    end

    -- Show the restored feed
    builder:showNewsBlurFeed(account, client, feed_node, { reuse = true, menu_page = feed_state.menu_page })
end

function RSSReader:restoreCommaFeedFeed(builder, account, feed_state)
    if not self.accounts or type(self.accounts.getCommaFeedClient) ~= "function" then
        return
    end

    local client, err = self.accounts:getCommaFeedClient(account)
    if not client then
        return
    end

    -- Create a mock feed node with restored state
    local feed_node = {
        id = feed_state.feed_id,
        title = feed_state.feed_title,
        account_name = feed_state.account_name,
        _rss_stories = feed_state.stories,
        _rss_story_keys = {},
        _rss_page = feed_state.current_page,
        _rss_has_more = feed_state.has_more
    }

    -- Rebuild story keys
    for _, story in ipairs(feed_state.stories) do
        local key = story.story_hash or story.hash or story.guid or story.story_id or story.id
        if key then
            feed_node._rss_story_keys[key] = true
        end
    end

    -- Show the restored feed
    builder:showCommaFeedFeed(account, client, feed_node, { reuse = true, menu_page = feed_state.menu_page })
end

function RSSReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("rssreader_open", {
        category = "none",
        event = "RSSReader",
        title = _("RSS Reader"),
        general = true,
    })
end

function RSSReader:addToMainMenu(menu_items)
    menu_items.rss_reader = {
        text = _("RSS Reader"),
        sorting_hint = "search",
        callback = function()
            self:openAccountList()
        end,
    }
end

function RSSReader:onRSSReader()
    self:openAccountList()
end

local function removeWidgetFromGroup(group, widget)
    if not group or not widget then
        return
    end
    for index = #group, 1, -1 do
        if group[index] == widget then
            table.remove(group, index)
            break
        end
    end
end

function RSSReader:updateBackButton(menu_instance)
    if not menu_instance or not menu_instance.page_info then
        return
    end

    if #self.history == 0 then
        if not menu_instance._rss_back_span then
            menu_instance._rss_back_span = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
        end
        if not menu_instance._rss_back_button then
            menu_instance._rss_back_button = Button:new{
                text = _("Back"),
                bordersize = 0,
                show_parent = menu_instance.show_parent or menu_instance,
            }
        elseif menu_instance._rss_back_button.setText then
            menu_instance._rss_back_button:setText(_("Back"), menu_instance._rss_back_button.width)
        else
            menu_instance._rss_back_button.text = _("Back")
        end
        menu_instance._rss_back_button.callback = function()
            self:goBack()
        end
        menu_instance._rss_back_button:enable()
        if not menu_instance._rss_back_inserted then
            table.insert(menu_instance.page_info, menu_instance._rss_back_span)
            table.insert(menu_instance.page_info, menu_instance._rss_back_button)
            menu_instance._rss_back_inserted = true
            menu_instance.page_info:resetLayout()
        end
        return
    end

    if not menu_instance._rss_back_span then
        menu_instance._rss_back_span = HorizontalSpan:new{
            width = Screen:scaleBySize(16),
        }
    end
    if not menu_instance._rss_back_button then
        menu_instance._rss_back_button = Button:new{
            text = _("Back"),
            bordersize = 0,
            show_parent = menu_instance.show_parent or menu_instance,
        }
    elseif menu_instance._rss_back_button.setText then
        menu_instance._rss_back_button:setText(_("Back"), menu_instance._rss_back_button.width)
    else
        menu_instance._rss_back_button.text = _("Back")
    end

    menu_instance._rss_back_button.callback = function()
        self:goBackFromMenu(menu_instance)
    end
    menu_instance._rss_back_button:enable()

    if not menu_instance._rss_back_inserted then
        table.insert(menu_instance.page_info, menu_instance._rss_back_span)
        table.insert(menu_instance.page_info, menu_instance._rss_back_button)
        menu_instance._rss_back_inserted = true
    end
    menu_instance.page_info:resetLayout()
end

function RSSReader:goBackFromMenu(menu_instance)
    if menu_instance and menu_instance._rss_is_root_menu then
        if self.current_menu_info and self.current_menu_info.menu == menu_instance then
            self.current_menu_info = nil
        end
        self.history = {}
        UIManager:close(menu_instance)
        return
    end

    self:goBack()
end

function RSSReader:onMenuClosed(menu_instance)
    if UIManager:isWidgetShown(menu_instance) then
        return
    end

    if self.current_menu_info and self.current_menu_info.menu == menu_instance then
        self.current_menu_info = nil
        -- Only reset history if we're closing the top-level menu without navigating.
        if not self.closing_for_navigation and menu_instance._rss_is_root_menu then
            self.history = {}
        end
    end
end

function RSSReader:showMenu(menu_instance, reopen_func, opts)
    opts = opts or {}

    if #self.history == 0 and not opts.reset_history and not self.current_menu_info and self.root_reopen then
        table.insert(self.history, self.root_reopen)
    end

    if opts.reset_history then
        self.history = {}
        menu_instance._rss_is_root_menu = true
    elseif self.current_menu_info and self.current_menu_info.reopen then
        table.insert(self.history, self.current_menu_info.reopen)
        menu_instance._rss_is_root_menu = false
    else
        menu_instance._rss_is_root_menu = menu_instance._rss_is_root_menu or false
    end

    if self.current_menu_info and self.current_menu_info.menu then
        self.closing_for_navigation = true
        UIManager:close(self.current_menu_info.menu)
        self.closing_for_navigation = false
    end

    menu_instance.close_callback = function()
        self:onMenuClosed(menu_instance)
    end

    self.current_menu_info = {
        menu = menu_instance,
        reopen = reopen_func,
    }
    menu_instance._rss_reader = self
    if menu_instance._rss_feed_node then
        self.last_feed_key = self:getFeedKey(menu_instance._rss_feed_node._account_name or "unknown", menu_instance._rss_feed_node.id)
    end

    UIManager:show(menu_instance)
    self:updateBackButton(menu_instance)

    -- Save navigation state after showing menu
    self:saveNavigationState()
end

function RSSReader:goBack()
    if #self.history == 0 then
        if self.current_menu_info and self.current_menu_info.menu then
            local menu = self.current_menu_info.menu
            if menu and menu._rss_feed_node then
                self:handleFeedMenuExit(menu)
            end
            UIManager:close(self.current_menu_info.menu)
            self.current_menu_info = nil
        end
        return
    end

    local reopen = table.remove(self.history)
    local current = self.current_menu_info
    self.closing_for_navigation = true
    if current and current.menu then
        if current.menu._rss_feed_node then
            self:handleFeedMenuExit(current.menu)
        end
        UIManager:close(current.menu)
    end
    self.closing_for_navigation = false
    self.current_menu_info = nil

    if reopen then
        reopen()
    end
end

function RSSReader:openAccountList(opts)
    opts = opts or {}

    self.root_reopen = function()
        self:openAccountList({ skip_restore = true })
    end

    if not opts.skip_restore then
        -- Try to restore previous state first
        local saved_state = self:loadNavigationState()
        if saved_state and self:isFeedStateRecent(saved_state) and self:restoreNavigationState(saved_state) then
            return
        end
    end

    local accounts = self.accounts:getAccounts()
    local builder = MenuBuilder:new{ accounts = self.accounts, reader = self }
    local entries = builder:buildAccountEntries(accounts, function(account)
        self:openAccount(account)
    end)

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No RSS accounts available."),
        })
        return
    end

    local menu_instance
    menu_instance = Menu:new{
        title = _("RSS Accounts"),
        item_table = entries,
    }
    self:showMenu(menu_instance, function()
        self:openAccountList({ skip_restore = true })
    end, { reset_history = true })
end

function RSSReader:openAccount(account)
    if not account then
        return
    end
    local builder = MenuBuilder:new{ accounts = self.accounts, reader = self }
    builder:openAccount(self, account)
end

return RSSReader
