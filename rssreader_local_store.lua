local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local LocalStore = {}
LocalStore.__index = LocalStore

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = deepCopy(entry)
    end
    return result
end

local function loadPluginDefaults()
    local path = package.searchpath("rssreader_local_defaults", package.path)
    if not path then
        local base_path = lfs.currentdir() .. "/plugins/rssreader.koplugin/rssreader_local_defaults.lua"
        path = base_path
    end

    local attributes = path and lfs.attributes(path, "mode")
    if attributes ~= "file" then
        logger.warn("RSSReader", "Local defaults file not found: " .. tostring(path))
        return { accounts = {} }
    end

    local chunk, load_err = loadfile(path)
    if not chunk then
        logger.warn("RSSReader", "Failed to load defaults file: " .. tostring(load_err))
        return { accounts = {} }
    end

    local ok, data_or_err = pcall(chunk)
    if not ok then
        logger.warn("RSSReader", "Failed to execute defaults file: " .. tostring(data_or_err))
        return { accounts = {} }
    end

    if type(data_or_err) ~= "table" or type(data_or_err.accounts) ~= "table" then
        logger.warn("RSSReader", "Defaults file is invalid or missing 'accounts' table: " .. tostring(path))
        return { accounts = {} }
    end

    return data_or_err
end

local DEFAULT_DATA = deepCopy(loadPluginDefaults())

function LocalStore:new()
    local instance = {
        data = deepCopy(DEFAULT_DATA),
    }
    setmetatable(instance, self)
    if type(instance.data.accounts) ~= "table" then
        instance.data.accounts = {}
    end
    return instance
end

function LocalStore:getAccounts()
    return self.data.accounts or {}
end

function LocalStore:getAccount(name)
    local accounts = self:getAccounts()
    return accounts[name]
end

function LocalStore:listGroups(name)
    local account = self:getAccount(name)
    if type(account) ~= "table" then
        return {}
    end
    return account.groups or {}
end

function LocalStore:listFeeds(name)
    local account = self:getAccount(name)
    if type(account) ~= "table" then
        return {}
    end
    return account.feeds or {}
end

return LocalStore
