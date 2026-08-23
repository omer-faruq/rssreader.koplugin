local util = require("util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")

local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

-- Host of the FiveFilters API on RapidAPI. Only the makefulltextfeed.php
-- route is reachable with GET there (extract.php is POST-only and returns
-- JSON), which is convenient: makefulltextfeed.php answers with the same RSS
-- the plain type already parses, so only the auth differs.
local RAPIDAPI_HOST = "full-text-rss.p.rapidapi.com"

local FiveFiltersSanitizer = {}

function FiveFiltersSanitizer.hasLikelyXmlStructure(content)
    if type(content) ~= "string" then
        return false
    end

    local trimmed = content:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return false
    end

    if trimmed:sub(1, 1) ~= "<" then
        return false
    end

    if trimmed:find("<item", 1, true) or trimmed:find("<entry", 1, true) then
        return true
    end
    if trimmed:find("<rss", 1, true) or trimmed:find("<feed", 1, true) then
        return true
    end

    return false
end

function FiveFiltersSanitizer.buildUrl(link, sanitizer)  
    if type(link) ~= "string" or link == "" then  
        return nil  
    end  
  
    local encoded = util.urlEncode(link)  
    if not encoded or encoded == "" then  
        return nil  
    end  
  
    -- Use custom base_url if provided, otherwise use default  
    local base_url = "https://ftr.fivefilters.net"  
    if type(sanitizer) == "table" and type(sanitizer.base_url) == "string" and sanitizer.base_url ~= "" then  
        base_url = sanitizer.base_url:gsub("/+$", "")  -- Remove trailing slashes  
    end  
  
    return string.format(  
        "%s/makefulltextfeed.php?step=3&fulltext=1&url=%s&max=3&links=preserve&exc=1&submit=Create+Feed",  
        base_url,  
        encoded  
    )  
end

-- Same call as buildUrl, aimed at the RapidAPI proxy. base_url stays
-- overridable so a RapidAPI-style deployment on another host can be used.
function FiveFiltersSanitizer.buildRapidApiUrl(sanitizer, link)
    if type(sanitizer) ~= "table" then
        return nil
    end

    local token = sanitizer.token
    if type(token) ~= "string" or token == "" then
        return nil
    end

    local base_url = sanitizer.base_url
    if type(base_url) ~= "string" or base_url == "" then
        base_url = "https://" .. RAPIDAPI_HOST
    end

    return FiveFiltersSanitizer.buildUrl(link, { base_url = base_url })
end

-- RapidAPI authenticates with headers, which utils.fetchViaHttp cannot send,
-- so this mirrors what the Diffbot and Instaparser sanitizers already do.
function FiveFiltersSanitizer.fetchContent(sanitizer, url, on_complete)
    local token = type(sanitizer) == "table" and sanitizer.token or nil
    if type(token) ~= "string" or token == "" then
        if on_complete then
            on_complete(nil, "missing_token")
        end
        return
    end

    -- The proxy routes on the Host header, so it has to name the host we call.
    local host = url:match("^https?://([^/]+)") or RAPIDAPI_HOST

    local sink = {}
    -- Extraction runs server-side; measured calls land well under a second,
    -- so the same budget as the other sanitizers is plenty.
    socketutil:set_timeout(8, 20)
    local ok, status_code, _, status_text = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
            ["x-rapidapi-host"] = host,
            ["x-rapidapi-key"] = token,
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
        -- 401/403 means a bad or missing key, 429 an exhausted quota.
        logger.info("RSSReader", "FiveFilters RapidAPI request failed", status_text or status_code)
        if on_complete then
            on_complete(nil, status_text or status_code or "rapidapi_request_failed")
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

function FiveFiltersSanitizer.detectBlocked(content)
    if type(content) ~= "string" then
        return false
    end

    return content:find("URL blocked", 1, true) ~= nil
end

local function extractTagContent(block, tag)
    local pattern = string.format("<%s[^>]*>(.-)</%s>", tag, tag)
    local value = block:match(pattern)
    if not value then
        return nil
    end

    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    local cdata = value:match("^<!%[CDATA%[(.*)%]%]>$")
    if cdata then
        value = cdata
    end

    return value
end

function FiveFiltersSanitizer.extractHtml(xml_content)
    if type(xml_content) ~= "string" or xml_content == "" then
        return nil
    end

    local item_block = xml_content:match("<item[^>]*>(.-)</item>")
    if not item_block then
        return nil
    end

    local title_text = util.htmlEntitiesToUtf8(extractTagContent(item_block, "title") or "")
    local description_text = extractTagContent(item_block, "description") or ""

    if description_text == "" then
        return nil
    end

    description_text = util.htmlEntitiesToUtf8(description_text)
    description_text = description_text:gsub("&lt;", "<"):gsub("&gt;", ">")

    local placeholder_marker = "[unable to retrieve full-text content]"
    if description_text:lower():find(placeholder_marker, 1, true) then
        return nil
    end

    local fragments = {}
    table.insert(fragments, description_text)

    return table.concat(fragments, "")
end

function FiveFiltersSanitizer.rewriteHtml(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end

    local trimmed = html:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return nil
    end

    local cleaned = trimmed:gsub(
        "%s*<p>%s*<strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org\">Adblock%s+test</a>%s*</strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org/acceptable%.html\">%(Why%?%)</a>%s*</p>%s*",
        ""
    )

    return cleaned
end

function FiveFiltersSanitizer.cleanupHtml(html)
    if type(html) ~= "string" or html == "" then
        return html
    end

    return html:gsub(
        "%s*<p>%s*<strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org\">Adblock%s+test</a>%s*</strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org/acceptable%.html\">%(Why%?%)</a>%s*</p>%s*",
        ""
    )
end

function FiveFiltersSanitizer.contentIsMeaningful(html)
    return SanitizerBase.contentIsMeaningful(html, 200)
end

return FiveFiltersSanitizer
