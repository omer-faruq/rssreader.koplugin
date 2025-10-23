local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local mime = require("mime")

local CommaFeed = {}
CommaFeed.__index = CommaFeed

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

local function encodeQuery(params)
    local components = {}
    local keys = {}
    for key in pairs(params or {}) do
        table.insert(keys, key)
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local value = params[key]
        if value ~= nil then
            table.insert(components, string.format("%s=%s", url.escape(tostring(key)), url.escape(tostring(value))))
        end
    end
    if #components > 0 then
        return "?" .. table.concat(components, "&")
    end
    return ""
end

local function sanitizeBaseUrl(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end
    -- collapse duplicate slashes after the protocol
    local prefix, rest = trimmed:match("^(https?://[^/]+)(/?.*)$")
    if prefix then
        rest = rest:gsub("//+", "/")
        trimmed = prefix .. rest
    else
        trimmed = trimmed:gsub("//+", "/")
    end
    return trimmed:gsub("/+$", "")
end

local function joinUrl(base, path, query_params)
    local normalized_base = sanitizeBaseUrl(base)
    if not normalized_base then
        return nil
    end
    local normalized_path = path or ""
    if normalized_path == "" then
        normalized_path = "/"
    elseif not normalized_path:match("^/") then
        normalized_path = "/" .. normalized_path
    end
    local query_string = encodeQuery(query_params)
    return normalized_base .. normalized_path .. query_string
end

local function buildFeedNode(feed_id, feed_data)
    return {
        kind = "feed",
        id = tostring(feed_id),
        title = feed_data.title or feed_data.name or feed_data.feed_title or feed_data.site_url or feed_data.url or tostring(feed_id),
        feed = feed_data,
    }
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then
        return {}
    end
    local story = {}
    local id_value = entry.id or entry.entryId
    if id_value ~= nil then
        local id_str = tostring(id_value)
        story.id = id_str
        story.story_id = id_str
    end
    local feed_id_value = entry.feedId or entry.feed_id
    if feed_id_value ~= nil then
        local feed_id_str = tostring(feed_id_value)
        story.feed_id = feed_id_str
        story.story_feed_id = feed_id_str
    end
    local title = entry.title or entry.name or entry.url or ""
    story.title = title
    story.story_title = title
    local permalink = entry.url or entry.link or entry.guid
    story.permalink = permalink
    story.story_permalink = permalink
    local content = entry.content or entry.summary or entry.description
    story.content = content
    story.story_content = content
    local timestamp = entry.insertedDate or entry.date or entry.timestamp
    story.created_on_time = timestamp
    story.timestamp = timestamp
    local read_flag = entry.read == true
    story.read = read_flag
    story.read_status = read_flag
    story.story_read = read_flag
    if entry.starred ~= nil then
        story.starred = entry.starred and true or false
    end
    story.author = entry.author
    story.guid = entry.guid
    return story
end

local function extractStoryId(story)
    if type(story) ~= "table" then
        return nil
    end
    local identifier = story.story_id or story.id
    if identifier == nil then
        return nil
    end
    local numeric = tonumber(identifier)
    if numeric then
        return tostring(math.floor(numeric))
    end
    return tostring(identifier)
end

function CommaFeed:new(account)
    local instance = {
        account = account or {},
        structure_cache = nil,
        tree_cache = nil,
        pagination_state = {},
    }
    setmetatable(instance, self)
    return instance
end

function CommaFeed:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil, nil, nil
    end
    local api_key = auth.api_key or auth.apikey or auth.key
    if type(api_key) ~= "string" or api_key == "" then
        api_key = nil
    end
    local base_url = auth.base_url or auth.baseurl or auth.endpoint or auth.url or auth.api_url
    base_url = sanitizeBaseUrl(base_url)
    if not base_url or base_url == "" then
        base_url = "https://www.commafeed.com/rest"
    end
    local username = auth.username or auth.user
    if type(username) == "string" and username == "" then
        username = nil
    end
    local password = auth.password or auth.pass
    if type(password) == "string" and password == "" then
        password = nil
    end
    return api_key, base_url, username, password
end

function CommaFeed:performRestRequest(method, path, query_params, body_table)
    local api_key, base_url, username, password = self:getCredentials()
    if not base_url then
        return false, "Missing CommaFeed base URL."
    end

    local query = {}
    for key, value in pairs(query_params or {}) do
        query[key] = value
    end
    if api_key then
        query.apiKey = query.apiKey or api_key
    end

    local target_url = joinUrl(base_url, path, query)
    if not target_url then
        return false, "Unable to build CommaFeed request URL."
    end

    local http_method = method or "GET"
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
    }
    if username and password then
        local token = string.format("%s:%s", username, password)
        headers["Authorization"] = "Basic " .. mime.b64(token)
    end

    local body
    if body_table ~= nil then
        local payload = {}
        for key, value in pairs(body_table) do
            payload[key] = value
        end
        if payload.apiKey == nil and api_key then
            payload.apiKey = api_key
        end
        local ok, encoded = pcall(json.encode, payload)
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
        local message = string.format("CommaFeed request failed (HTTP %s - %s)", tostring(code), tostring(status))
        return false, message
    end

    local text = table.concat(response_chunks)
    local decoded = safe_json_decode(text)
    if not decoded then
        local snippet = text and text:sub(1, 160) or ""
        logger.warn("CommaFeed response parse error", text or "no data")
        return false, string.format("Unable to parse CommaFeed response. First bytes: %s", snippet)
    end

    if decoded.error then
        return false, tostring(decoded.error)
    end

    return true, decoded
