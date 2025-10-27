local SanitizerBase = {}

function SanitizerBase.contentIsMeaningful(html, minimum_length)
    if type(html) ~= "string" then
        return false
    end

    local trimmed = html:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return false
    end

    local threshold = tonumber(minimum_length) or 200
    return trimmed:len() >= threshold
end

return SanitizerBase
