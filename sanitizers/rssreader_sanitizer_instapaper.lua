local rapidjson = require("rapidjson")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")
local RateLimit = require("sanitizers/rssreader_sanitizer_ratelimit")

-- Instapaper's parser, reached through API v2 with a personal access token:
-- save the link as a bookmark, read back its parsed body, delete the
-- bookmark again. The API has no "parse a URL" call, only "parse a saved
-- bookmark", hence the round trip. Parsing is free for personal use (the
-- token's owner registered the application); past Instaparser's free credit
-- it answers 402 and the chain moves on.
--
-- Saving a URL the account already has returns the existing bookmark rather
-- than a new one, so the delete step only runs for a bookmark that looks
-- freshly made (isPreexisting). A separate Instapaper account for this keeps
-- the user's own reading list out of reach entirely.
local InstapaperSanitizer = {}

local DEFAULT_API_BASE = "https://www.instapaper.com/api/2"
-- Parsing goes through Instaparser, which allows 1 call per second on its
-- free tier; the same spacing as the Instaparser sanitizer.
local DEFAULT_SECONDS_BETWEEN_CALLS = 2
-- A bookmark saved more than this long before the server's clock at the
-- moment it answered was already in the account.
local FRESH_BOOKMARK_SECONDS = 120
-- After an answer that will not change on the next story (token refused,
-- parse credit used up, application suspended), stories skip this sanitizer
-- for this long instead of each spending a save and a delete to find out.
local PAUSE_SECONDS = 3600

-- Unix time until which the sanitizer is skipped; in memory, so a restart
-- tries again. Forked workers inherit it, but what they learn stays theirs.
local paused_until = 0

-- 401: token refused; 402: parse credit used up; 403: application not
-- approved or suspended.
InstapaperSanitizer.PAUSING_CODES = { [401] = true, [402] = true, [403] = true }

-- For tests.
function InstapaperSanitizer.resetPause()
    paused_until = 0
end

local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- Unix time of an HTTP Date header ("Sun, 11 Oct 2026 12:06:00 GMT"), or nil.
-- The server's clock, not the device's: e-readers often keep the wrong time.
function InstapaperSanitizer.parseHttpDate(value)
    if type(value) ~= "string" then
        return nil
    end
    local day, mon, year, hour, min, sec = value:match("(%d+) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d)")
    local month = MONTHS[mon or ""]
    if not month then
        return nil
    end
    day, year = tonumber(day), tonumber(year)
    -- Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (month + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(hour) * 3600 + tonumber(min) * 60 + tonumber(sec)
end

-- Whether the bookmark POST /bookmarks returned was already in the account
-- (then it must not be deleted). Anything the user did to it gives it away;
-- failing that, its save time against the server's clock. When in doubt it
-- counts as existing: a leftover bookmark is better than a lost one.
function InstapaperSanitizer.isPreexisting(bookmark, server_now)
    if type(bookmark) ~= "table" then
        return true
    end
    if bookmark.archived == true or bookmark.liked == true then
        return true
    end
    if type(bookmark.folder_id) == "number" then
        return true
    end
    if type(bookmark.tags) == "table" and #bookmark.tags > 0 then
        return true
    end
    local progress = type(bookmark.progress) == "table" and bookmark.progress or {}
    if type(progress.percentage) == "number" and progress.percentage > 0 then
        return true
    end
    local saved_at = bookmark.time
    if type(saved_at) ~= "number" or type(server_now) ~= "number" then
        return true
    end
    return server_now - saved_at > FRESH_BOOKMARK_SECONDS
end

-- One API v2 call. Returns status code (or nil), decoded JSON body (or nil),
-- response headers.
local function request(api_base, token, method, path, body)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["User-Agent"] = "KOReader RSSReader",
    }
    local source
    if body ~= nil then
        local ok_encode, body_str = pcall(rapidjson.encode, body)
        if not ok_encode or not body_str then
            return nil
        end
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_str)
        source = ltn12.source.string(body_str)
    end

    local sink = {}
    -- Modest timeouts, like the other sanitizers: a slow call should hand
    -- over to the next sanitizer rather than stall the story.
    socketutil:set_timeout(8, 15)
    local ok, status_code, response_headers = http.request{
        url = api_base .. path,
        method = method,
        source = source,
        sink = socketutil.table_sink(sink),
        headers = headers,
    }
    socketutil:reset_timeout()
    if not ok then
        logger.info("RSSReader", "Instapaper", method, path, "failed", status_code)
        return nil
    end

    local decoded
    local payload = table.concat(sink)
    if payload ~= "" then
        -- rapidjson, like the Feedbin sanitizer: LuaJSON can abort the
        -- process on a reply that is not JSON at all, even under pcall.
        local ok_decode, value = pcall(rapidjson.decode, payload)
        if ok_decode and type(value) == "table" then
            decoded = value
        end
    end
    return tonumber(status_code), decoded, response_headers
