local DataStorage = require("datastorage")
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local rapidjson = require("rapidjson")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

-- Feedbin REST API v2: https://github.com/feedbin/feedbin-api
-- Entries carry no read or starred flag; those come from the separate
-- unread_entries / starred_entries ID lists.
local Feedbin = {}
Feedbin.__index = Feedbin

local USER_AGENT = "KOReader RSSReader"
local DEFAULT_BASE_URL = "https://api.feedbin.com"

local STORIES_PER_PAGE = 50
-- Unread counts have no endpoint of their own, and an entry's feed only
-- comes with the whole entry, article included. So which feed each unread
-- entry belongs to is cached on disk, and each tree load looks up at most
-- one page of entries it has not seen yet.
local COUNT_PAGE_SIZE = 100
-- Most IDs unread_entries / starred_entries take per call.
local MARK_BATCH_SIZE = 1000

Feedbin.ALL_FEEDS_ID = "__feedbin_all_feeds__"
Feedbin.ALL_UNREAD_ID = "__feedbin_all_unread__"
Feedbin.STARRED_ID = "__feedbin_starred__"

local function requestWithScheme(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "http"
    if scheme == "https" then
        return https.request(options)
    end
    return http.request(options)
end

-- Replies are decoded with rapidjson, not the json module (LuaJSON): on
-- input that is not JSON at all, such as a captive portal's HTML page,
-- LuaJSON can abort the whole process even under pcall, while rapidjson
-- returns nil and an error. It is also several times faster. Request bodies
-- are still encoded with json.
local function safe_json_decode(payload)
    if not payload or payload == "" then
        return {}
    end
    local ok, decoded = pcall(rapidjson.decode, payload)
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

-- JSON null may decode to a sentinel rather than nil, so only accept strings.
local function stringOrNil(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- Feedbin timestamps are UTC ("2013-02-02T14:07:33.000000Z"). os.time reads
-- a table as local time and gets daylight saving wrong when shifted back, so
-- count the days since the epoch directly (Howard Hinnant's days_from_civil).
local function parseUtcTimestamp(timestamp)
    if type(timestamp) ~= "string" then
        return nil
    end
    local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return nil
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if month <= 2 then
        year = year - 1
    end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local day_of_year = math.floor((153 * (month > 2 and month - 3 or month + 9) + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return days * 86400 + tonumber(hour) * 3600 + tonumber(min) * 60 + tonumber(sec)
end

local function idSet(ids)
    local set = {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            set[tostring(id)] = true
        end
    end
    return set
end

local function normalizeEntry(entry, unread_set, starred_set, feed_titles)
    if type(entry) ~= "table" then
        return {}
    end

    local story = {}

    if entry.id ~= nil then
        local id_str = tostring(entry.id)
        story.id = id_str
        story.story_id = id_str
    end

    if entry.feed_id ~= nil then
        local feed_id_str = tostring(entry.feed_id)
        story.feed_id = feed_id_str
        story.story_feed_id = feed_id_str
        if feed_titles and feed_titles[feed_id_str] then
            story.feed_title = feed_titles[feed_id_str]
        end
    end

    local title = stringOrNil(entry.title) or ""
    story.title = title
    story.story_title = title

    local permalink = stringOrNil(entry.url)
    story.permalink = permalink
    story.story_permalink = permalink
    -- Pre-signed full-article extraction, used by the "feedbin" sanitizer.
    story.extracted_content_url = stringOrNil(entry.extracted_content_url)

    local content = stringOrNil(entry.content) or stringOrNil(entry.summary) or ""
    story.content = content
    story.story_content = content

    local unix_time = parseUtcTimestamp(entry.published) or parseUtcTimestamp(entry.created_at)
    if unix_time then
        story.timestamp = unix_time * 1000
        story.created_on_time = unix_time * 1000
    end

    local read_flag = not (story.id and unread_set and unread_set[story.id])
    story.read = read_flag
    story.read_status = read_flag
    story.story_read = read_flag

    story.starred = (story.id and starred_set and starred_set[story.id]) and true or false

    local author = stringOrNil(entry.author)
    if author then
        story.author = author
    end

    return story
end

function Feedbin:new(account)
    local instance = {
        account = account or {},
        tree_cache = nil,
        subscriptions_cache = nil,
        feed_titles = {},
        entry_feeds = nil,
    }
    setmetatable(instance, self)
    return instance
end

function Feedbin:getCredentials()
    local auth = self.account and self.account.auth
    if type(auth) ~= "table" then
        return nil, nil, nil
    end

    local username = auth.username or auth.email or auth.user
    if type(username) ~= "string" or username == "" then
        username = nil
    end

    local password = auth.password
    if type(password) ~= "string" or password == "" then
        password = nil
    end

    local base_url = sanitizeBaseUrl(auth.base_url or auth.baseurl or auth.url) or DEFAULT_BASE_URL

    return username, password, base_url
end

-- Returns ok, decoded_body_or_error, http_code.
function Feedbin:performRequest(method, path, body_table)
    local username, password, base_url = self:getCredentials()

    if not username or not password then
        return false, "Missing Feedbin email or password"
    end

    local target_url = joinUrl(base_url, path)
    if not target_url then
        return false, "Unable to build Feedbin request URL"
    end

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
        ["Authorization"] = "Basic " .. mime.b64(username .. ":" .. password),
    }

    local body
    if body_table ~= nil then
        local ok, encoded = pcall(json.encode, body_table)
        if not ok then
            return false, string.format("Failed to encode request body: %s", encoded)
        end
        body = encoded
        headers["Content-Type"] = "application/json; charset=utf-8"
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
    if numeric_code == 401 then
        return false, "Feedbin login failed: check the email and password", numeric_code
    end
    if not numeric_code or numeric_code < 200 or numeric_code >= 300 then
        return false, string.format("Feedbin request failed (HTTP %s - %s)", tostring(code), tostring(status)), numeric_code
    end

    local text = table.concat(response_chunks)
    if text == "" or text == "null" then
        return true, {}, numeric_code
    end

    local decoded = safe_json_decode(text)
    if type(decoded) ~= "table" then
        logger.warn("Feedbin response parse error", text or "no data")
        return false, "Unable to parse Feedbin response", numeric_code
    end

    return true, decoded, numeric_code
end

-- Fetches one page of entries. Feedbin answers 404 for a page past the end
-- (and so possibly for an empty list), which is treated as an empty page.
function Feedbin:fetchEntriesPage(path, params, page, per_page)
    local query_parts = {
        "page=" .. tostring(page),
        "per_page=" .. tostring(per_page),
    }
    for _, param in ipairs(params or {}) do
        table.insert(query_parts, param)
    end
    local ok, data, code = self:performRequest("GET", path .. "?" .. table.concat(query_parts, "&"))
    if not ok then
        if code == 404 then
            return true, {}
        end
        return false, data
    end
    return true, data
end

function Feedbin:fetchUnreadIds()
    local ok, data = self:performRequest("GET", "/v2/unread_entries.json")
    if not ok then
        return false, data
    end
    return true, data
end

function Feedbin:fetchStarredIds()
    local ok, data = self:performRequest("GET", "/v2/starred_entries.json")
    if not ok then
        return false, data
    end
    return true, data
end

function Feedbin:fetchSubscriptions(force)
    if self.subscriptions_cache and not force then
        return true, self.subscriptions_cache
    end

    local ok, data = self:performRequest("GET", "/v2/subscriptions.json")
    if not ok then
        return false, data
    end

    self.subscriptions_cache = data
    self.feed_titles = {}
    for _, subscription in ipairs(data) do
        if subscription.feed_id ~= nil then
            self.feed_titles[tostring(subscription.feed_id)] = stringOrNil(subscription.title) or "Feed"
        end
    end
    return true, data
end

function Feedbin:entryFeedsPath()
    local name = tostring(self.account and self.account.name or "default"):gsub("[^%w%-_]", "_")
    return DataStorage:getDataDir() .. "/data/rssreader_feedbin_" .. name .. ".json"
end

-- entry_feeds maps an entry ID string to its feed ID string, or to false for
-- an entry Feedbin no longer returns, so it is not looked up again.
function Feedbin:loadEntryFeeds()
    if self.entry_feeds then
        return self.entry_feeds
    end
    self.entry_feeds = {}
    local file = io.open(self:entryFeedsPath(), "r")
    if file then
        local content = file:read("*all")
        file:close()
        local data = safe_json_decode(content)
        if type(data) == "table" then
            for entry_id, feed_id in pairs(data) do
                self.entry_feeds[tostring(entry_id)] = feed_id ~= 0 and tostring(feed_id) or false
            end
        end
    end
    return self.entry_feeds
end

function Feedbin:saveEntryFeeds()
    if not self.entry_feeds then
        return
    end
    -- Saved as 0 rather than false, which some JSON encoders drop.
    local data = {}
    for entry_id, feed_id in pairs(self.entry_feeds) do
        data[entry_id] = feed_id or 0
    end
    local ok, encoded = pcall(json.encode, data)
    if not ok then
        return
    end
    util.makePath(DataStorage:getDataDir() .. "/data")
    local file = io.open(self:entryFeedsPath(), "w")
    if file then
        file:write(encoded)
        file:close()
    end
end

-- Remembers the feed of entries fetched anyway, so browsing fills the cache.
function Feedbin:rememberEntryFeeds(entries)
    local entry_feeds = self:loadEntryFeeds()
    local added = false
    for _, entry in ipairs(entries) do
        if entry.id ~= nil and entry.feed_id ~= nil then
            local key = tostring(entry.id)
            if entry_feeds[key] == nil then
                entry_feeds[key] = tostring(entry.feed_id)
                added = true
            end
        end
    end
    if added then
        self:saveEntryFeeds()
    end
end

-- Counts unread entries per feed from the cached entry -> feed map, after
-- looking up the newest COUNT_PAGE_SIZE unread entries missing from it.
-- Returns the counts and whether entries were left uncounted.
function Feedbin:countUnreadByFeed()
    local ok, unread_ids = self:fetchUnreadIds()
    if not ok then
        return false, unread_ids
    end

    local entry_feeds = self:loadEntryFeeds()
    -- Entries that are no longer unread drop out of the cache.
    local unread_set = idSet(unread_ids)
    for entry_id in pairs(entry_feeds) do
        if not unread_set[entry_id] then
            entry_feeds[entry_id] = nil
        end
    end

    local unknown = {}
    for _, id in ipairs(unread_ids) do
        if entry_feeds[tostring(id)] == nil then
            table.insert(unknown, id)
        end
    end
    -- Higher IDs are newer; look those up first.
    table.sort(unknown, function(a, b) return a > b end)

    if #unknown > 0 then
        local batch = {}
        for i = 1, math.min(COUNT_PAGE_SIZE, #unknown) do
            batch[i] = tostring(unknown[i])
        end
        local ok_entries, entries = self:performRequest("GET", "/v2/entries.json?ids=" .. table.concat(batch, ","))
        if not ok_entries then
            return false, entries
        end
        for _, entry in ipairs(entries) do
            if entry.id ~= nil and entry.feed_id ~= nil then
                entry_feeds[tostring(entry.id)] = tostring(entry.feed_id)
            end
        end
        for _, id_str in ipairs(batch) do
            if entry_feeds[id_str] == nil then
                entry_feeds[id_str] = false
            end
        end
    end
    self:saveEntryFeeds()

    local counts = {}
    for _, id in ipairs(unread_ids) do
        local feed_id = entry_feeds[tostring(id)]
        if feed_id then
            counts[feed_id] = (counts[feed_id] or 0) + 1
        end
    end
    return true, counts, #unknown > COUNT_PAGE_SIZE
end

function Feedbin:buildTree(force)
    if self.tree_cache and not force then
        return true, self.tree_cache
    end

    local ok_subs, subscriptions = self:fetchSubscriptions(true)
    if not ok_subs then
        return false, subscriptions
    end

    local ok_tags, taggings = self:performRequest("GET", "/v2/taggings.json")
    if not ok_tags then
        return false, taggings
    end

    -- A failed count only costs the numbers, not the tree.
    local ok_counts, counts, counts_partial = self:countUnreadByFeed()
    if not ok_counts then
        logger.warn("Feedbin unread count failed", counts)
        counts = {}
        counts_partial = false
    end

    local function makeFeedNode(subscription)
        local feed_id = tostring(subscription.feed_id)
        return {
            kind = "feed",
            id = feed_id,
            title = self.feed_titles[feed_id] or "Feed",
            feed = {
                unreadCount = counts[feed_id] or 0,
                unreadCountPartial = counts_partial,
            },
        }
    end

    local subscription_by_feed = {}
    for _, subscription in ipairs(subscriptions) do
        if subscription.feed_id ~= nil then
            subscription_by_feed[tostring(subscription.feed_id)] = subscription
        end
    end

    -- A feed can carry several tags and then shows up in each folder.
    local folder_map = {}
    local tagged = {}
    for _, tagging in ipairs(taggings) do
        local name = stringOrNil(tagging.name)
        local feed_key = tagging.feed_id ~= nil and tostring(tagging.feed_id)
        local subscription = feed_key and subscription_by_feed[feed_key]
        if name and subscription then
            local folder = folder_map[name]
            if not folder then
                folder = {
                    kind = "folder",
                    id = name,
                    title = name,
                    children = {},
                }
                folder_map[name] = folder
            end
            table.insert(folder.children, makeFeedNode(subscription))
            tagged[feed_key] = true
        end
    end

    local function byTitle(a, b)
        return (a.title or "") < (b.title or "")
    end

    local root_children = {}
    for _, folder in pairs(folder_map) do
        table.sort(folder.children, byTitle)
        table.insert(root_children, folder)
    end
    for _, subscription in ipairs(subscriptions) do
        if subscription.feed_id ~= nil and not tagged[tostring(subscription.feed_id)] then
            table.insert(root_children, makeFeedNode(subscription))
        end
    end

    table.sort(root_children, function(a, b)
        if a.kind == "folder" and b.kind == "feed" then
            return true
        elseif a.kind == "feed" and b.kind == "folder" then
            return false
        end
        return byTitle(a, b)
    end)

    -- Feedbin's entries endpoint cannot filter by tag, so the aggregated
    -- views only exist at the root.
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.STARRED_ID,
        title = "★ Starred",
        _virtual = true,
    })
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.ALL_UNREAD_ID,
        title = "★ All Unread",
        _virtual = true,
        _read_filter = "unread",
    })
    table.insert(root_children, 1, {
        kind = "feed",
        id = Feedbin.ALL_FEEDS_ID,
        title = "★ All Feeds",
        _virtual = true,
        _read_filter = "all",
    })

    self.tree_cache = {
        kind = "root",
        title = (self.account and self.account.name) or "Feedbin",
        children = root_children,
    }

    return true, self.tree_cache
end

function Feedbin:fetchStories(feed_id, options)
    if not feed_id then
        return false, "Missing feed identifier"
    end

    options = options or {}
    local page = options.page or 1
    if page < 1 then
        page = 1
    end

    local is_virtual = feed_id == Feedbin.ALL_FEEDS_ID
        or feed_id == Feedbin.ALL_UNREAD_ID
        or feed_id == Feedbin.STARRED_ID

    local path
    local params = {}
    if feed_id == Feedbin.ALL_FEEDS_ID then
        path = "/v2/entries.json"
    elseif feed_id == Feedbin.ALL_UNREAD_ID then
        path = "/v2/entries.json"
        table.insert(params, "read=false")
    elseif feed_id == Feedbin.STARRED_ID then
        path = "/v2/entries.json"
        table.insert(params, "starred=true")
    else
        path = "/v2/feeds/" .. url.escape(tostring(feed_id)) .. "/entries.json"
    end

    -- Story titles in virtual feeds are prefixed with the feed title.
    if is_virtual then
        local ok_subs, err = self:fetchSubscriptions()
        if not ok_subs then
            return false, err
        end
    end

    local ok_unread, unread_ids = self:fetchUnreadIds()
    if not ok_unread then
        return false, unread_ids
    end
    local ok_starred, starred_ids = self:fetchStarredIds()
    if not ok_starred then
        return false, starred_ids
    end
    local unread_set = idSet(unread_ids)
    local starred_set = idSet(starred_ids)

    local ok, entries = self:fetchEntriesPage(path, params, page, STORIES_PER_PAGE)
    if not ok then
        return false, entries
    end
    self:rememberEntryFeeds(entries)

    local stories = {}
    for _, entry in ipairs(entries) do
        local story = normalizeEntry(entry, unread_set, starred_set, self.feed_titles)
        if is_virtual then
            story._from_virtual_feed = true
        end
        table.insert(stories, story)
    end

    return true, {
        stories = stories,
        more_stories = #entries >= STORIES_PER_PAGE,
    }
end

local function storyIdNumber(story)
    local story_id = story and (story.id or story.story_id)
    return story_id and tonumber(story_id)
end

-- Sends ids to an unread_entries / starred_entries endpoint in batches.
-- Uses the POST .../delete.json forms rather than DELETE with a body.
function Feedbin:sendIdBatches(path, key, ids)
    for start = 1, #ids, MARK_BATCH_SIZE do
        local batch = {}
        for i = start, math.min(start + MARK_BATCH_SIZE - 1, #ids) do
            table.insert(batch, tonumber(ids[i]) or ids[i])
        end
        local ok, err = self:performRequest("POST", path, { [key] = batch })
        if not ok then
            return false, err
        end
    end
    return true
end

function Feedbin:markIdsAsRead(ids)
    return self:sendIdBatches("/v2/unread_entries/delete.json", "unread_entries", ids)
end

function Feedbin:markStoryAsRead(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:markIdsAsRead({ id })
end

function Feedbin:markStoryAsUnread(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/unread_entries.json", "unread_entries", { id })
end

function Feedbin:markStoryAsStarred(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/starred_entries.json", "starred_entries", { id })
end

function Feedbin:markStoryAsUnstarred(feed_id, story)
    local id = storyIdNumber(story)
    if not id then
        return false, "Missing story ID"
    end
    return self:sendIdBatches("/v2/starred_entries/delete.json", "starred_entries", { id })
end

-- Collects a feed's unread entry IDs page by page.
function Feedbin:collectUnreadIdsForFeed(feed_id, into)
    local path = "/v2/feeds/" .. url.escape(tostring(feed_id)) .. "/entries.json"
    local page = 1
    while true do
        local ok, entries = self:fetchEntriesPage(path, { "read=false" }, page, COUNT_PAGE_SIZE)
        if not ok then
            return false, entries
        end
        for _, entry in ipairs(entries) do
            if entry.id ~= nil then
                table.insert(into, entry.id)
            end
        end
        if #entries < COUNT_PAGE_SIZE then
            return true, into
        end
        page = page + 1
    end
end

function Feedbin:markFeedAsRead(feed_id)
    if not feed_id then
        return false, "Missing feed identifier"
    end
    local ok, ids = self:collectUnreadIdsForFeed(feed_id, {})
    if not ok then
        return false, ids
    end
    return self:markIdsAsRead(ids)
end

-- category_id is the tag name, which is the folder's id in the tree.
function Feedbin:markCategoryAsRead(category_id)
    if not category_id then
        return false, "Missing category identifier"
    end
    local ok_tree, tree = self:buildTree()
    if not ok_tree then
        return false, tree
    end
    local folder
    for _, child in ipairs(tree.children or {}) do
        if child.kind == "folder" and child.id == category_id then
            folder = child
            break
        end
    end
    if not folder then
        return false, "Folder not found"
    end
    local ids = {}
    for _, child in ipairs(folder.children or {}) do
        if child.kind == "feed" and not child._virtual then
            local ok, err = self:collectUnreadIdsForFeed(child.id, ids)
            if not ok then
                return false, err
            end
        end
    end
    return self:markIdsAsRead(ids)
end

function Feedbin:markAllAsRead()
    local ok, ids = self:fetchUnreadIds()
    if not ok then
        return false, ids
    end
    return self:markIdsAsRead(ids)
end

function Feedbin:markStarredAsRead()
    local ok_unread, unread_ids = self:fetchUnreadIds()
    if not ok_unread then
        return false, unread_ids
    end
    local ok_starred, starred_ids = self:fetchStarredIds()
    if not ok_starred then
        return false, starred_ids
    end
    local unread_set = idSet(unread_ids)
    local ids = {}
    for _, id in ipairs(starred_ids) do
        if unread_set[tostring(id)] then
            table.insert(ids, id)
        end
    end
    return self:markIdsAsRead(ids)
end

return Feedbin