end

function CommaFeed:fetchStructure(force)
    if self.structure_cache and not force then
        return true, self.structure_cache
    end
    local ok, data_or_err = self:performRestRequest("GET", "/category/get")
    if not ok then
        return false, data_or_err
    end
    self.structure_cache = data_or_err
    self.tree_cache = nil
    return true, data_or_err
end

local function convertCategoryToNodes(category, feeds_map)
    if type(category) ~= "table" then
        return nil
    end
    local node_children = {}
    for _, subcategory in ipairs(category.children or {}) do
        local sub_node = convertCategoryToNodes(subcategory, feeds_map)
        if sub_node then
            table.insert(node_children, sub_node)
        end
    end
    for _, feed in ipairs(category.feeds or {}) do
        if type(feed) == "table" and feed.id ~= nil then
            local feed_id = tostring(feed.id)
            feeds_map[feed_id] = feed
            table.insert(node_children, buildFeedNode(feed_id, feed))
        end
    end

    local category_id = category.id or category.name or ""
    local title = category.name or category_id or "Category"
    return {
        kind = "folder",
        id = tostring(category_id),
        title = title,
        children = node_children,
    }
end

function CommaFeed:buildTree(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    local ok, root_category = self:fetchStructure(force)
    if not ok then
        return false, root_category
    end

    local feeds_map = {}
    local children = {}

    if type(root_category) == "table" then
        for _, subcategory in ipairs(root_category.children or {}) do
            local node = convertCategoryToNodes(subcategory, feeds_map)
            if node then
                table.insert(children, node)
            end
        end
        for _, feed in ipairs(root_category.feeds or {}) do
            if type(feed) == "table" and feed.id ~= nil then
                local feed_id = tostring(feed.id)
                feeds_map[feed_id] = feed
                table.insert(children, buildFeedNode(feed_id, feed))
            end
        end
    end

    if #children == 0 and type(root_category) == "table" then
        local node = convertCategoryToNodes(root_category, feeds_map)
        if node then
            children = node.children or {}
        end
    end

    self.tree_cache = {
        kind = "root",
        title = (self.account and self.account.name) or "CommaFeed",
        children = children,
        feeds = feeds_map,
    }
    return true, self.tree_cache
end

function CommaFeed:resetPagination(feed_id)
    if not feed_id then
        return
    end
    self.pagination_state[tostring(feed_id)] = {}
end

function CommaFeed:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier."
    end

    local id_str = tostring(feed_id)
    local page = (options and options.page) or 1
    if page < 1 then
        page = 1
    end

    local limit = 50
    local offset = (page - 1) * limit

    local query = {
        id = id_str,
        limit = limit,
        offset = offset,
        readType = "all",
        order = "desc",
    }

    local ok, data_or_err = self:performRestRequest("GET", "/feed/entries", query)
    if not ok then
        return false, data_or_err
    end

    local stories = {}
    for _, entry in ipairs(data_or_err.entries or {}) do
        table.insert(stories, normalizeEntry(entry))
    end

    local has_more = data_or_err.hasMore == true

    return true, {
        stories = stories,
        more_stories = has_more,
    }
end

local function toEntryIdValue(story_id)
    if not story_id then
        return nil
    end
    local numeric = tonumber(story_id)
    if numeric then
        return math.floor(numeric)
    end
    return story_id
end

function CommaFeed:markStoryAsRead(feed_id, story)
    local story_id = extractStoryId(story)
    if not story_id then
        return false, "Missing story identifiers"
    end
    local payload = {
        id = toEntryIdValue(story_id),
        read = true,
        entryId = toEntryIdValue(story_id),
    }
    return self:performRestRequest("POST", "/entry/mark", nil, payload)
end

function CommaFeed:markStoryAsUnread(feed_id, story)
    local story_id = extractStoryId(story)
    if not story_id then
        return false, "Missing story identifiers"
    end
    local payload = {
        id = toEntryIdValue(story_id),
        read = false,
        entryId = toEntryIdValue(story_id),
    }
    return self:performRestRequest("POST", "/entry/mark", nil, payload)
end

function CommaFeed:markFeedAsRead(feed_id)
    if not feed_id then
        return false, "Missing feed identifier."
    end
    return self:performRestRequest("POST", "/feed/markAllAsRead", {
        id = tostring(feed_id),
    })
end

function CommaFeed:markCategoryAsRead(category_id)
    if not category_id then
        return false, "Missing category identifier."
    end
    return self:performRestRequest("POST", "/category/markAllAsRead", {
        id = tostring(category_id),
    })
end

return CommaFeed
