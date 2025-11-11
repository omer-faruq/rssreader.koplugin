-- rssreader_freshrss.lua
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local mime = require("mime")

local FreshRSS = {}
FreshRSS.__index = FreshRSS

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
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function joinUrl(base, path, query_params)
    local normalized_base = sanitizeBaseUrl(base)
    if not normalized_base then
        return nil
    end
    local normalized_path = path or ""
    if not normalized_path:match("^/") then
        normalized_path = "/" .. normalized_path
    end
    local query_string = encodeQuery(query_params)
    return normalized_base .. normalized_path .. query_string
end

function FreshRSS:new(account)
    local instance = {
        account = account or {},
        auth_token = nil,
        last_login = nil,
        tree_cache = nil,
        token_cache = nil, -- For edit-tag operations
    }
    setmetatable(instance, self)
    return instance
end

function FreshRSS:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil, nil
    end
    local base_url = sanitizeBaseUrl(auth.base_url)
    local username = auth.username
    local password = auth.password -- This should be the API password set in FreshRSS
    return base_url, username, password
end

-- Authenticate using the ClientLogin flow
function FreshRSS:authenticate()
    if self.auth_token and self.last_login and (os.time() - self.last_login) < 1800 then
        return true -- Token is fresh
    end

    local base_url, username, password = self:getCredentials()
    if not base_url or not username or not password then
        return false, "Missing FreshRSS credentials."
    end

    -- The path must be /api/greader.php/accounts/ClientLogin
    local target_url = joinUrl(base_url, "/api/greader.php/accounts/ClientLogin")

    -- All parameters go into the POST body, as confirmed by capyreader
    local form_data = string.format("Email=%s&Passwd=%s&client=%s&service=%s",  
        url.escape(username),  
        url.escape(password),  
        url.escape(USER_AGENT),  
        url.escape("reader")  
    )

    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, headers, status = requestWithScheme({
        url = target_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#form_data),
            ["User-Agent"] = USER_AGENT,
        },
        source = ltn12.source.string(form_data),
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    local numeric_code = tonumber(code)
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        return false, string.format("FreshRSS login failed (HTTP %s - %s)", code, status)
    end

    local body = table.concat(response_chunks)
    local auth_token = body:match("Auth=([%w%-/_]+)")
    if not auth_token then
        return false, "Failed to get Auth token from FreshRSS response."
    end

    self.auth_token = auth_token
    self.last_login = os.time()
    self.token_cache = nil -- Clear edit-token
    return true
end

-- Get the edit-token required for marking items
function FreshRSS:getEditToken()
    if self.token_cache then
        return true, self.token_cache
    end
    local ok, token_or_err = self:authorizedRequest("GET", "/api/greader.php/reader/api/0/token")
    if not ok then
        return false, token_or_err
    end
    if type(token_or_err) ~= "string" or token_or_err == "" then
        return false, "Did not receive valid edit-token"
    end
    self.token_cache = token_or_err
    return true, self.token_cache
end

-- Perform an authorized API request
function FreshRSS:authorizedRequest(method, path, query_params, body)
    local ok, err = self:authenticate()
    if not ok then
        return false, err
    end

    local base_url = self.account.auth.base_url
    local target_url = joinUrl(base_url, path, query_params)

    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Authorization"] = "GoogleLogin auth=" .. self.auth_token,
    }

    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(#body)
    end

    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, _, status = requestWithScheme({
        url = target_url,
        method = method or "GET",
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    local numeric_code = tonumber(code)
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        -- If unauthorized, clear token and retry once
        if numeric_code == 401 and self.last_login ~= nil then
            self.auth_token = nil
            self.last_login = nil
            logger.warn("FreshRSS auth token expired, retrying...")
            return self:authorizedRequest(method, path, query_params, body)
        end
        return false, string.format("FreshRSS request failed (HTTP %s - %s)", code, status)
    end

    local text = table.concat(response_chunks)
    -- For edit-tag, response is just "OK"
    if path == "/api/greader.php/reader/api/0/edit-tag" or path == "/api/greader.php/reader/api/0/token" then
        return true, text
    end

    local decoded = safe_json_decode(text)
    if not decoded then
        return false, "Unable to parse FreshRSS JSON response"
    end

    return true, decoded
end

function FreshRSS:fetchStructure(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    -- 1. Get all subscriptions
    local ok, subs_data = self:authorizedRequest("GET", "/api/greader.php/reader/api/0/subscription/list", { output = "json" })
    if not ok then
        return false, subs_data
    end

    -- 2. Get all tags (folders)
    local ok, tags_data = self:authorizedRequest("GET", "/api/greader.php/reader/api/0/tag/list", { output = "json" })
    if not ok then
        return false, tags_data
    end

    self.tree_cache = self:buildTreeFromData(subs_data, tags_data)
    return true, self.tree_cache
end

function FreshRSS:buildTreeFromData(subs_data, tags_data)
    local feeds_map = {}
    local feeds_in_folders = {}
    local folders = {}
    local folders_map = {}

    -- Process tags (folders)
    for _, tag in ipairs(tags_data.tags or {}) do
        if tag.type == "folder" then
            local folder_id = tag.id
            local folder_node = {
                kind = "folder",
                id = folder_id,
                title = (tag.label or folder_id:match("user/-/label/(.*)")) or "Folder",
                children = {},
            }
            folders[#folders + 1] = folder_node
            folders_map[folder_id] = folder_node
        end
    end

    -- Process subscriptions (feeds)
    for _, feed in ipairs(subs_data.subscriptions or {}) do
        local feed_node = {
            kind = "feed",
            id = feed.id, -- e.g., "feed/http://..."
            title = feed.title or "Untitled Feed",
            feed = {
                id = feed.id,
                title = feed.title,
                url = feed.htmlUrl,
                feed_url = feed.id:gsub("^feed/", ""),
                unreadCount = feed.unreadCount or 0,
            },
        }
        feeds_map[feed.id] = feed_node

        local added_to_folder = false
        for _, category in ipairs(feed.categories or {}) do
            if category.type == "folder" then
                local folder = folders_map[category.id]
                if folder then
                    table.insert(folder.children, feed_node)
                    feeds_in_folders[feed.id] = true
                    added_to_folder = true
                end
            end
        end

        if not added_to_folder then
            -- Add to root
            table.insert(folders, feed_node)
        end
    end

    return {
        kind = "root",
        title = (self.account and self.account.name) or "FreshRSS",
        children = folders,
        feeds = feeds_map,
    }
end

function FreshRSS:buildTree(force)
    return self:fetchStructure(force)
end

local function normalizeEntry(entry)
    if type(entry) ~= "table" then return {} end
    local is_read = false
    for _, category in ipairs(entry.categories or {}) do
        if category:find("/state/com.google/read$") then
            is_read = true
            break
        end
    end

    local content = (entry.content and entry.content.content) or (entry.summary and entry.summary.content) or ""
    local permalink = (entry.alternate and entry.alternate[1] and entry.alternate[1].href) or entry.id

    return {
        id = entry.id,
        story_id = entry.id,
        feed_id = entry.origin and entry.origin.streamId,
        title = entry.title or "Untitled",
        story_title = entry.title or "Untitled",
        permalink = permalink,
        story_permalink = permalink,
        content = content,
        story_content = content,
        timestamp = (entry.published or entry.updated or 0) * 1000,
        read = is_read,
        read_status = is_read,
        story_read = is_read,
        author = entry.author,
    }
end

function FreshRSS:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier."
    end
    options = options or {}
    local page = options.page or 1

    local query = {
        output = "json",
        n = 50, -- Number of items to fetch
    }
    if options.continuation then
        query.c = options.continuation
    end

    if options.published_since then
        -- 'nt' means "newer than"
        query.nt = options.published_since 
    end
 
    if options.read_filter == "unread_only" then
        -- 'xt' means "exclude tag". We exclude items with the "read" state.
        query.xt = "user/-/state/com.google/read"
    elseif options.read_filter == "read_only" then
        -- 'it' means "include tag".
        query.it = "user/-/state/com.google/read"
    end

    -- We fetch unread first, then all. FreshRSS doesn't have a simple page number.
    -- This implementation is simple and just fetches the latest 50.
    -- A real implementation would need to handle the 'c' (continuation) param.

    local ok, data_or_err = self:authorizedRequest("GET", "/api/greader.php/reader/api/0/stream/contents/" .. url.escape(feed_id), query)
    if not ok then
        return false, data_or_err
    end

    local stories = {}
    for _, entry in ipairs(data_or_err.items or {}) do
        table.insert(stories, normalizeEntry(entry))
    end

    return true, {
        stories = stories,
        more_stories = data_or_err.continuation and true or false,
        continuation = data_or_err.continuation,
    }
end

function FreshRSS:markStory(story, add_tag, remove_tag)
    local ok, token = self:getEditToken()
    if not ok then return false, token end

    local story_id = (story and (story.id or story.story_id))
    if not story_id then return false, "Missing story ID" end

    -- Data for a POST request must be in the body, not the query string.
    local post_data = {
        client = USER_AGENT,
        T = token,
        i = story_id,
    }
    if add_tag then
        post_data.a = add_tag
    end
    if remove_tag then
        post_data.r = remove_tag
    end

    -- We must manually encode the body for a POST request.
    -- We pass 'nil' for the query_params.
    local body_string = encodeQuery(post_data):gsub("^%?", "") -- remove leading '?' from encodeQuery

    local ok, err = self:authorizedRequest("POST", "/api/greader.php/reader/api/0/edit-tag", nil, body_string)
    if not ok then
        -- If token was bad, clear it and retry
        if tostring(err):find("Token") then
            self.token_cache = nil
            return self:markStory(story, add_tag, remove_tag)
        end
        return false, err
    end
    return true
end

function FreshRSS:markStoryAsRead(feed_id, story)
    return self:markStory(story, "user/-/state/com.google/read", nil)
end

function FreshRSS:markStoryAsUnread(feed_id, story)
    return self:markStory(story, nil, "user/-/state/com.google/read")
end

function FreshRSS:markFeedAsRead(feed_id)
    return self:markStory({ id = feed_id }, "user/-/state/com.google/read", nil)
end

return FreshRSS