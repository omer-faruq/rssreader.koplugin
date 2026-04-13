local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local Miniflux = {}
Miniflux.__index = Miniflux

local USER_AGENT = "KOReader RSSReader"

local function requestWithScheme(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "http"
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

local function joinUrl(base, path)
    local normalized_base = sanitizeBaseUrl(base)
    if not normalized_base then
        return nil
    end
    local normalized_path = path or ""
    if normalized_path ~= "" and not normalized_path:match("^/") then
        normalized_path = "/" .. normalized_path
    end
    return normalized_base .. normalized_path
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return {}
    end
    
    local story = {}
    
    local id_value = entry.id
    if id_value ~= nil then
        local id_str = tostring(id_value)
        story.id = id_str
        story.story_id = id_str
    end
    
    local feed_id_value = entry.feed_id or entry.feedId
    if feed_id_value ~= nil then
        local feed_id_str = tostring(feed_id_value)
        story.feed_id = feed_id_str
        story.story_feed_id = feed_id_str
    end
    
    if entry.feed and entry.feed.title then
        story.feed_title = entry.feed.title
    end
    
    local title = entry.title or ""
    story.title = title
    story.story_title = title
    
    local permalink = entry.url or entry.link
    story.permalink = permalink
    story.story_permalink = permalink
    
    local content = entry.content or entry.summary or entry.description or ""
    story.content = content
    story.story_content = content
    
    local timestamp = entry.published_at or entry.created_at
    if type(timestamp) == "string" then
        local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
        if year then
            local time_table = {
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            }
            local unix_time = os.time(time_table)
            if unix_time then
                story.timestamp = unix_time * 1000
                story.created_on_time = unix_time * 1000
            end
        end
    end
    
    local status = entry.status or ""
    local read_flag = (status == "read")
    story.read = read_flag
    story.read_status = read_flag
    story.story_read = read_flag
    
    if entry.starred ~= nil then
        story.starred = entry.starred and true or false
    end
    
    if entry.author then
        story.author = entry.author
    end
    
    return story
end

function Miniflux:new(account)
    local instance = {
        account = account or {},
        structure_cache = nil,
        tree_cache = nil,
        feeds_cache = nil,
        categories_cache = nil,
    }
    setmetatable(instance, self)
    return instance
end

function Miniflux:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil
    end
    
    local api_key = auth.api_key or auth.apikey or auth.token or auth.key
    if type(api_key) ~= "string" or api_key == "" then
        api_key = nil
    end
    
    local base_url = auth.base_url or auth.baseurl or auth.endpoint or auth.url or auth.api_url
    base_url = sanitizeBaseUrl(base_url)
    
    return api_key, base_url
end

function Miniflux:performRequest(method, path, body_table)
    local api_key, base_url = self:getCredentials()
    
    if not api_key then
        return false, "Missing Miniflux API key"
    end
    
    if not base_url then
        return false, "Missing Miniflux base URL"
    end
    
    local target_url = joinUrl(base_url, path)
    if not target_url then
        return false, "Unable to build Miniflux request URL"
    end
    
    local http_method = method or "GET"
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
        ["X-Auth-Token"] = api_key,
    }
    
    local body
    if body_table ~= nil then
        local ok, encoded = pcall(json.encode, body_table)
        if not ok then
            return false, string.format("Failed to encode request body: %s", encoded)
        end
        body = encoded
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    
    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, _, status = requestWithScheme({
        url = target_url,
        method = http_method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()
    
    local numeric_code = tonumber(code)
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        local message = string.format("Miniflux request failed (HTTP %s - %s)", tostring(code), tostring(status))
        return false, message
    end
    
    local text = table.concat(response_chunks)
    
    if text == "" or text == "null" then
        return true, {}
    end
    
    local decoded = safe_json_decode(text)
    if not decoded then
        logger.warn("Miniflux response parse error", text or "no data")
        return false, "Unable to parse Miniflux response"
    end
    
    if decoded.error_message then
        return false, tostring(decoded.error_message)
    end
    
    return true, decoded
end

function Miniflux:fetchCategories(force)
    if self.categories_cache and not force then
        return true, self.categories_cache
    end
    
    local ok, data = self:performRequest("GET", "/v1/categories")
    if not ok then
        return false, data
    end
    
    self.categories_cache = data or {}
    return true, self.categories_cache
end

function Miniflux:fetchFeeds(force)
    if self.feeds_cache and not force then
        return true, self.feeds_cache
    end
    
    local ok, data = self:performRequest("GET", "/v1/feeds")
    if not ok then
        return false, data
    end
    
    self.feeds_cache = data or {}
    return true, self.feeds_cache
end

function Miniflux:buildTree(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end
    
    local ok_cat, categories = self:fetchCategories(force)
    if not ok_cat then
        return false, categories
    end
    
    local ok_feeds, feeds = self:fetchFeeds(force)
    if not ok_feeds then
        return false, feeds
    end
    
    local category_map = {}
    for _, category in ipairs(categories) do
        if category.id then
            category_map[tostring(category.id)] = {
                kind = "folder",
                id = tostring(category.id),
                title = category.title or "Category",
                children = {},
            }
        end
    end
    
    local uncategorized_feeds = {}
    
    for _, feed in ipairs(feeds) do
        if feed.id then
            local feed_node = {
                kind = "feed",
                id = tostring(feed.id),
                title = feed.title or "Feed",
                feed = feed,
            }
            
            local category_id = feed.category and feed.category.id
            if category_id and category_map[tostring(category_id)] then
                table.insert(category_map[tostring(category_id)].children, feed_node)
            else
                table.insert(uncategorized_feeds, feed_node)
            end
        end
    end
    
    for _, folder_node in pairs(category_map) do
        local category_id = folder_node.id
        
        table.insert(folder_node.children, 1, {
            kind = "feed",
            id = "__miniflux_category_unread__" .. category_id,
            title = "★ All Unread",
            _virtual = true,
            _read_filter = "unread",
            _category_id = category_id,
        })
        table.insert(folder_node.children, 1, {
            kind = "feed",
            id = "__miniflux_category_all__" .. category_id,
            title = "★ All Feeds",
            _virtual = true,
            _read_filter = "all",
            _category_id = category_id,
        })
    end
    
    local root_children = {}
    
    for _, folder in pairs(category_map) do
        if #folder.children > 0 then
            table.insert(root_children, folder)
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
    
    table.insert(root_children, 1, {
        kind = "feed",
        id = "__miniflux_all_unread__",
        title = "★ All Unread",
        _virtual = true,
        _read_filter = "unread",
    })
    table.insert(root_children, 1, {
        kind = "feed",
        id = "__miniflux_all_feeds__",
        title = "★ All Feeds",
        _virtual = true,
        _read_filter = "all",
    })
    
    self.tree_cache = {
        kind = "root",
        title = (self.account and self.account.name) or "Miniflux",
        children = root_children,
    }
    
    return true, self.tree_cache
end

function Miniflux:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier"
    end
    
    options = options or {}
    local limit = 50
    local offset = 0
    
    local page = options.page or 1
    if page < 1 then
        page = 1
    end
    offset = (page - 1) * limit
    
    local is_virtual_all = feed_id == "__miniflux_all_feeds__" or feed_id == "__miniflux_all_unread__"
    local is_category_virtual = feed_id:match("^__miniflux_category_")
    
    local path = "/v1/entries"
    local query_parts = {}
    
    table.insert(query_parts, "limit=" .. tostring(limit))
    table.insert(query_parts, "offset=" .. tostring(offset))
    table.insert(query_parts, "order=published_at")
    table.insert(query_parts, "direction=desc")
    
    if is_virtual_all then
        if feed_id == "__miniflux_all_unread__" then
            table.insert(query_parts, "status=unread")
        end
    elseif is_category_virtual then
        local category_id
        local read_filter
        
        if feed_id:match("^__miniflux_category_unread__") then
            category_id = feed_id:gsub("^__miniflux_category_unread__", "")
            read_filter = "unread"
        elseif feed_id:match("^__miniflux_category_all__") then
            category_id = feed_id:gsub("^__miniflux_category_all__", "")
            read_filter = "all"
        end
        
        if category_id then
            table.insert(query_parts, "category_id=" .. url.escape(category_id))
            if read_filter == "unread" then
                table.insert(query_parts, "status=unread")
            end
        end
    else
        table.insert(query_parts, "feed_id=" .. url.escape(tostring(feed_id)))
    end
    
    local full_path = path .. "?" .. table.concat(query_parts, "&")
    
    local ok, data = self:performRequest("GET", full_path)
    if not ok then
        return false, data
    end
    
    local stories = {}
    local entries = data.entries or {}
    
    for _, entry in ipairs(entries) do
        local story = normalizeEntry(entry)
        if is_virtual_all or is_category_virtual then
            story._from_virtual_feed = true
        end
        table.insert(stories, story)
    end
    
    local total = data.total or 0
    local has_more = (offset + limit) < total
    
    return true, {
        stories = stories,
        more_stories = has_more,
    }
end

function Miniflux:markStoryAsRead(feed_id, story)
    local story_id = story and (story.id or story.story_id)
    if not story_id then
        return false, "Missing story ID"
    end
    
    local entry_ids = { tonumber(story_id) }
    local payload = {
        entry_ids = entry_ids,
        status = "read",
    }
    
    return self:performRequest("PUT", "/v1/entries", payload)
end

function Miniflux:markStoryAsUnread(feed_id, story)
    local story_id = story and (story.id or story.story_id)
    if not story_id then
        return false, "Missing story ID"
    end
    
    local entry_ids = { tonumber(story_id) }
    local payload = {
        entry_ids = entry_ids,
        status = "unread",
    }
    
    return self:performRequest("PUT", "/v1/entries", payload)
end

function Miniflux:markFeedAsRead(feed_id)
    if not feed_id then
        return false, "Missing feed identifier"
    end
    
    local path = "/v1/feeds/" .. url.escape(tostring(feed_id)) .. "/mark-all-as-read"
    return self:performRequest("PUT", path)
end

function Miniflux:markCategoryAsRead(category_id)
    if not category_id then
        return false, "Missing category identifier"
    end
    
    local path = "/v1/categories/" .. url.escape(tostring(category_id)) .. "/mark-all-as-read"
    return self:performRequest("PUT", path)
end

return Miniflux
