local util = require("util")
local SanitizerBase = require("sanitizers/rssreader_sanitizer_base")

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

function FiveFiltersSanitizer.buildUrl(link)
    if type(link) ~= "string" or link == "" then
        return nil
    end

    local encoded = util.urlEncode(link)
    if not encoded or encoded == "" then
        return nil
    end

    return string.format(
        "https://ftr.fivefilters.net/makefulltextfeed.php?step=3&fulltext=1&url=%s&max=3&links=preserve&exc=1&submit=Create+Feed",
        encoded
    )
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
    if title_text ~= "" then
        table.insert(fragments, string.format("<h3>%s</h3>", title_text))
    end
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
