local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local md5 = require("ffi/sha2").md5

local Fever = {}
Fever.__index = Fever

local USER_AGENT = "KOReader RSSReader"

local function requestWithScheme(options)
    local parsed_url = url.parse(options.url)
    local scheme = parsed_url and parsed_url.scheme or "http"
    if scheme == "https" then
        return https.request(options)
    end
    return http.request(options)
end

local function safe_json_decode(payload)
    if not payload or payload == "" then
        return {}
    end
    local ok, decoded = pcall(json.decode, payload)
    if ok then
        return decoded
    end
    return nil
end

local function sanitizeBaseUrl(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

function Fever:new(account)
    local instance = {
        account = account or {},
        api_key = nil,
        tree_cache = nil,
    }
    setmetatable(instance, self)
    return instance
end

function Fever:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil, nil, nil
    end
    local base_url = sanitizeBaseUrl(auth.base_url)
    local username = auth.username
    local password = auth.password
    local api_key = auth.api_key
    return base_url, username, password, api_key
end

function Fever:getApiKey()
    if self.api_key then
        logger.dbg("Fever: Using cached API key")
        return self.api_key
    end

    local base_url, username, password, direct_api_key = self:getCredentials()
    
    if direct_api_key and type(direct_api_key) == "string" and direct_api_key ~= "" then
        self.api_key = direct_api_key
        return self.api_key
    end

    if not username or not password then
        return nil
    end

    local key_string = username .. ":" .. password
    self.api_key = md5(key_string)
    return self.api_key
end

function Fever:apiRequest(params)
    local base_url = self:getCredentials()
    if not base_url then
        return false, "Missing Fever API base URL"
    end

    local api_key = self:getApiKey()
    if not api_key then
        return false, "Failed to generate API key"
    end

    params = params or {}
    params.api_key = api_key
    params.api = ""

    local query_parts = {}
    for k, v in pairs(params) do
        if v ~= "" then
            table.insert(query_parts, string.format("%s=%s", url.escape(k), url.escape(tostring(v))))
        else
            table.insert(query_parts, url.escape(k))
        end
    end
    
    local target_url = base_url .. "/?" .. table.concat(query_parts, "&")

    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, _, status = requestWithScheme({
        url = target_url,
        method = "GET",
        headers = {
            ["User-Agent"] = USER_AGENT,
        },
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    local numeric_code = tonumber(code)
    
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        return false, string.format("Fever API request failed (HTTP %s - %s)", code, status)
    end

    local text = table.concat(response_chunks)
    
    local decoded = safe_json_decode(text)
    if not decoded then
        return false, "Unable to parse Fever API JSON response"
    end
    
    if decoded.auth ~= 1 then
        return false, "Fever API authentication failed"
    end

    return true, decoded
end

function Fever:fetchStructure(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    local ok1, groups_data = self:apiRequest({ groups = "" })
    if not ok1 then
        return false, groups_data
    end

    local ok2, feeds_data = self:apiRequest({ feeds = "" })
    if not ok2 then
        return false, feeds_data
    end
    
    self.feeds_cache = feeds_data.feeds or {}
    self.feed_id_to_title = {}
    for _, feed in ipairs(self.feeds_cache) do
        if feed.id and feed.title then
            self.feed_id_to_title[tostring(feed.id)] = feed.title
        end
    end

    local feeds_groups_data
    if groups_data.feeds_groups then
        feeds_groups_data = { feeds_groups = groups_data.feeds_groups }
    else
        local ok3, fg_data = self:apiRequest({ feeds_groups = "" })
        if ok3 then
            feeds_groups_data = fg_data
        else
            feeds_groups_data = {}
        end
    end

    return self:buildTreeFromData(groups_data, feeds_data, feeds_groups_data)
end

function Fever:buildTreeFromData(groups_data, feeds_data, feeds_groups_data)
    local groups = groups_data.groups or {}
    local feeds = feeds_data.feeds or {}
    local feeds_groups = feeds_groups_data.feeds_groups or {}

    if #feeds_groups == 0 then
        local root_children = {}
        for _, feed in ipairs(feeds) do
            table.insert(root_children, {
                kind = "feed",
                id = tostring(feed.id),
                title = feed.title,
                feed = {
                    unreadCount = 0,
                },
            })
        end
        
        table.sort(root_children, function(a, b)
            return (a.title or "") < (b.title or "")
        end)

        local tree = {
            kind = "root",
            title = self.account.name or "Fever API",
            children = root_children,
        }
        self.tree_cache = tree
        return true, tree
    end

    local group_map = {}
    for _, group in ipairs(groups) do
        group_map[group.id] = {
            kind = "folder",
            id = "group_" .. tostring(group.id),
            title = group.title,
            children = {},
        }
    end

    local feed_to_groups = {}
    for _, fg in ipairs(feeds_groups) do
        local feed_ids = {}
        for feed_id_str in string.gmatch(fg.feed_ids, "%d+") do
            local feed_id = tonumber(feed_id_str)
            if feed_id then
                table.insert(feed_ids, feed_id)
            end
        end
        for _, feed_id in ipairs(feed_ids) do
            feed_to_groups[feed_id] = feed_to_groups[feed_id] or {}
            table.insert(feed_to_groups[feed_id], fg.group_id)
        end
    end

    local uncategorized_feeds = {}
    
    for _, feed in ipairs(feeds) do
        local feed_node = {
            kind = "feed",
            id = tostring(feed.id),
            title = feed.title,
            feed = {
                unreadCount = 0,
            },
        }

        local assigned_groups = feed_to_groups[feed.id] or {}
        if #assigned_groups == 0 then
            table.insert(uncategorized_feeds, feed_node)
        else
            for _, group_id in ipairs(assigned_groups) do
                local group_node = group_map[group_id]
                if group_node then
                    table.insert(group_node.children, feed_node)
                else
                    if group_id == 0 then
                        table.insert(uncategorized_feeds, feed_node)
                    end
                end
            end
        end
    end

    local root_children = {}
    
    for _, group_node in pairs(group_map) do
        if #group_node.children > 0 then
            table.insert(root_children, group_node)
        end
    end
    
    for _, feed_node in ipairs(uncategorized_feeds) do
        table.insert(root_children, feed_node)
    end

    table.sort(root_children, function(a, b)
        local a_title = a.title or ""
        local b_title = b.title or ""
        if a.kind == "folder" and b.kind == "feed" then
            return true
        elseif a.kind == "feed" and b.kind == "folder" then
            return false
        else
            return a_title < b_title
        end
    end)

    local tree = {
        kind = "root",
        title = self.account.name or "Fever API",
        children = root_children,
    }

    self.tree_cache = tree
    return true, tree
end

function Fever:buildTree(force)
    return self:fetchStructure(force)
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return {}
    end

    local is_read = (entry.is_read == 1 or entry.is_read == "1")

    return {
        id = tostring(entry.id),
        story_id = tostring(entry.id),
        feed_id = tostring(entry.feed_id),
        feed_title = nil,
        title = entry.title or "Untitled",
        story_title = entry.title or "Untitled",
        permalink = entry.url or "",
        story_permalink = entry.url or "",
        content = entry.html or "",
        story_content = entry.html or "",
        timestamp = (entry.created_on_time or 0) * 1000,
        read = is_read,
        read_status = is_read,
        story_read = is_read,
        author = entry.author,
    }
end

function Fever:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier"
    end
    
    options = options or {}
    
    local is_virtual_all = (feed_id == "fever_all_feeds" or feed_id == "fever_all_unread")
    
    local params = {
        items = "",
    }
    
    if not is_virtual_all then
        params.feed_id = feed_id
    end
    
    if options.since_id then
        params.since_id = options.since_id
    end
    
    if options.max_id then
        params.max_id = options.max_id
    end
    
    if options.read_filter == "unread_only" then
        params.with_ids = nil
    end

    local ok, data = self:apiRequest(params)
    if not ok then
        return false, data
    end

    local stories = {}
    
    for _, entry in ipairs(data.items or {}) do
        local normalized = normalizeEntry(entry)
        
        if self.feed_id_to_title and normalized.feed_id then
            normalized.feed_title = self.feed_id_to_title[normalized.feed_id]
            
            if is_virtual_all and normalized.feed_title then
                normalized._is_from_virtual_feed = true
            end
        end
        
        if options.read_filter == "unread_only" and normalized.read then
        elseif options.read_filter == "read_only" and not normalized.read then
        else
            table.insert(stories, normalized)
        end
    end

    return true, {
        stories = stories,
        more_stories = false,
        continuation = nil,
    }
end

function Fever:markStoryAsRead(feed_id, story)
    local story_id = story and (story.id or story.story_id)
    if not story_id then
        return false, "Missing story ID"
    end

    local params = {
        mark = "item",
        as = "read",
        id = story_id,
    }

    local ok, err = self:apiRequest(params)
    if not ok then
        return false, err
    end
    
    return true
end

function Fever:markStoryAsUnread(feed_id, story)
    local story_id = story and (story.id or story.story_id)
    if not story_id then
        return false, "Missing story ID"
    end

    local params = {
        mark = "item",
        as = "unread",
        id = story_id,
    }

    local ok, err = self:apiRequest(params)
    if not ok then
        return false, err
    end
    
    return true
end

function Fever:markFeedAsRead(feed_id, before_timestamp)
    if not feed_id then
        return false, "Missing feed ID"
    end

    local params = {
        mark = "feed",
        as = "read",
        id = feed_id,
    }
    
    if before_timestamp then
        params.before = before_timestamp
    end

    local ok, err = self:apiRequest(params)
    if not ok then
        return false, err
    end
    
    return true
end

return Fever
