local _ = require("gettext")

local Commons = {}

function Commons.accountTitle(account)
    if type(account) ~= "table" then
        return _("Unnamed Account")
    end
    local title = account.name
    if type(title) ~= "string" or title == "" then
        title = _("Unnamed Account")
    end
    return title
end

return Commons
