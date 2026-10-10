--[[
Offline Mode storage: the feed selection, the download dialog's last values,
and one folder per downloaded feed holding its story files and a
manifest.json describing them.

    <DataDir>/rssreader_offline/<account>__<hash>/manifest.json
    <DataDir>/rssreader_offline/<account>__<hash>/<story files>

The manifest/selection logic (merge, retention, counts, toggles) is plain Lua
with no KOReader dependency, so it can be tested in a bare LuaJIT. Everything
that touches the disk or the settings requires its modules lazily.
]]

local OfflineStore = {}

local SETTINGS_KEY = "rssreader_offline"
local ROOT_DIR_NAME = "rssreader_offline"
local MANIFEST_NAME = "manifest.json"

OfflineStore.RETENTION_DELETE_ALL = "delete_all"
OfflineStore.RETENTION_DELETE_READ = "delete_read"
OfflineStore.RETENTION_KEEP = "keep"

-- Values the download dialog opens with on its very first use; after that
-- it opens with whatever was used last (see getLastRun/saveLastRun).
OfflineStore.LAST_RUN_DEFAULTS = {
    max_per_feed = 20,
    unread_only = true,
    content = "full", -- "full" | "feed"
    download_images = true,
    retention = OfflineStore.RETENTION_DELETE_READ,
    wifi_off = false,
}

-- ────────────────────────────────────────────────────────────
-- Pure logic
-- ────────────────────────────────────────────────────────────

local function sameFeed(entry, account_name, feed_id)
    return entry.account == account_name and tostring(entry.feed_id) == tostring(feed_id)
end

function OfflineStore.selectionIndex(selection, account_name, feed_id)
    for index, entry in ipairs(selection or {}) do
        if sameFeed(entry, account_name, feed_id) then
            return index
        end
    end
    return nil
end

function OfflineStore.isSelected(selection, account_name, feed_id)
    return OfflineStore.selectionIndex(selection, account_name, feed_id) ~= nil
end

-- Adds the entry if absent, removes it if present. Returns true when the
-- feed is selected afterwards.
function OfflineStore.toggleSelection(selection, entry)
    local index = OfflineStore.selectionIndex(selection, entry.account, entry.feed_id)
    if index then
        table.remove(selection, index)
        return false
    end
    table.insert(selection, entry)
    return true
end

-- How many selected feeds of this account have their id in the id set.
function OfflineStore.countSelectedIn(selection, account_name, feed_ids)
    local count = 0
    for _i, entry in ipairs(selection or {}) do
        if entry.account == account_name and feed_ids[tostring(entry.feed_id)] then
            count = count + 1
        end
    end
    return count
end

function OfflineStore.countSelectedForAccount(selection, account_name)
    local count = 0
    for _i, entry in ipairs(selection or {}) do
        if entry.account == account_name then
            count = count + 1
        end
    end
    return count
end

function OfflineStore.newManifest(selection_entry)
    return {
        account = selection_entry.account,
        account_type = selection_entry.account_type,
        feed_id = tostring(selection_entry.feed_id),
        feed_title = selection_entry.title,
        updated = nil,
        stories = {},
    }
end

function OfflineStore.hasStory(manifest, key)
    for _i, story in ipairs(manifest.stories or {}) do
        if story.key == key then
            return true
        end
    end
    return false
end

-- Drops the stories the retention mode says go, and returns the file paths
-- they leave behind (for the caller to delete).
function OfflineStore.applyRetention(manifest, mode)
    local removed_paths = {}
    if mode == OfflineStore.RETENTION_KEEP then
        return removed_paths
    end
    local kept = {}
    for _i, story in ipairs(manifest.stories or {}) do
        local drop = mode == OfflineStore.RETENTION_DELETE_ALL
            or (mode == OfflineStore.RETENTION_DELETE_READ and story.read)
        if drop then
            if story.path then
                table.insert(removed_paths, story.path)
            end
        else
            table.insert(kept, story)
        end
    end
    manifest.stories = kept
    return removed_paths
end

