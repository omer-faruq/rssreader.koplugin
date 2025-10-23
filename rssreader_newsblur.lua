local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local NewsBlur = {}
NewsBlur.__index = NewsBlur

NewsBlur.BASE_URL = "https://www.newsblur.com"
NewsBlur.LOGIN_ENDPOINT = "/api/login"
NewsBlur.SUBSCRIPTION_ENDPOINT = "/reader/feeds"
NewsBlur.STORIES_ENDPOINT = "/reader/feed"
NewsBlur.MARK_READ_ENDPOINT = "/reader/mark_story_as_read"
NewsBlur.MARK_UNREAD_ENDPOINT = "/reader/mark_story_as_unread"
NewsBlur.USER_AGENT = "KOReader RSSReader"

local function requestWithScheme(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "http"
    if scheme == "https" then
        return https.request(options)
    else
        return http.request(options)
    end
end

local function normalizeFeedKey(key)
    if type(key) ~= "string" then
        key = tostring(key)
    end
    local numeric = key:match("(%d+)$")
    if numeric then
        return numeric
    end
    return key
end

local function safe_json_decode(payload)
    local ok, decoded = pcall(json.decode, payload)
    if ok then
        return decoded
    end
    return nil
end

local function encodeForm(params)
    local parts = {}
    for key, value in pairs(params or {}) do
        table.insert(parts, string.format("%s=%s", url.escape(key), url.escape(tostring(value))))
    end
    return table.concat(parts, "&")
end

local function normalizeStory(entry)
    if type(entry) ~= "table" then
        return {}
    end
    local story = {}

    local story_id = entry.story_id or entry.id or entry.story_hash
    if story_id ~= nil then
        story_id = tostring(story_id)
        story.id = story_id
        story.story_id = story_id
    end

    if entry.story_hash ~= nil then
        story.story_hash = entry.story_hash
        story.hash = entry.story_hash
    elseif entry.hash ~= nil then
        story.hash = entry.hash
    end

    local feed_id = entry.story_feed_id or entry.feed_id
    if feed_id ~= nil then
        feed_id = tostring(feed_id)
        story.story_feed_id = feed_id
        story.feed_id = feed_id
    end

    local title = entry.story_title or entry.title or entry.story_permalink or entry.story_hash or entry.id
    story.story_title = title
    story.title = title

    local permalink = entry.story_permalink or entry.permalink or entry.link or entry.url
    story.story_permalink = permalink
    story.permalink = permalink

    local content = entry.story_content or entry.content or entry.summary
    story.story_content = content
    story.content = content

    if entry.read_status ~= nil then
        story.read_status = entry.read_status
    end
    if entry.read ~= nil then
        story.read = entry.read
    end
    if entry.story_read ~= nil then
        story.story_read = entry.story_read
    end
    if entry.starred ~= nil then
        story.starred = entry.starred and true or false
    end

    story.author = entry.story_authors or entry.authors or entry.author

    local timestamp = entry.story_timestamp or entry.timestamp or entry.created_on_time or entry.created_on
    if type(timestamp) == "string" then
        local numeric = tonumber(timestamp)
        if numeric then
            timestamp = numeric
        else
            timestamp = nil
        end
    end
    if type(timestamp) == "number" then
        if timestamp < 1000000000000 then
            timestamp = math.floor(timestamp * 1000)
        end
        story.timestamp = timestamp
        story.created_on_time = timestamp
    end

    if story.created_on_time == nil then
        local created_on = entry.created_on_time or entry.created_on
        if type(created_on) == "string" then
            local numeric = tonumber(created_on)
            if numeric then
                created_on = numeric
            else
                created_on = nil
            end
        end
        if type(created_on) == "number" then
            if created_on < 1000000000000 then
                created_on = math.floor(created_on * 1000)
            end
            story.created_on_time = created_on
        end
    end

    local date_label = entry.story_date or entry.published or entry.pubdate or entry.date
    if date_label ~= nil and date_label ~= "" then
        story.date = date_label
    end

    return story
end

function NewsBlur:new(account)
    local instance = {
        account = account or {},
        cookie = nil,
        last_login = nil,
        subscriptions_cache = nil,
        tree_cache = nil,
        csrf_token = nil,
    }
    setmetatable(instance, self)
    return instance
end

function NewsBlur:getCredentials()
    local auth = self.account and self.account.auth
    if not auth then
        return nil, nil
    end
    return auth.username, auth.password
end

function NewsBlur:login()
    if self.cookie and self.last_login and (os.time() - self.last_login) < 1800 then
        return true
    end

    local username, password = self:getCredentials()
    if not username or username == "" or not password or password == "" then
        return false, "Missing NewsBlur credentials."
    end

    local payload = string.format("username=%s&password=%s",
        url.escape(username),
        url.escape(password))

    local response_chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, headers, status = requestWithScheme({
        url = self.BASE_URL .. self.LOGIN_ENDPOINT,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#payload),
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = self.USER_AGENT,
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Referer"] = self.BASE_URL .. "/",
            ["Origin"] = self.BASE_URL,
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    if tonumber(code) ~= 200 then
        local message = string.format("NewsBlur login failed (HTTP %s - %s)", tostring(code), tostring(status))
        return false, message
    end

    local body = table.concat(response_chunks)
    local decoded = safe_json_decode(body)
    if not decoded then
        return false, "Unable to parse NewsBlur login response."
    end

    if not decoded.authenticated then
        return false, decoded.message or "Invalid NewsBlur credentials."
    end

    local raw_cookies = {}
    local headers_cookie = headers and (headers["set-cookie"] or headers["Set-Cookie"])
    if headers_cookie then
        if type(headers_cookie) ~= "table" then
            headers_cookie = { headers_cookie }
        end
        for _, cookie_entry in ipairs(headers_cookie) do
            if type(cookie_entry) == "string" then
                local value = cookie_entry:match("([^;]+)")
                if value then
                    table.insert(raw_cookies, value)
                    local csrf = value:match("csrftoken=([^;]+)")
                    if csrf then
                        self.csrf_token = csrf
                    end
                end
            end
        end
    end

    if #raw_cookies == 0 then
        return false, "NewsBlur login did not return a session cookie."
    end

    self.cookie = table.concat(raw_cookies, "; ")
    self.last_login = os.time()
    return true
end

function NewsBlur:authorizedRequest(options)
    local ok, err = self:login()
    if not ok then
        return false, err
    end

    local response_chunks = {}
    local headers = options.headers or {}
    headers["Cookie"] = self.cookie
    headers["Accept-Encoding"] = headers["Accept-Encoding"] or "identity"
    headers["User-Agent"] = headers["User-Agent"] or self.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/javascript, */*; q=0.01"
    headers["X-Requested-With"] = headers["X-Requested-With"] or "XMLHttpRequest"
    headers["Referer"] = headers["Referer"] or self.BASE_URL .. "/"
    headers["Origin"] = headers["Origin"] or self.BASE_URL
    if self.csrf_token then
        headers["X-CSRFToken"] = headers["X-CSRFToken"] or self.csrf_token
    end
    local body = options.body
    if body then
        headers["Content-Type"] = headers["Content-Type"] or "application/x-www-form-urlencoded; charset=utf-8"
        headers["Content-Length"] = tostring(#body)
    end
    options.headers = headers
    options.sink = ltn12.sink.table(response_chunks)
    options.method = options.method or (body and "POST" or "GET")
    if body then
        options.source = ltn12.source.string(body)
        options.body = nil
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, response_headers, status = requestWithScheme(options)
    socketutil:reset_timeout()

    if tonumber(code) == 302 and response_headers and response_headers.location then
        if options.follow_redirects ~= false then
            local redirect_options = {}
            for key, value in pairs(options) do
                redirect_options[key] = value
            end
            redirect_options.url = url.absolute(options.url, response_headers.location)
            redirect_options.follow_redirects = false
            return self:authorizedRequest(redirect_options)
        end
    end

    if tonumber(code) ~= 200 then
        local message = string.format("NewsBlur request failed (HTTP %s - %s)", tostring(code), tostring(status))
        return false, message
    end

    local text = table.concat(response_chunks)
    local decoded = safe_json_decode(text)
    if not decoded then
        local snippet = text and text:sub(1, 160) or ""
        logger.warn("NewsBlur response parse error", text or "no data")
        return false, string.format("Unable to parse NewsBlur response. First bytes: %s", snippet)
    end
    return true, decoded
end

function NewsBlur:fetchSubscriptions(force)
    if self.subscriptions_cache and not force then
        return true, self.subscriptions_cache
    end
    local ok, data_or_err = self:authorizedRequest({
        url = self.BASE_URL .. self.SUBSCRIPTION_ENDPOINT,
        method = "POST",
        body = encodeForm({
            flat = "false",
            include_favicons = "false",
        }),
    })
    if not ok then
        return false, data_or_err
    end
    self.subscriptions_cache = data_or_err
    self.tree_cache = nil
    return true, data_or_err
end

local function buildFeedNode(feed_id, feed_data)
    return {
        kind = "feed",
        id = feed_id,
        title = feed_data.feed_title or feed_data.title or feed_data.id or feed_id,
        feed = feed_data,
    }
end

function NewsBlur:parseFolderList(folder_list, feeds)
    local nodes = {}
    if type(folder_list) ~= "table" then
        return nodes
    end
    for _, entry in ipairs(folder_list) do
        local entry_type = type(entry)
        if entry_type == "string" or entry_type == "number" then
            local feed_key = normalizeFeedKey(entry)
            local feed_data = feeds[feed_key]
            if feed_data then
                table.insert(nodes, buildFeedNode(feed_key, feed_data))
            end
        elseif entry_type == "table" then
            for folder_name, children in pairs(entry) do
                table.insert(nodes, {
                    kind = "folder",
                    title = folder_name,
                    children = self:parseFolderList(children, feeds),
                })
            end
        end
    end
    return nodes
end

function NewsBlur:buildTree(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    local ok, data_or_err = self:fetchSubscriptions(force)
    if not ok then
        return false, data_or_err
    end

    local feeds = data_or_err.feeds or {}
    local folders = data_or_err.folders or {}

    local children = self:parseFolderList(folders, feeds)

    -- Include feeds that may not appear in any folder
    local present = {}
    local function markNodes(list)
        for _, node in ipairs(list) do
            if node.kind == "feed" then
                present[node.id] = true
            elseif node.kind == "folder" then
                markNodes(node.children)
            end
        end
    end
    markNodes(children)
    for feed_id, feed_data in pairs(feeds) do
        if not present[feed_id] then
            table.insert(children, buildFeedNode(feed_id, feed_data))
        end
    end

    self.tree_cache = {
        kind = "root",
        title = self.account and self.account.name or "NewsBlur",
        children = children,
        feeds = feeds,
    }
    return true, self.tree_cache
end

function NewsBlur:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier."
    end
    local params = {
        include_story_content = 1,
        order = "newest",
    }
    params.read_filter = (options and options.read_filter) or "all"
    local page = options and options.page
    if page then
        params.page = page
    end
    local request_url = string.format("%s%s/%s", self.BASE_URL, self.STORIES_ENDPOINT, tostring(feed_id))
    if page then
        request_url = string.format("%s?page=%s", request_url, url.escape(tostring(page)))
        params.page = nil
    end
    local ok, data_or_err = self:authorizedRequest({
        url = request_url,
        method = "POST",
        body = encodeForm(params),
    })
    if not ok then
        return false, data_or_err
    end

    local result = {
        stories = {},
        more_stories = data_or_err.more_stories or data_or_err.has_more or data_or_err.stories_remaining,
    }

    if type(data_or_err.stories) == "table" then
        for _, entry in ipairs(data_or_err.stories) do
            table.insert(result.stories, normalizeStory(entry))
        end
    end

    return true, result
end

local function buildStoryStateParams(feed_id, story)
    if type(story) ~= "table" then
        return nil
    end
    local params = {}
    if story.story_id or story.id then
        params.story_id = story.story_id or story.id
    end
    params.story_feed_id = story.story_feed_id or feed_id
    params.feed_id = feed_id
    if story.story_hash or story.hash then
        params.story_hash = story.story_hash or story.hash
    end
    if params.story_hash or params.story_id then
        return params
    end
    return nil
end

function NewsBlur:markStoryAsRead(feed_id, story)
    local params = buildStoryStateParams(feed_id, story)
    if not params then
        return false, "Missing story identifiers"
    end
    return self:authorizedRequest({
        url = self.BASE_URL .. self.MARK_READ_ENDPOINT,
        method = "POST",
        body = encodeForm(params),
    })
end

function NewsBlur:markStoryAsUnread(feed_id, story)
    local params = buildStoryStateParams(feed_id, story)
    if not params then
        return false, "Missing story identifiers"
    end
    return self:authorizedRequest({
        url = self.BASE_URL .. self.MARK_UNREAD_ENDPOINT,
        method = "POST",
        body = encodeForm(params),
    })
end

function NewsBlur:markFeedAsRead(feed_id)
    if not feed_id then
        return false, "Missing feed identifier."
    end
    return self:authorizedRequest({
        url = self.BASE_URL .. "/reader/mark_feed_as_read",
        method = "POST",
        body = encodeForm({
            feed_id = feed_id,
        }),
    })
end

function NewsBlur:markFolderAsRead(folder_name)
    if not folder_name then
        return false, "Missing folder name."
    end
    return self:authorizedRequest({
        url = self.BASE_URL .. "/reader/mark_folder_as_read",
        method = "POST",
        body = encodeForm({
            folder_name = folder_name,
        }),
    })
end

return NewsBlur
