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
    if type(value) ~= "string" then
        return nil
    end
    value = util.trim(value)
    if value == "" then
        return nil
    end
    value = util.htmlEntitiesToUtf8(value)
    if type(value) == "string" then
        value = util.trim(value)
        if value == "" then
            return nil
        end
    end
    return value
end

local function sanitizeImageUrl(url_value)
    if not url_value then
        return nil
    end
    if type(url_value) == "table" then
        url_value = url_value.url or url_value.href or url_value.src
    end
    if type(url_value) ~= "string" then
        return nil
    end
    url_value = stripCData(url_value)
    if not url_value then
        return nil
    end
    url_value = util.htmlEntitiesToUtf8(url_value)
    url_value = util.trim(url_value or "")
    if url_value == "" then
        return nil
    end
    if url_value:find("^data:") then
        return nil
    end
    return url_value
end

local function insertImageCandidate(result, image_url)
    local sanitized = sanitizeImageUrl(image_url)
    if not sanitized then
        return
    end
    result.story_image = result.story_image or sanitized
    result.image = result.image or sanitized
    if not result.image_urls then
        result.image_urls = { sanitized }
    else
        for _, existing in ipairs(result.image_urls) do
            if existing == sanitized then
                return
            end
        end
        table.insert(result.image_urls, sanitized)
    end
end

local function decodeAtomBody(body, attrs)
    if not body then
        return nil
    end
    body = stripCData(body)
    if not body or body == "" then
        return nil
    end

    local type_attr
    if attrs then
        type_attr = attrs:match('[Tt][Yy][Pp][Ee]%s*=%s*["\'](.-)["\']')
        if type_attr then
            type_attr = type_attr:lower()
        end
    end

    if not type_attr or type_attr == "text" then
        local escaped = util.htmlEscape(util.htmlEntitiesToUtf8(body))
        return string.format("<p>%s</p>", escaped)
    elseif type_attr == "html" then
        return util.htmlEntitiesToUtf8(body)
    elseif type_attr == "xhtml" then
        return body
    else
        return util.htmlEntitiesToUtf8(body)
    end
end

local function extractAtomLink(raw)
    local fallback
    for attrs in raw:gmatch("<link%s+([^>]-)/?>") do
        local href = attrs:match('href%s*=%s*["\'](.-)["\']')
        if href and href ~= "" then
            href = util.htmlEntitiesToUtf8(stripCData(href))
            local rel = attrs:match('rel%s*=%s*["\'](.-)["\']')
            local type_attr = attrs:match('type%s*=%s*["\'](.-)["\']')
            local rel_lower = rel and rel:lower() or nil
            local type_lower = type_attr and type_attr:lower() or nil

            if not rel_lower or rel_lower == "alternate" then
                if not type_lower or type_lower == "text/html" or type_lower == "html" then
                    return href
                end
                if not fallback then
                    fallback = href
                end
            elseif not fallback then
                fallback = href
            end
        end
    end
    return fallback
end

local function parseRSS(content)
    local items = {}
    for raw in content:gmatch("<item[%s>](.-)</item>") do
        local title = sanitize(raw:match("<title[^>]*>(.-)</title>"))
        local link = stripCData(raw:match("<link[^>]*>(.-)</link>"))
        local description = raw:match("<description[^>]*>(.-)</description>")
        local contentEncoded = raw:match("<content:encoded[^>]*>(.-)</content:encoded>")
        local body = contentEncoded or description
        body = stripCData(body)
        if body and body ~= "" then
            body = util.htmlEntitiesToUtf8(body)
        end
        local pub_date = stripCData(raw:match("<pubDate[^>]*>(.-)</pubDate>"))
            or stripCData(raw:match("<dc:date[^>]*>(.-)</dc:date>"))
            or stripCData(raw:match("<published[^>]*>(.-)</published>"))
            or stripCData(raw:match("<updated[^>]*>(.-)</updated>"))
        if pub_date then
            pub_date = util.trim(pub_date)
        end
        if title or link or body then
            local result = {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = body,
                date = pub_date,
            }

            insertImageCandidate(result, raw:match("<media:content[^>]-url%s*=%s*['\"](.-)['\"]"))
            insertImageCandidate(result, raw:match("<media:thumbnail[^>]-url%s*=%s*['\"](.-)['\"]"))
            local enclosure = raw:match("<enclosure[^>]-type%s*=%s*['\"]image/[^'\"]*['\"][^>]*>")
            if enclosure then
                insertImageCandidate(result, enclosure:match("url%s*=%s*['\"](.-)['\"]"))
            end
            insertImageCandidate(result, raw:match("<itunes:image[^>]-href%s*=%s*['\"](.-)['\"]"))

            table.insert(items, result)
        end
    end
    return items
end

local function parseAtom(content)
    local items = {}
    for raw in content:gmatch("<entry[%s>](.-)</entry>") do
        local title = sanitize(raw:match("<title[^>]*>(.-)</title>"))
        local link = extractAtomLink(raw)
        local content_attrs, content_body = raw:match("<content([^>]*)>(.-)</content>")
        local summary_attrs, summary_body = raw:match("<summary([^>]*)>(.-)</summary>")
        local body = decodeAtomBody(content_body, content_attrs) or decodeAtomBody(summary_body, summary_attrs)
        local pub_date = stripCData(raw:match("<updated[^>]*>(.-)</updated>"))
            or stripCData(raw:match("<published[^>]*>(.-)</published>"))
        if pub_date then
            pub_date = util.trim(pub_date)
        end
        if title or link or body then
            local result = {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = stripCData(body),
                date = pub_date,
            }

            insertImageCandidate(result, raw:match("<media:content[^>]-url%s*=%s*['\"](.-)['\"]"))
            insertImageCandidate(result, raw:match("<media:thumbnail[^>]-url%s*=%s*['\"](.-)['\"]"))
            for attrs in raw:gmatch("<link%s+([^>]-)/?>") do
                local rel = attrs:match("rel%s*=%s*['\"](.-)['\"]")
                local type_attr = attrs:match("type%s*=%s*['\"](.-)['\"]")
                if rel and rel:lower() == "enclosure" and type_attr and type_attr:lower():find("image/") then
                    insertImageCandidate(result, attrs:match("href%s*=%s*['\"](.-)['\"]"))
                end
            end

            table.insert(items, result)
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
            local result = {
                story_title = title or link or "Untitled",
                permalink = link,
                story_content = stripCData(body),
                date = pub_date,
            }

            insertImageCandidate(result, item.image or item.banner_image or item.thumbnail)
            if type(item.attachments) == "table" then
                for _, attachment in ipairs(item.attachments) do
                    if type(attachment) == "table" and type(attachment.url) == "string" then
                        local mime = attachment.mime_type or attachment.type
                        if not mime or mime:lower():find("image/") then
                            insertImageCandidate(result, attachment.url)
                        end
                    end
                end
            end

            table.insert(items, result)
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
