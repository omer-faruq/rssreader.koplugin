local util = require("util")
local json = require("json")
local http = require("socket.http")
local socketutil = require("socketutil")
local logger = require("logger")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

local DiffbotSanitizer = {}

local DEFAULT_ENDPOINT = "https://api.diffbot.com/v3/analyze"

-- Diffbot renders the target page server-side and sends *nothing* until the
-- extraction is done, so time-to-first-byte is effectively the whole call.
-- Measured on real articles it runs 3-23s, which is also why this value has
-- to feed the socket budget in fetchContent and not just the query string.
local DEFAULT_TIMEOUT_MS = 30000

-- The free (kgfree) plan allows roughly one call per 10s and answers 429 with
-- a Retry-After. Waiting longer than this for a single article is worse than
-- falling through to the next sanitizer.
local MAX_RETRY_WAIT_S = 12

--- Diffbot's own page-fetch budget, in milliseconds.
-- Without it Diffbot gives up on slow sites and returns errorCode 500.
function DiffbotSanitizer.resolveTimeoutMs(sanitizer)
    local configured = type(sanitizer) == "table" and tonumber(sanitizer.timeout) or nil
    if configured and configured > 0 then
        return math.floor(configured)
    end
    return DEFAULT_TIMEOUT_MS
end

function DiffbotSanitizer.buildUrl(sanitizer, link)
    if type(link) ~= "string" or link == "" then
        return nil
    end
    if type(sanitizer) ~= "table" then
        return nil
    end

    local token = sanitizer.token
    if type(token) ~= "string" or token == "" then
        return nil
    end

    local endpoint = sanitizer.endpoint
    if type(endpoint) ~= "string" or endpoint == "" then
        endpoint = DEFAULT_ENDPOINT
    end

    local params = {}
    local function addParam(key, value)
        if value == nil then
            return
        end
        local value_type = type(value)
        if value_type == "string" then
            if value == "" then
                return
            end
            params[#params + 1] = string.format("%s=%s", key, util.urlEncode(value))
        elseif value_type == "number" then
            params[#params + 1] = string.format("%s=%s", key, tostring(value))
        elseif value_type == "boolean" then
            params[#params + 1] = string.format("%s=%s", key, value and "true" or "false")
        end
    end

    addParam("token", token)
    addParam("url", link)
    addParam("mode", sanitizer.mode)
    addParam("fallback", sanitizer.fallback)
    addParam("fields", sanitizer.fields)
    if sanitizer.discussion ~= nil then
        addParam("discussion", sanitizer.discussion and "true" or "false")
    end
    params[#params + 1] = string.format("timeout=%d", DiffbotSanitizer.resolveTimeoutMs(sanitizer))
    if type(sanitizer.params) == "table" then
        for key, value in pairs(sanitizer.params) do
            -- timeout is already set above from resolveTimeoutMs, which
            -- fetchContent also sizes its socket budget from; letting a raw
            -- params entry through would send it twice.
            if type(key) == "string" and key ~= "" and key ~= "timeout" and key ~= "token" and key ~= "url" then
                addParam(key, value)
            end
        end
    end

    if #params == 0 then
        return nil
    end

    return string.format("%s?%s", endpoint, table.concat(params, "&"))
end

--- Seconds to wait before retrying, from a 429's Retry-After header.
-- Diffbot answers with "0 days, 00:00:09" rather than a plain second count or
-- an HTTP-date, so tonumber() alone does not get there.
function DiffbotSanitizer.parseRetryAfter(headers)
    if type(headers) ~= "table" then
        return nil
    end
    local value = headers["retry-after"] or headers["Retry-After"]
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end

    local days, hours, minutes, seconds = value:match("(%d+)%s*days?%s*,%s*(%d+):(%d+):(%d+)")
    if days then
        return tonumber(days) * 86400 + tonumber(hours) * 3600
            + tonumber(minutes) * 60 + tonumber(seconds)
    end

    local h, m, sec = value:match("(%d+):(%d+):(%d+)")
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
    end

    return tonumber(value)
end

-- options.timeout_ms sizes the socket budget (see DEFAULT_TIMEOUT_MS), and
-- options.wait_callback(seconds) is how a 429 retry waits without freezing the
-- UI; it returns false to cancel. Both are optional.
function DiffbotSanitizer.fetchContent(diffbot_url, on_complete, options)
    options = type(options) == "table" and options or {}
    local timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS
    local wait_callback = options.wait_callback

    -- Diffbot holds the connection open while it extracts and only then
    -- answers, so the wait for the first byte is bounded by the *block*
    -- timeout. The previous 8s dropped most successful responses on the floor
    -- (measured TTFB median ~9s). Give it Diffbot's own budget plus slack, and
    -- use socketutil.table_sink so the total timeout is actually enforced -
    -- plain ltn12.sink.table ignores it entirely.
    local block_timeout = math.ceil(timeout_ms / 1000) + 5
    local total_timeout = block_timeout + 15

    local attempted_retry = false

    local function attempt()
        local sink = {}
        socketutil:set_timeout(block_timeout, total_timeout)
        local ok, status_code, headers, status_text = http.request{
            url = diffbot_url,
            method = "GET",
            sink = socketutil.table_sink(sink),
            headers = {
                ["Accept-Encoding"] = "identity",
                ["User-Agent"] = "KOReader RSSReader",
                ["Accept"] = "application/json",
            },
        }
        socketutil:reset_timeout()

        if not ok or tostring(status_code):sub(1, 1) ~= "2" then
            -- 429 is the common case on the free plan, and it comes with a
            -- short Retry-After. Honoring it once recovers the call instead of
            -- silently handing the article to the next sanitizer.
            if tostring(status_code) == "429" and not attempted_retry and wait_callback then
                attempted_retry = true
                local delay = DiffbotSanitizer.parseRetryAfter(headers) or 5
                if delay > 0 and delay <= MAX_RETRY_WAIT_S then
                    logger.info("RSSReader", "Diffbot rate-limited; retrying in", delay)
                    if wait_callback(delay) == false then
                        if on_complete then
                            on_complete(nil, "cancelled")
                        end
                        return
                    end
                    return attempt()
                end
                logger.info("RSSReader", "Diffbot rate-limited; Retry-After too long", delay)
            end
            logger.info("RSSReader", "Diffbot request failed", status_text or status_code)
            if on_complete then
                on_complete(nil, status_text or status_code or "diffbot_request_failed")
            end
            return
        end

        local payload = table.concat(sink)
        if not payload or payload == "" then
            if on_complete then
                on_complete(nil, "empty_content")
            end
            return
        end

        if on_complete then
            on_complete(payload)
        end
    end

    attempt()
end

function DiffbotSanitizer.parseResponse(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end

    local ok, decoded = pcall(json.decode, payload)
    if not ok or type(decoded) ~= "table" then
        logger.info("RSSReader", "Unable to decode Diffbot response")
        return nil
    end

    if decoded.error or decoded.errorCode then
        logger.info("RSSReader", "Diffbot returned an error", decoded.error or decoded.errorCode)
        return nil
    end

    local objects = decoded.objects
    if type(objects) ~= "table" then
        return nil
    end

    local fallback_text
    for _, object in ipairs(objects) do
        if type(object) == "table" then
            local object_type = object.type
            local html = object.html
            if type(html) == "string" and html:match("%S") then
                if object_type ~= "other" or DiffbotSanitizer.contentIsMeaningful(html) then
                    return html
                end
            end
            if not fallback_text then
                -- Article objects carry text; type "other"/"list" objects come
                -- back with only a `content` field, which was previously never
                -- read, so those responses always looked empty.
                local text = object.text
                if type(text) ~= "string" or not text:match("%S") then
                    text = object.content
                end
                if type(text) == "string" and text:match("%S") then
                    fallback_text = text
                end
            end
        end
    end

    if not fallback_text then
        return nil
    end

    local paragraphs = {}
    for paragraph in fallback_text:gmatch("[^\r\n]+") do
        local trimmed = paragraph:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            paragraphs[#paragraphs + 1] = string.format("<p>%s</p>", util.htmlEscape(trimmed))
        end
    end

    if #paragraphs == 0 then
        return nil
    end

    return table.concat(paragraphs, "")
end

function DiffbotSanitizer.contentIsMeaningful(html)
    return SanitizerBase.contentIsMeaningful(html, 150)
end

return DiffbotSanitizer