-- A download inserts its stories above the ones already there, in the order
-- it fetched them (newest first), so the list reads newest to oldest.
-- insert_at is where the current run's next story goes.
function OfflineStore.insertStory(manifest, story, insert_at)
    manifest.stories = manifest.stories or {}
    insert_at = math.min(math.max(insert_at or 1, 1), #manifest.stories + 1)
    table.insert(manifest.stories, insert_at, story)
    return insert_at + 1
end

function OfflineStore.unreadCount(manifest)
    local count = 0
    for _i, story in ipairs(manifest and manifest.stories or {}) do
        if not story.read then
            count = count + 1
        end
    end
    return count
end

function OfflineStore.findStory(manifest, key)
    for index, story in ipairs(manifest and manifest.stories or {}) do
        if story.key == key then
            return story, index
        end
    end
    return nil
end

-- Folder name for a feed: readable account prefix + a hash of the full
-- identity, so two feeds never share a folder and odd ids stay valid names.
function OfflineStore.feedDirName(account_name, feed_id, hash_fn)
    local prefix = tostring(account_name or "account"):gsub("[^%w]", "_"):sub(1, 24)
    local digest = hash_fn(tostring(account_name) .. "\0" .. tostring(feed_id))
    return prefix .. "__" .. digest:sub(1, 12)
end

-- Read states waiting to reach the server. One entry per (account, story):
-- a later change replaces the earlier one, so read → unread → read sends a
-- single "read". Returns the queue.
function OfflineStore.queueReadState(queue, item)
    queue = queue or {}
    for index, existing in ipairs(queue) do
        if existing.account == item.account and existing.key == item.key then
            table.remove(queue, index)
            break
        end
    end
    table.insert(queue, item)
    return queue
end

-- Set of the story keys of this account waiting to be sent as read.
function OfflineStore.readKeysInQueue(queue, account_name)
    local keys = {}
    for _i, item in ipairs(queue or {}) do
        if item.account == account_name and item.read and item.key then
            keys[item.key] = true
        end
    end
    return keys
end

function OfflineStore.countPending(queue, account_name)
    local count = 0
    for _i, item in ipairs(queue or {}) do
        if not account_name or item.account == account_name then
            count = count + 1
        end
    end
    return count
end

-- Drops from a freshly loaded queue the items a sync sent. An item queued
-- again since then with the other state (read ↔ unread) stays.
function OfflineStore.removeSent(queue, sent_items)
    local sent = {}
    for _i, item in ipairs(sent_items or {}) do
        sent[tostring(item.account) .. "\0" .. tostring(item.key) .. "\0" .. tostring(item.read)] = true
    end
    local kept = {}
    for _i, item in ipairs(queue or {}) do
        if not sent[tostring(item.account) .. "\0" .. tostring(item.key) .. "\0" .. tostring(item.read)] then
            table.insert(kept, item)
        end
    end
    return kept
end

-- Fills the gaps in a saved last-run table from the defaults; also drops
-- values from older versions that are no longer valid.
function OfflineStore.mergeLastRun(saved)
    local result = {}
    for key, value in pairs(OfflineStore.LAST_RUN_DEFAULTS) do
        result[key] = value
    end
    if type(saved) ~= "table" then
        return result
    end
    for key, default in pairs(OfflineStore.LAST_RUN_DEFAULTS) do
        if type(saved[key]) == type(default) then
            result[key] = saved[key]
        end
    end
    return result
end

-- ────────────────────────────────────────────────────────────
-- Settings
-- ────────────────────────────────────────────────────────────

local function readSettings()
    local stored = G_reader_settings and G_reader_settings:readSetting(SETTINGS_KEY)
    if type(stored) ~= "table" then
        stored = {}
    end
    return stored
end

local function writeSettings(settings)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    end
end

function OfflineStore.getSelection()
    local selection = readSettings().selection
    if type(selection) ~= "table" then
        return {}
    end
    return selection
end

function OfflineStore.saveSelection(selection)
    local settings = readSettings()
    settings.selection = selection
    writeSettings(settings)
end

function OfflineStore.getLastRun()
    return OfflineStore.mergeLastRun(readSettings().last_run)
end

function OfflineStore.saveLastRun(last_run)
    local settings = readSettings()
    settings.last_run = OfflineStore.mergeLastRun(last_run)
    writeSettings(settings)
end

OfflineStore.SYNC_AUTO = "auto"
OfflineStore.SYNC_MANUAL = "manual"

function OfflineStore.getSyncMode()
    local mode = readSettings().readstate_sync
    if mode == OfflineStore.SYNC_MANUAL then
        return mode
    end
    return OfflineStore.SYNC_AUTO
end

function OfflineStore.setSyncMode(mode)
    local settings = readSettings()
    settings.readstate_sync = mode
    writeSettings(settings)
end

-- ────────────────────────────────────────────────────────────
-- Disk
-- ────────────────────────────────────────────────────────────

function OfflineStore.rootDir()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/" .. ROOT_DIR_NAME
end

function OfflineStore.feedDir(account_name, feed_id)
    local sha2 = require("ffi/sha2")
    return OfflineStore.rootDir() .. "/" .. OfflineStore.feedDirName(account_name, feed_id, sha2.md5)
end

function OfflineStore.ensureDir(dir)
    require("util").makePath(dir)
    return dir
end

function OfflineStore.loadManifest(dir)
    local file = io.open(dir .. "/" .. MANIFEST_NAME, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    if not content or content == "" then
        return nil
    end
    local json = require("common/json")
    local ok, manifest = pcall(json.decode, content)
    if not ok or type(manifest) ~= "table" then
        require("logger").warn("RSSReader Offline", "Unreadable manifest in", dir)
        return nil
    end
    manifest.stories = type(manifest.stories) == "table" and manifest.stories or {}
    manifest.dir = dir
    return manifest
end

-- Written to a temporary file first and renamed over the old one, so a
-- crash mid-write never leaves a truncated manifest behind.
function OfflineStore.saveManifest(dir, manifest)
    local json = require("common/json")
    local dir_field = manifest.dir
    manifest.dir = nil
    local ok, encoded = pcall(json.encode, manifest)
    manifest.dir = dir_field
    if not ok then
        require("logger").warn("RSSReader Offline", "Cannot encode manifest", encoded)
        return false
    end
    local path = dir .. "/" .. MANIFEST_NAME
    local tmp_path = path .. ".tmp"
    local file = io.open(tmp_path, "w")
    if not file then
        return false
    end
    file:write(encoded)
    file:close()
    os.remove(path)
    return os.rename(tmp_path, path) and true or false
end

local function pendingPath()
    return OfflineStore.rootDir() .. "/pending_read_states.json"
end

function OfflineStore.loadPending()
    local file = io.open(pendingPath(), "r")
    if not file then
        return {}
    end
    local content = file:read("*all")
    file:close()
    local ok, queue = pcall(require("common/json").decode, content or "")
    if not ok or type(queue) ~= "table" then
        return {}
    end
    return queue
end

function OfflineStore.savePending(queue)
    OfflineStore.ensureDir(OfflineStore.rootDir())
    if #queue == 0 then
        os.remove(pendingPath())
        return true
    end
    local ok, encoded = pcall(require("common/json").encode, queue)
    if not ok then
        return false
    end
    local tmp_path = pendingPath() .. ".tmp"
    local file = io.open(tmp_path, "w")
    if not file then
        return false
    end
    file:write(encoded)
    file:close()
    os.remove(pendingPath())
    return os.rename(tmp_path, pendingPath()) and true or false
end

function OfflineStore.removeFiles(paths)
    for _i, path in ipairs(paths or {}) do
        os.remove(path)
    end
end

-- Every feed that has a manifest, sorted by account then title.
function OfflineStore.listFeeds()
    local lfs = require("libs/libkoreader-lfs")
    local root = OfflineStore.rootDir()
    local feeds = {}
    if lfs.attributes(root, "mode") ~= "directory" then
        return feeds
    end
    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." then
            local dir = root .. "/" .. name
            if lfs.attributes(dir, "mode") == "directory" then
                local manifest = OfflineStore.loadManifest(dir)
                if manifest then
                    table.insert(feeds, manifest)
                end
            end
        end
    end
    table.sort(feeds, function(a, b)
        local a_account, b_account = tostring(a.account or ""), tostring(b.account or "")
        if a_account ~= b_account then
            return a_account < b_account
        end
        return tostring(a.feed_title or ""):lower() < tostring(b.feed_title or ""):lower()
    end)
    return feeds
end

-- Total unread across all downloaded feeds (for the account list row).
function OfflineStore.totalUnread()
    local total = 0
    for _i, manifest in ipairs(OfflineStore.listFeeds()) do
        total = total + OfflineStore.unreadCount(manifest)
    end
    return total
end

-- Removes a feed's folder with everything in it.
function OfflineStore.deleteFeedDir(dir)
    local lfs = require("libs/libkoreader-lfs")
    if type(dir) ~= "string" or dir == "" or lfs.attributes(dir, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            os.remove(dir .. "/" .. name)
        end
    end
    lfs.rmdir(dir)
end

return OfflineStore
