local util = require("util")
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

local DiffbotSanitizer = {}

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
        endpoint = "https://api.diffbot.com/v3/analyze"
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
    if sanitizer.timeout ~= nil then
        local timeout_value = tonumber(sanitizer.timeout)
        if timeout_value and timeout_value > 0 then
            params[#params + 1] = string.format("timeout=%d", math.floor(timeout_value))
        end
    end
    if type(sanitizer.params) == "table" then
        for key, value in pairs(sanitizer.params) do
            if type(key) == "string" and key ~= "" then
                addParam(key, value)
            end
        end
    end

    if #params == 0 then
        return nil
    end

    return string.format("%s?%s", endpoint, table.concat(params, "&"))
end

function DiffbotSanitizer.fetchContent(diffbot_url, on_complete)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, status_code, _, status_text = http.request{
        url = diffbot_url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
            ["Accept"] = "application/json",
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
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
                local text = object.text
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
