local json = require("common/json")
local util = require("util")
local DataStorage = require("datastorage")
local sha2 = require("ffi/sha2")

local LocalReadState = {}

local BASE_DIR = DataStorage:getDataDir() .. "/data/rssreader_local_log"

local function ensureBaseDir()
    util.makePath(BASE_DIR)
    return BASE_DIR
end

local function toString(value)
    if value == nil then
        return nil
    end
    return tostring(value)
end

local function buildFilename(feed_identifier)
    local base_dir = ensureBaseDir()
    local identifier = feed_identifier
    if type(identifier) ~= "string" or identifier == "" then
        identifier = tostring(identifier or "local_feed")
    end
    local digest = sha2.md5(identifier)
    local sanitized = identifier
    if type(sanitized) ~= "string" then
        sanitized = tostring(sanitized)
    end
    sanitized = sanitized:gsub("[\\/:*?\"<>|]", "_")
    sanitized = sanitized:gsub("%s+", "_")
    sanitized = sanitized:gsub("__+", "_")
    sanitized = sanitized:gsub("^_+", "")
    sanitized = sanitized:gsub("_+$", "")
    if sanitized == "" then
        sanitized = "local_feed"
    else
        sanitized = sanitized:sub(1, 80)
    end
    return string.format("%s/%s_%s.json", base_dir, sanitized, digest)
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

local function writeFile(path, data)
    local file = io.open(path, "w")
    if not file then
        return false
    end
    local ok = file:write(data)
    file:close()
    return ok and true or false
end

local function encodePayload(map)
    local payload = { read_stories = {} }
    for key, value in pairs(map or {}) do
        if value then
            payload.read_stories[tostring(key)] = true
        end
    end
    return json.encode(payload)
end

local function decodePayload(content)
    if type(content) ~= "string" or content == "" then
        return {}
    end
    local decoder
    local decode_value = json.decode
    if type(decode_value) == "function" then
        decoder = decode_value
    elseif type(decode_value) == "table" and type(decode_value.decode) == "function" then
        decoder = decode_value.decode
    else
        return {}
    end
    local ok, data = pcall(decoder, content)
    if not ok or type(data) ~= "table" then
        return {}
    end
    local source = data.read_stories
    if type(source) ~= "table" then
        source = {}
        for key, value in pairs(data) do
            if value == true then
                source[key] = true
            end
        end
    end
    local result = {}
    for key, value in pairs(source) do
        if value then
            result[tostring(key)] = true
        end
    end
    return result
end

function LocalReadState.load(feed_identifier)
    local path = buildFilename(feed_identifier)
    local content = readFile(path)
    return decodePayload(content), path
end

function LocalReadState.save(feed_identifier, map)
    local path = buildFilename(feed_identifier)
    local encoded = encodePayload(map or {})
    writeFile(path, encoded)
    return path
end

function LocalReadState.markRead(feed_identifier, story_key, map)
    local key = toString(story_key)
    if not key then
        return map
    end
    map = map or {}
    if not map[key] then
        map[key] = true
        LocalReadState.save(feed_identifier, map)
    else
        LocalReadState.save(feed_identifier, map)
    end
    return map
end

function LocalReadState.markUnread(feed_identifier, story_key, map)
    local key = toString(story_key)
    if not key or not map then
        return map
    end
    if map[key] then
        map[key] = nil
        LocalReadState.save(feed_identifier, map)
    end
    return map
end

function LocalReadState.prune(feed_identifier, map, valid_keys)
    map = map or {}
    if type(valid_keys) ~= "table" then
        return map
    end
    local valid_lookup = {}
    for _, key in ipairs(valid_keys) do
        if key then
            valid_lookup[tostring(key)] = true
        end
    end
    local changed = false
    for key in pairs(map) do
        if not valid_lookup[key] then
            map[key] = nil
            changed = true
        end
    end
    if changed then
        LocalReadState.save(feed_identifier, map)
    end
    return map
end

return LocalReadState