end

local function isSuccess(code)
    return code and code >= 200 and code < 300
end

local function errorMessage(code, decoded)
    local err = type(decoded) == "table" and decoded.error
    local message = type(err) == "table" and type(err.message) == "string" and err.message or nil
    return tostring(code or "network error") .. (message and (": " .. message) or "")
end

-- options.title: the story's title; sending it spares Instapaper looking it
-- up before it answers. Calls on_complete(html) or on_complete(nil, error).
function InstapaperSanitizer.fetchArticle(sanitizer, link, on_complete, options)
    local function finish(html, err)
        if on_complete then
            on_complete(html, err)
        end
    end

    if type(link) ~= "string" or link == "" then
        return finish(nil, "invalid_url")
    end
    if type(sanitizer) ~= "table" then
        return finish(nil, "invalid_sanitizer_config")
    end
    local token = sanitizer.token
    if type(token) ~= "string" or token == "" then
        return finish(nil, "missing_token")
    end
    local api_base = sanitizer.base_url
    if type(api_base) ~= "string" or api_base == "" then
        api_base = DEFAULT_API_BASE
    end
    api_base = api_base:gsub("/+$", "")

    local save_body = { url = link }
    local title = type(options) == "table" and options.title
    if type(title) == "string" and title:match("%S") then
        save_body.title = title
    end

    if os.time() < paused_until then
        return finish(nil, "instapaper_paused")
    end

    -- seconds_between_calls in the sanitizer entry overrides it (0 = no limit).
    local interval = RateLimit.intervalFor(sanitizer, DEFAULT_SECONDS_BETWEEN_CALLS)

    -- spaced: keep to the interval (the parse, which is Instaparser's limit).
    -- Rate-limited anyway (another device on the same account, say): one
    -- more try in the next free slot.
    local function requestWithRetry(spaced, method, path, body)
        local code, decoded, headers
        for attempt = 1, 2 do
            if spaced or attempt > 1 then
                RateLimit.wait("instapaper", interval)
            end
            code, decoded, headers = request(api_base, token, method, path, body)
            if code ~= 429 or attempt == 2 then
                break
            end
            logger.info("RSSReader", "Instapaper rate-limited; retrying in the next slot")
        end
        return code, decoded, headers
    end

    local function pauseOn(code, decoded)
        if InstapaperSanitizer.PAUSING_CODES[code] then
            paused_until = os.time() + PAUSE_SECONDS
            logger.warn("RSSReader", "Instapaper sanitizer paused for", PAUSE_SECONDS, "s:",
                errorMessage(code, decoded))
        end
    end

    local code, bookmark, headers = requestWithRetry(false, "POST", "/bookmarks", save_body)
    if not isSuccess(code) or type(bookmark) ~= "table" or type(bookmark.id) ~= "number" then
        logger.info("RSSReader", "Instapaper save failed", errorMessage(code, bookmark))
        pauseOn(code, bookmark)
        return finish(nil, "instapaper_save_failed")
    end

    local bookmark_id = string.format("%d", bookmark.id)
    local server_now = InstapaperSanitizer.parseHttpDate(type(headers) == "table" and headers["date"])
    local keep = InstapaperSanitizer.isPreexisting(bookmark, server_now)

    local parse_code, parsed = requestWithRetry(true, "GET", "/bookmarks/" .. bookmark_id .. "/parse")

    -- Before looking at the result, so a failed parse leaves nothing behind.
    if keep then
        logger.info("RSSReader", "Instapaper: link was already saved, keeping bookmark", bookmark_id)
    else
        local delete_code, delete_body = request(api_base, token, "DELETE", "/bookmarks/" .. bookmark_id)
        if not isSuccess(delete_code) then
            logger.warn("RSSReader", "Instapaper: could not delete temporary bookmark",
                bookmark_id, errorMessage(delete_code, delete_body))
        end
    end

    if not isSuccess(parse_code) then
        logger.info("RSSReader", "Instapaper parse failed", errorMessage(parse_code, parsed))
        pauseOn(parse_code, parsed)
        return finish(nil, "instapaper_parse_failed")
    end
    finish(InstapaperSanitizer.extractHtml(parsed))
end

-- Decoded parse response -> article body HTML, or nil.
function InstapaperSanitizer.extractHtml(parsed)
    local content = type(parsed) == "table" and parsed.content
    if type(content) ~= "table" then
        return nil
    end
    local body = content.body
    if type(body) ~= "string" or not body:match("%S") then
        return nil
    end
    if content.paywalled == true then
        logger.info("RSSReader", "Instapaper: article looks paywalled, body may be a preview")
    end
    if content.direction == "rtl" then
        body = '<div dir="rtl">' .. body .. "</div>"
    end
    return body
end

function InstapaperSanitizer.contentIsMeaningful(html)
    return SanitizerBase.contentIsMeaningful(html, 150)
end

return InstapaperSanitizer
