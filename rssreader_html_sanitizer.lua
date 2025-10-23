local HtmlSanitizer = {}

local function stripDangerousBlocks(html, tag)
    local pattern = string.format("<%%s*%s[^>]*>.-<%%s*/%s[^>]*>", tag, tag)
    html = html:gsub(pattern, "")
    local self_closing = string.format("<%%s*%s[^>]*/>", tag)
    html = html:gsub(self_closing, "")
    return html
end

local function stripDangerousAttributes(content)
    content = content:gsub("%s+on[%w_%-]+%s*=%s*\"[^\"]*\"", "")
    content = content:gsub("%s+on[%w_%-]+%s*=%s*'[^']*'", "")
    content = content:gsub("%s+on[%w_%-]+%s*=%s*[^%s>]+", "")
    content = content:gsub("(href%s*=%s*\")%s*javascript:[^\"]*(\")", "%1%2")
    content = content:gsub("(href%s*=%s*')%s*javascript:[^']*(')", "%1%2")
    content = content:gsub("(src%s*=%s*\")%s*javascript:[^\"]*(\")", "%1%2")
    content = content:gsub("(src%s*=%s*')%s*javascript:[^']*(')", "%1%2")
    return content
end

local function disableFontSizeDeclarations(content)
    if type(content) ~= "string" or content == "" then
        return content
    end

    local function replaceFontSize(value)
        if type(value) ~= "string" or value == "" then
            return value
        end
        return value:gsub("([Ff][Oo][Nn][Tt]%s*-%s*[Ss][Ii][Zz][Ee])", "font-size-disabled")
    end

    content = content:gsub('(<%s*[^>]-[Ss][Tt][Yy][Ll][Ee]%s*=%s*")([^"]*)(")', function(prefix, value, suffix)
        return prefix .. replaceFontSize(value) .. suffix
    end)

    content = content:gsub("(<%s*[^>]-[Ss][Tt][Yy][Ll][Ee]%s*=%s*')([^']*)(')", function(prefix, value, suffix)
        return prefix .. replaceFontSize(value) .. suffix
    end)

    content = content:gsub("(<%s*[Ss][Tt][Yy][Ll][Ee][^>]*>)([%s%S]-)(<%s*/%s*[Ss][Tt][Yy][Ll][Ee][^>]*>)", function(open_tag, value, close_tag)
        return open_tag .. replaceFontSize(value) .. close_tag
    end)

    return content
end

function HtmlSanitizer.sanitize(content)
    if type(content) ~= "string" then
        return nil
    end

    local cleaned = disableFontSizeDeclarations(content)
    local block_tags = {
        "script",
        "style",
        "iframe",
        "object",
        "embed",
        "noscript",
    }

    for _, tag in ipairs(block_tags) do
        cleaned = stripDangerousBlocks(cleaned, tag)
    end

    cleaned = cleaned:gsub("<%s*link[^>]->", function(tag)
        local lower = tag:lower()
        if lower:find("stylesheet") or lower:find("javascript") then
            return ""
        end
        return tag
    end)

    cleaned = cleaned:gsub("<%s*meta[^>]->", "")
    cleaned = stripDangerousAttributes(cleaned)

    return cleaned
end

function HtmlSanitizer.disableFontSizeDeclarations(content)
    return disableFontSizeDeclarations(content)
end

return HtmlSanitizer
