--[[
Offline Mode read-state sync: sends the read/unread changes made in the
Offline list to the accounts' servers.

Automatic mode runs it when the device comes online, before a download, and
before a remote account's tree loads; manual mode only from the Offline
menu or the Dispatcher action. It runs in one go (no yields), so the queue
cannot change under it. Items that fail stay queued for the next run.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local OfflineStore = require("rssreader_offline_store")
local OfflineDownload = require("rssreader_offline_download")

local OfflineSync = {}

local LOG_TAG = "RSSReader Offline"
-- Above this many server requests, an automatic sync asks first.
local CONFIRM_REQUESTS = 20
local BATCH_SIZE = 100

local running = false

local function groupByAccount(queue, only_account)
    local groups, order = {}, {}
    for _i, item in ipairs(queue) do
        if not only_account or item.account == only_account then
            if not groups[item.account] then
                groups[item.account] = {}
                table.insert(order, item.account)
            end
            table.insert(groups[item.account], item)
        end
    end
    return groups, order
end

local function hasBatch(client)
    return type(client.markStoriesAsRead) == "function"
end

local function estimateRequests(client, items)
    local reads, unreads = 0, 0
    for _i, item in ipairs(items) do
        if item.read then
            reads = reads + 1
        else
            unreads = unreads + 1
        end
    end
    if hasBatch(client) then
        return math.ceil(reads / BATCH_SIZE) + unreads
    end
    return reads + unreads
end

-- pcall around a backend call that returns ok, err.
local function call(client, method, ...)
    local fn = client[method]
    if type(fn) ~= "function" then
        return false, "unsupported"
    end
    local call_ok, ok, err = pcall(fn, client, ...)
    if not call_ok then
        return false, ok
    end
    return ok and true or false, err
end

-- Sends one account's items; every item that reached the server goes into
-- the sent set.
local function sendAccount(client, items, sent)
    local reads, unreads = {}, {}
    for _i, item in ipairs(items) do
        table.insert(item.read and reads or unreads, item)
    end

    if #reads > 0 and hasBatch(client) then
        local stories = {}
        for _i, item in ipairs(reads) do
            table.insert(stories, item.story or {})
        end
        local ok, err = call(client, "markStoriesAsRead", stories)
        if ok then
            for _i, item in ipairs(reads) do
                sent[item] = true
            end
        else
            logger.warn(LOG_TAG, "Batch mark-read failed", err)
        end
    else
        for _i, item in ipairs(reads) do
            local ok, err = call(client, "markStoryAsRead", item.feed_id, item.story or {})
            if ok then
                sent[item] = true
            else
                logger.warn(LOG_TAG, "Mark-read failed", item.key, err)
            end
        end
    end

    for _i, item in ipairs(unreads) do
        local ok, err = call(client, "markStoryAsUnread", item.feed_id, item.story or {})
        if ok then
            sent[item] = true
        else
            logger.warn(LOG_TAG, "Mark-unread failed", item.key, err)
        end
    end
end

function OfflineSync.pendingCount(account_name)
    return OfflineStore.countPending(OfflineStore.loadPending(), account_name)
end

function OfflineSync.isAuto()
    return OfflineStore.getSyncMode() == OfflineStore.SYNC_AUTO
end

-- opts.account: only this account's items.
-- opts.confirm: ask first when it would take many requests (automatic runs).
-- opts.quiet: no message when there was nothing to send.
-- opts.on_done(result): always called once, also when nothing ran.
function OfflineSync.run(builder, opts)
    opts = opts or {}
    local finished = false
    local function done(result)
        if finished then return end
        finished = true
        if opts.on_done then
            opts.on_done(result or { sent = 0, failed = 0 })
        end
    end

    if running then
        done()
        return
    end

    local queue = OfflineStore.loadPending()
    local groups, order = groupByAccount(queue, opts.account)
    local plans, total_items, total_requests = {}, 0, 0
    for _i, account_name in ipairs(order) do
        local account = OfflineDownload.findAccount(builder, account_name)
        local client = account and OfflineDownload.getClient(builder, account)
        if client then
            local items = groups[account_name]
            table.insert(plans, { client = client, items = items })
            total_items = total_items + #items
            total_requests = total_requests + estimateRequests(client, items)
        else
            -- The account is gone or inactive: keep its items, they cost nothing.
            logger.info(LOG_TAG, "Skipping read states of unavailable account", account_name)
        end
    end

    if total_items == 0 then
        if not opts.quiet then
            UIManager:show(InfoMessage:new{ text = _("No read states to sync."), timeout = 2 })
        end
        done()
        return
    end

    local function go()
        running = true
        local progress = InfoMessage:new{
            text = T(_("Syncing %1 read states…"), total_items),
            timeout = nil,
        }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local sent = {}
        for _i, plan in ipairs(plans) do
            sendAccount(plan.client, plan.items, sent)
        end
        local sent_items = {}
        for item in pairs(sent) do
            table.insert(sent_items, item)
        end
        local sent_count = #sent_items
        OfflineStore.savePending(OfflineStore.removeSent(OfflineStore.loadPending(), sent_items))
        running = false
        UIManager:close(progress)

        local failed = total_items - sent_count
        local text = T(_("%1 read states synced."), sent_count)
        if failed > 0 then
            text = text .. "\n" .. T(_("%1 could not be synced; they will be tried again next time."), failed)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = failed > 0 and 4 or 2 })
        done({ sent = sent_count, failed = failed })
    end

    NetworkMgr:runWhenOnline(function()
        if opts.confirm and total_requests > CONFIRM_REQUESTS then
            -- Counts as running while the question is up, so another
            -- trigger (say, NetworkConnected) does not ask a second time.
            running = true
            UIManager:show(ConfirmBox:new{
                text = T(_("Send %1 read states from offline reading to the server now?\nThis takes about %2 requests."),
                    total_items, total_requests),
                ok_text = _("Sync"),
                cancel_text = _("Later"),
                ok_callback = go,
                cancel_callback = function()
                    running = false
                    done()
                end,
            })
        else
            go()
        end
    end)
end

-- The automatic run: nothing at all in manual mode or with an empty queue.
function OfflineSync.autoSync(builder, opts)
    opts = opts or {}
    if not OfflineSync.isAuto() or OfflineSync.pendingCount(opts.account) == 0 then
        if opts.on_done then
            opts.on_done({ sent = 0, failed = 0 })
        end
        return
    end
    OfflineSync.run(builder, {
        account = opts.account,
        confirm = true,
        quiet = true,
        on_done = opts.on_done,
    })
end

-- True when opening this account should wait for its read states first.
function OfflineSync.shouldSyncBeforeOpen(account_name)
    return OfflineSync.isAuto() and OfflineSync.pendingCount(account_name) > 0
end

return OfflineSync
