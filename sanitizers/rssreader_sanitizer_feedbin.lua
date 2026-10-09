local rapidjson = require("rapidjson")
local http = require("socket.http")
local logger = require("logger")
local socketutil = require("socketutil")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

-- Feedbin's full-article extraction (Mercury Parser). Every Feedbin entry
-- carries a pre-signed extracted_content_url, so this needs no account or
-- token, and it only applies to stories from a Feedbin account.
local FeedbinSanitizer = {}

function FeedbinSanitizer.extractionUrl(story)
    local extraction_url = type(story) == "table" and story.extracted_content_url
    if type(extraction_url) ~= "string" or extraction_url == "" then
        return nil
    end
    return extraction_url
end

function FeedbinSanitizer.fetchArticle(extraction_url, on_complete)
    local sink = {}
    -- Keep timeouts modest so a slow extraction doesn't stall fetchStoryContent;
    -- the original article fetch can still be tried as fallback.
    socketutil:set_timeout(8, 15)
    local ok, status_code, _, status_text = http.request{
        url = extraction_url,
        method = "GET",
        sink = socketutil.table_sink(sink),
        headers = {
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
        logger.info("RSSReader", "Feedbin extraction request failed", status_text or status_code)
        if on_complete then
            on_complete(nil, status_text or status_code or "feedbin_extraction_failed")
        end
        return
    end

    local payload = table.concat(sink)
    if payload == "" then
        if on_complete then
            on_complete(nil, "empty_response")
        end
        return
    end

    if on_complete then
        on_complete(payload)
    end
end

function FeedbinSanitizer.parseResponse(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end

    -- rapidjson, like rssreader_feedbin.lua: LuaJSON can abort the process
    -- on a reply that is not JSON at all, even under pcall.
    local ok, decoded = pcall(rapidjson.decode, payload)
    if not ok or type(decoded) ~= "table" then
        logger.info("RSSReader", "Unable to decode Feedbin extraction response")
        return nil
    end

    local html = decoded.content
    if type(html) ~= "string" or not html:match("%S") then
        return nil
    end
    return html
end

function FeedbinSanitizer.contentIsMeaningful(html)
    return SanitizerBase.contentIsMeaningful(html, 150)
end

return FeedbinSanitizer
