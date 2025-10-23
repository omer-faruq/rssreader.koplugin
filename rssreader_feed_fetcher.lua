local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local json = require("json.decode")

local FeedFetcher = {}

local USER_AGENT = "KOReader RSSReader"
local DEFAULT_TIMEOUT = 10
local DEFAULT_TOTAL_TIMEOUT = 30

local function httpGet(url)
    local sink = {}
    socketutil:set_timeout(DEFAULT_TIMEOUT, DEFAULT_TOTAL_TIMEOUT)
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = USER_AGENT,
        },
        sink = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if not code or string.sub(code, 1, 1) ~= "2" then
        return nil, status or tostring(code)
    end
    return table.concat(sink)
end

local function stripCData(value)
    if not value then
        return nil
    end
    local stripped = value:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    return stripped
end

local function sanitize(value)
    if not value then
        return nil
    end
    value = stripCData(value)
    return util.htmlEntitiesToUtf8(value)
end

local function parseRSS(content)
    local items = {}
    for raw in content:gmatch("<item[%s>](.-)</item>") do
        local title = sanitize(raw:match("<title[^>]*>(.-)</title>"))
        local link = stripCData(raw:match("<link[^>]*>(.-)</link>"))
        local description = raw:match("<description[^>]*>(.-)</description>")
        local contentEncoded = raw:match("<content:encoded[^>]*>(.-)</content:encoded>")
        local body = contentEncoded or description
        local pub_date = stripCData(raw:match("<pubDate[^>]*>(.-)</pubDate>"))
            or stripCData(raw:match("<dc:date[^>]*>(.-)</dc:date>"))
            or stripCData(raw:match("<published[^>]*>(.-)</published>"))
            or stripCData(raw:match("<updated[^>]*>(.-)</updated>"))
        if pub_date then
            pub_date = util.trim(pub_date)
        end
        if title or link or body then
            table.insert(items, {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = stripCData(body),
                date = pub_date,
            })
        end
    end
    return items
end

local function parseAtom(content)
    local items = {}
    for raw in content:gmatch("<entry[%s>](.-)</entry>") do
        local title = sanitize(raw:match("<title[^>]*>(.-)</title>"))
        local link = raw:match("<link[^>]+href%=(['\"])(.-)%1")
        local contentHtml = raw:match("<content[^>]*>(.-)</content>")
        local summary = raw:match("<summary[^>]*>(.-)</summary>")
        local body = contentHtml or summary
        local pub_date = stripCData(raw:match("<updated[^>]*>(.-)</updated>"))
            or stripCData(raw:match("<published[^>]*>(.-)</published>"))
        if pub_date then
            pub_date = util.trim(pub_date)
        end
        if title or link or body then
            table.insert(items, {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = stripCData(body),
                date = pub_date,
            })
        end
    end
    return items
end

local function parseJSON(content)
    local items = {}
    local status, feed = pcall(json.decode, content)
    if not status or not feed or not feed.items then
        return items
    end
    for _, item in ipairs(feed.items) do
        local title = sanitize(item.title)
        local link = item.url or item.external_url
        local body = item.content_html or item.content_text or item.summary
        local pub_date = item.date_published or item.published or item.dateModified or item.date_modified or item.updated
        if type(pub_date) == "string" then
            pub_date = util.trim(pub_date)
        end
        if title or link or body then
            table.insert(items, {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = stripCData(body),
                date = pub_date,
            })
        end
    end
    return items
end

local function detectFormat(content)
    if content:find("<item") then
        return "rss"
    elseif content:find("<entry") then
        return "atom"
    else
        -- Try JSON Feed
        local status, feed = pcall(json.decode, content)
        if status and feed and feed.version and feed.items then
            return "json"
        end
    end
    return "unknown"
end

function FeedFetcher.fetch(url)
    local body, err = httpGet(url)
    if not body then
        return false, err or "Unable to download feed"
    end

    local format = detectFormat(body)
    local items
    if format == "rss" then
        items = parseRSS(body)
    elseif format == "atom" then
        items = parseAtom(body)
    elseif format == "json" then
        items = parseJSON(body)
    else
        return false, "Unsupported feed format"
    end

    return true, items
end

return FeedFetcher
