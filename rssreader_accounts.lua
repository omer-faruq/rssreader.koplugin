local Accounts = {}
Accounts.__index = Accounts

local DEFAULT_CONFIG = {
    accounts = {},
}

local function loadConfiguration()
    package.loaded["rssreader_configuration"] = nil
    local ok, config = pcall(require, "rssreader_configuration")
    if ok and type(config) == "table" and type(config.accounts) == "table" then
        return config
    end
    return DEFAULT_CONFIG
end

function Accounts:new()
    local config = loadConfiguration()
    local local_store = require("rssreader_local_store"):new()
    local instance = {
        config = config,
        local_store = local_store,
        newsblur_clients = {},
        commafeed_clients = {},
    }
    setmetatable(instance, self)
    return instance
end

function Accounts:getAccounts()
    if type(self.config) ~= "table" then
        return {}
    end
    local accounts = self.config.accounts or {}
    -- ensure we return an array for menu consumption
    local result = {}
    for _, account in ipairs(accounts) do
        if account.active == nil or account.active == true then
            table.insert(result, account)
        end
    end
    return result
end

function Accounts:getNewsBlurClient(account)
    if not account or account.type ~= "newsblur" then
        return nil, "Account is not a NewsBlur account"
    end
    if not account.name then
        return nil, "NewsBlur account is missing a name"
    end
    if self.newsblur_clients[account.name] then
        return self.newsblur_clients[account.name]
    end

    local NewsBlur = require("rssreader_newsblur")
    local client = NewsBlur:new(account)
    self.newsblur_clients[account.name] = client
    return client
end

function Accounts:getCommaFeedClient(account)
    if not account or account.type ~= "commafeed" then
        return nil, "Account is not a CommaFeed account"
    end
    if not account.name then
        return nil, "CommaFeed account is missing a name"
    end
    if self.commafeed_clients[account.name] then
        return self.commafeed_clients[account.name]
    end

    local CommaFeed = require("rssreader_commafeed")
    local client = CommaFeed:new(account)
    self.commafeed_clients[account.name] = client
    return client
end

return Accounts
