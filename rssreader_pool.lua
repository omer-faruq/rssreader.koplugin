local json = require("common/json")
local util = require("util")
local DataStorage = require("datastorage")
local logger = require("logger")
local sha2 = require("ffi/sha2")

local Pool = {}

local POOL_FILE = DataStorage:getDataDir() .. "/data/rssreader_pool.json"
local MAX_POOL_SIZE = 500

local function ensureDataDir()
    local dir = DataStorage:getDataDir() .. "/data"
    util.makePath(dir)
    return dir
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

local function storyKey(story)
    if type(story) ~= "table" then
        return nil
    end
    local key = story.story_hash
        or story.hash
        or story.guid
        or story.story_id
        or story.id
        or story.permalink
        or story.href
        or story.link
        or story.url
    if not key then
        local pieces = {}
        local title = story.story_title or story.title or story.permalink or story.href or story.link
        if title and title ~= "" then
            table.insert(pieces, title)
        end
        local suffix = story.date
            or story.timestamp
            or story.created_on_time
            or story.updated
            or story.published
            or story.pubDate
            or story.modified
            or story.dc_date
            or story.last_modified
            or story.insertedDate
            or story.created
            or story.guid
            or ""
        table.insert(pieces, tostring(suffix))
        local content_fragment = story.story_content or story.content or story.summary or story.description
        if type(content_fragment) == "string" and content_fragment ~= "" then
            table.insert(pieces, content_fragment:sub(1, 512))
        end
        if #pieces > 0 then
            key = string.format("pool:%s", sha2.md5(table.concat(pieces, "::")))
        end
    end
    if key == nil then
        return nil
    end
    return tostring(key)
end

local function serializeStory(story)
    local fields = {
        "story_title", "title", "story_content", "content", "summary", "description",
        "permalink", "href", "link", "url", "story_permalink",
        "story_hash", "hash", "guid", "story_id", "id",
        "author", "creator", "feed_title", "feed_id",
        "date", "timestamp", "created_on_time", "updated", "published", "pubDate",
        "read_status", "read", "story_read",
        "preview_image", "primary_image", "story_image", "image", "thumbnail",
        "media_thumbnail", "media_content", "image_urls",
        "_rss_is_read", "_rss_marked_read",
        "_from_virtual_feed", "_is_from_virtual_feed",
    }
    local result = {}
    for _, field in ipairs(fields) do
        if story[field] ~= nil then
            result[field] = story[field]
        end
    end
    return result
end

function Pool.load()
    ensureDataDir()
    local content = readFile(POOL_FILE)
    local data = decodeJson(content)
    if not data or type(data.stories) ~= "table" then
        return { stories = {}, keys = {} }
    end
    local keys = {}
    for _, story in ipairs(data.stories) do
        local key = storyKey(story)
        if key then
            keys[key] = true
        end
    end
    return { stories = data.stories, keys = keys }
end

function Pool.save(pool_data)
    ensureDataDir()
    local payload = { stories = pool_data.stories or {} }
    local encoded = json.encode(payload)
    if not writeFile(POOL_FILE, encoded) then
        logger.warn("RSSReader Pool", "Failed to write pool file")
        return false
    end
    return true
end

function Pool.addStory(story)
    if type(story) ~= "table" then
        return false, "invalid_story"
    end
    local pool = Pool.load()
    local key = storyKey(story)
    if key and pool.keys[key] then
        return false, "duplicate"
    end
    if #pool.stories >= MAX_POOL_SIZE then
        return false, "pool_full"
    end
    local serialized = serializeStory(story)
    serialized._pool_read = false
    serialized._pool_added = os.time()
    serialized._pool_key = key
    table.insert(pool.stories, serialized)
    if key then
        pool.keys[key] = true
    end
    Pool.save(pool)
    return true
end

function Pool.removeStory(index)
    local pool = Pool.load()
    if index < 1 or index > #pool.stories then
        return false
    end
    local removed = table.remove(pool.stories, index)
    if removed and removed._pool_key then
        pool.keys[removed._pool_key] = nil
    end
    Pool.save(pool)
    return true
end

function Pool.removeStoryByKey(key)
    if not key then
        return false
    end
    local pool = Pool.load()
    for i = #pool.stories, 1, -1 do
        local story = pool.stories[i]
        local sk = story._pool_key or storyKey(story)
        if sk == key then
            table.remove(pool.stories, i)
            pool.keys[key] = nil
            Pool.save(pool)
            return true
        end
    end
    return false
end

function Pool.clear()
    local pool = { stories = {}, keys = {} }
    Pool.save(pool)
    return true
end

function Pool.getStories()
    local pool = Pool.load()
    return pool.stories
end

function Pool.count()
    local pool = Pool.load()
    return #pool.stories
end

function Pool.markRead(index)
    local pool = Pool.load()
    if index < 1 or index > #pool.stories then
        return false
    end
    pool.stories[index]._pool_read = true
    pool.stories[index]._rss_is_read = true
    Pool.save(pool)
    return true
end

function Pool.markUnread(index)
    local pool = Pool.load()
    if index < 1 or index > #pool.stories then
        return false
    end
    pool.stories[index]._pool_read = false
    pool.stories[index]._rss_is_read = false
    pool.stories[index]._rss_marked_read = nil
    Pool.save(pool)
    return true
end

function Pool.isRead(index)
    local pool = Pool.load()
    if index < 1 or index > #pool.stories then
        return false
    end
    return pool.stories[index]._pool_read == true
end

function Pool.storyKey(story)
    return storyKey(story)
end

function Pool.updateStory(index, story)
    local pool = Pool.load()
    if index < 1 or index > #pool.stories then
        return false
    end
    pool.stories[index] = story
    Pool.save(pool)
    return true
end

return Pool
