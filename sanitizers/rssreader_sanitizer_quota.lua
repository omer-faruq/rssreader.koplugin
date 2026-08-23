-- Monthly request counter for sanitizers that are billed per call.
--
-- RapidAPI's free BASIC plan is a *soft* limit: once the included requests are
-- used up the calls are not blocked, they are billed (currently $0.05 each),
-- and the only warning is a notice at 85% and 100% of the quota. Since the
-- sanitizer chain fires on every story that gets opened, the brake has to live
-- on this side.
--
-- The counter is deliberately conservative: it is incremented before the
-- request goes out, so a failed call still costs a slot rather than risking an
-- undercount against real billing.

local json = require("common/json")
local util = require("util")
local DataStorage = require("datastorage")
local logger = require("logger")

local Quota = {}

local QUOTA_FILE = DataStorage:getDataDir() .. "/data/rssreader_sanitizer_quota.json"

-- Local time, not UTC: the point is to match the month the user sees, and a
-- day of drift against the provider's own reset is harmless for a brake.
local function currentPeriod()
    return os.date("%Y-%m")
end

local function ensureDataDir()
    local dir = DataStorage:getDataDir() .. "/data"
    util.makePath(dir)
    return dir
end

local function decodeJson(content)
    if type(content) ~= "string" or content == "" then
        return nil
    end
    local decoder
    local decode_value = json.decode
    if type(decode_value) == "function" then
        decoder = decode_value
    elseif type(decode_value) == "table" and type(decode_value.decode) == "function" then
        decoder = decode_value.decode
    else
        return nil
    end
    local ok, data = pcall(decoder, content)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data
end

local function encodeJson(data)
    local ok, encoded = pcall(function() return json.encode(data) end)
    if not ok or type(encoded) ~= "string" then
        return nil
    end
    return encoded
end

local state -- cached across calls; the file is tiny but this runs per story

local function freshState()
    return { period = currentPeriod(), counts = {}, warned = {} }
end

local function loadState()
    if state then
        -- A reader session can outlive a month boundary.
        if state.period ~= currentPeriod() then
            state = freshState()
        end
        return state
    end

    local file = io.open(QUOTA_FILE, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local decoded = decodeJson(content)
        if decoded and decoded.period == currentPeriod() and type(decoded.counts) == "table" then
            decoded.warned = type(decoded.warned) == "table" and decoded.warned or {}
            state = decoded
            return state
        end
    end

    -- Missing, unreadable or from a previous month: start the period over.
    state = freshState()
    return state
end

local function saveState()
    if not state then
        return false
    end
    local encoded = encodeJson(state)
    if not encoded then
        return false
    end
    ensureDataDir()
    local file = io.open(QUOTA_FILE, "w")
    if not file then
        logger.info("RSSReader", "Unable to write sanitizer quota file")
        return false
    end
    file:write(encoded)
    file:close()
    return true
end

-- Requests already made in the current month for this sanitizer id.
function Quota.used(id)
    if type(id) ~= "string" or id == "" then
        return 0
    end
    local current = loadState()
    return tonumber(current.counts[id]) or 0
end

-- Books a request against `limit`. Returns true when the caller may proceed
-- (and the request has been counted), false when the quota is spent.
-- A limit of nil, 0 or a negative number means "no ceiling".
function Quota.consume(id, limit)
    if type(id) ~= "string" or id == "" then
        return true
    end

    local ceiling = tonumber(limit)
    local current = loadState()
    local used = tonumber(current.counts[id]) or 0

    if ceiling and ceiling > 0 and used >= ceiling then
        return false
    end

    current.counts[id] = used + 1
    saveState()
    return true
end

-- True the first time a quota runs out in a given month, so the caller can
-- tell the user once instead of on every story they open afterwards.
function Quota.shouldWarn(id)
    if type(id) ~= "string" or id == "" then
        return false
    end
    local current = loadState()
    if current.warned[id] then
        return false
    end
    current.warned[id] = true
    saveState()
    return true
end

return Quota
