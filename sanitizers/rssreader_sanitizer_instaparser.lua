local util = require("util")
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

local InstaparserSanitizer = {}

local DEFAULT_ENDPOINT = "https://www.instaparser.com/api/1/article"

function InstaparserSanitizer.fetchArticle(sanitizer, link, on_complete)
    if type(link) ~= "string" or link == "" then
        if on_complete then
            on_complete(nil, "invalid_url")
        end
        return
    end
    if type(sanitizer) ~= "table" then
        if on_complete then
            on_complete(nil, "invalid_sanitizer_config")
        end
        return
    end

    local token = sanitizer.token
    if type(token) ~= "string" or token == "" then
        if on_complete then
            on_complete(nil, "missing_token")
        end
        return
    end

    local endpoint = sanitizer.endpoint
    if type(endpoint) ~= "string" or endpoint == "" then
        endpoint = DEFAULT_ENDPOINT
    end

    local request_body = {
        url = link,
        output = "html",
    }
    if sanitizer.use_cache ~= nil then
        if sanitizer.use_cache then
            request_body.use_cache = "true"
        else
            request_body.use_cache = "false"
        end
    end

    local ok_encode, body_str = pcall(json.encode, request_body)
    if not ok_encode or not body_str then
        if on_complete then
            on_complete(nil, "json_encode_failed")
        end
        return
    end

    local sink = {}
    socketutil:set_timeout(30, 60)
    local ok, status_code, _, status_text = http.request{
        url = endpoint,
        method = "POST",
        source = ltn12.source.string(body_str),
        sink = ltn12.sink.table(sink),
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body_str),
            ["Accept"] = "application/json",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
        logger.info("RSSReader", "Instaparser request failed", status_text or status_code)
        if on_complete then
            on_complete(nil, status_text or status_code or "instaparser_request_failed")
        end
        return
    end

    local payload = table.concat(sink)
    if not payload or payload == "" then
        if on_complete then
            on_complete(nil, "empty_response")
        end
        return
    end

    if on_complete then
        on_complete(payload)
    end
end

function InstaparserSanitizer.parseResponse(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end

    local ok, decoded = pcall(json.decode, payload)
    if not ok or type(decoded) ~= "table" then
        logger.info("RSSReader", "Unable to decode Instaparser response")
        return nil
    end

    if decoded.error then
        logger.info("RSSReader", "Instaparser returned an error", decoded.error)
        return nil
    end

    local html = decoded.html
    if type(html) == "string" and html:match("%S") then
        if InstaparserSanitizer.contentIsMeaningful(html) then
            return html
        end
    end

    local text = decoded.text
    if type(text) == "string" and text:match("%S") then
        local paragraphs = {}
        for paragraph in text:gmatch("[^\r\n]+") do
            local trimmed = paragraph:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                paragraphs[#paragraphs + 1] = string.format("<p>%s</p>", util.htmlEscape(trimmed))
            end
        end
        if #paragraphs > 0 then
            local fallback = table.concat(paragraphs, "")
            if InstaparserSanitizer.contentIsMeaningful(fallback) then
                return fallback
            end
        end
    end

    return nil
end

function InstaparserSanitizer.contentIsMeaningful(html)
    return SanitizerBase.contentIsMeaningful(html, 150)
end

return InstaparserSanitizer
