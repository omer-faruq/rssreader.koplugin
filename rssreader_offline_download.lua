--[[
Offline Mode downloader: the options dialog and the runner that downloads
the selected feeds' stories into their offline folders.

The runner goes one network call at a time and hands control back to
UIManager between them (scheduleIn), like the List's Save All, so a tap on
the progress message still cancels. The manifest is saved after every
story, so a cancel or a crash keeps what was already downloaded.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local ffiutil = require("ffi/util")
local T = ffiutil.template

local OfflineStore = require("rssreader_offline_store")
local FeedFetcher = require("rssreader_feed_fetcher")
local utils = require("rssreader_menu_utils")

local OfflineDownload = {}

local LOG_TAG = "RSSReader Offline"
local MAX_PAGES_PER_FEED = 4
local STORIES_PER_FEED_CHOICES = { 5, 10, 20, 50 }
local RETENTION_CHOICES = {
    OfflineStore.RETENTION_DELETE_ALL,
    OfflineStore.RETENTION_DELETE_READ,
    OfflineStore.RETENTION_KEEP,
}

local CLIENT_GETTERS = {
    newsblur = "getNewsBlurClient",
    commafeed = "getCommaFeedClient",
    freshrss = "getFreshRSSClient",
    fever = "getFeverClient",
    miniflux = "getMinifluxClient",
    feedbin = "getFeedbinClient",
}

-- Heavy fields left out of the copy of a story kept in the manifest; the
-- article itself is in the downloaded file.
local DROPPED_STORY_FIELDS = {
    story_content = true,
    content = true,
    summary = true,
    description = true,
    images = true,
    enclosures = true,
}

local function nextChoice(choices, current)
    for index, value in ipairs(choices) do
        if value == current then
            return choices[(index % #choices) + 1]
        end
    end
    return choices[1]
end

local function retentionLabel(mode)
    if mode == OfflineStore.RETENTION_DELETE_ALL then
        return _("Delete all")
    elseif mode == OfflineStore.RETENTION_KEEP then
        return _("Keep all")
    end
    return _("Delete read only")
end

local function onOff(value)
    return value and _("on") or _("off")
end

function OfflineDownload.findAccount(builder, account_name)
    local accounts = builder.accounts and builder.accounts:getAccounts() or {}
    for _i, account in ipairs(accounts) do
        if account.name == account_name then
            return account
        end
    end
    return nil
end

function OfflineDownload.getClient(builder, account)
    local getter = CLIENT_GETTERS[account and account.type]
    if not getter or not builder.accounts or type(builder.accounts[getter]) ~= "function" then
        return nil, _("Account type is not supported.")
    end
    return builder.accounts[getter](builder.accounts, account)
end

-- The id and options a backend's fetchStories needs for a picked node. Per
-- feed unread filters exist only in some backends; the rest are filtered
-- after the fetch.
local function fetchRequest(entry, page, unread_only, continuation)
    local node = entry.node or {}
    local fetch_id = node.id or entry.feed_id
    local options = { page = page }
    local account_type = entry.account_type
    if account_type == "freshrss" then
        fetch_id = node.api_feed_id or fetch_id
        options.n = 50
        if node.is_special_feed then
            options.read_filter = node.read_filter_override or "unread_only"
            if node.id == "freshrss_today_unread" then
                options.published_since = utils.getStartOfTodayTimestamp() * 1000000
            end
        end
        if unread_only then
            options.read_filter = "unread_only"
        end
        options.continuation = continuation
    elseif account_type == "newsblur" then
        if unread_only then
            options.read_filter = "unread"
        end
    elseif account_type == "fever" then
        if unread_only or (node.is_virtual and node.virtual_type == "unread") then
            options.read_filter = "unread_only"
        end
    end
    return fetch_id, options
end

-- Up to `limit` stories of a remote feed that are not in the manifest yet,
-- newest first. Returns ok, stories_or_error.
local function collectRemoteStories(builder, entry, manifest, limit, unread_only, skip_keys)
    local account = OfflineDownload.findAccount(builder, entry.account)
    if not account then
        return false, _("Account not found.")
    end
    local client, err = OfflineDownload.getClient(builder, account)
    if not client then
        return false, err
    end

    -- A CommaFeed tag is fetched by name, which the client only knows once
    -- the tag's node has been made in this session.
    local tag_name = entry.node and entry.node.tag_name
    if tag_name and type(client.getTagNode) == "function" then
        client:getTagNode(tag_name)
    end

    local collected, seen = {}, {}
    local continuation
    for page = 1, MAX_PAGES_PER_FEED do
        local fetch_id, options = fetchRequest(entry, page, unread_only, continuation)
        local ok, data = client:fetchStories(fetch_id, options)
        if not ok then
            if page == 1 then
                return false, data
            end
            break
        end
        local stories = type(data) == "table" and data.stories or {}
        local new_on_page = 0
        for _i, story in ipairs(stories) do
            utils.normalizeStoryReadState(story)
            utils.normalizeStoryLink(story)
            local key = utils.storyUniqueKey(story)
            if key and not seen[key] then
                seen[key] = true
                new_on_page = new_on_page + 1
                if (not unread_only or utils.isUnread(story))
                        and not (unread_only and skip_keys and skip_keys[key])
                        and not OfflineStore.hasStory(manifest, key) then
                    story._rss_offline_key = key
                    table.insert(collected, story)
                    if #collected >= limit then
                        return true, collected
                    end
                end
            end
        end
        continuation = data.continuation
        -- No more pages, or a backend that ignores the page number (it
        -- returned only stories already seen).
        if not data.more_stories or new_on_page == 0 then
            break
        end
    end
    return true, collected
end

local function collectLocalStories(builder, entry, manifest, limit, unread_only, skip_keys)
    local url = entry.node and entry.node.url or entry.feed_id
    local ok, items = FeedFetcher.fetch(url)
    if not ok then
        return false, items
    end
    local read_map = unread_only and builder.local_read_state.load(url) or {}
    if type(read_map) ~= "table" then
        read_map = {}
    end
    local collected = {}
    for _i, story in ipairs(items or {}) do
        utils.normalizeStoryLink(story)
        local key = utils.storyUniqueKey(story)
        if key and not read_map[key] and not (unread_only and skip_keys and skip_keys[key])
                and not OfflineStore.hasStory(manifest, key) then
            story._rss_offline_key = key
            table.insert(collected, story)
            if #collected >= limit then
                break
            end
        end
    end
    return true, collected
end

local function storyFeedText(story)
    for _i, field in ipairs({ "story_content", "content", "summary", "description" }) do
        local value = story[field]
        if type(value) == "string" and value:match("%S") then
            return value
        end
    end
    return nil
end

-- The manifest's record of a downloaded story: where its file is, and the
-- story's own fields (minus the article) for the list and, later, for
-- telling the server it was read.
local function manifestEntry(story, path)
    local source = {}
    for key, value in pairs(story) do
        if not DROPPED_STORY_FIELDS[key] and type(key) == "string" and not key:match("^_rss_") then
            local value_type = type(value)
            if value_type == "string" or value_type == "number" or value_type == "boolean" then
                source[key] = value
            end
        end
    end
    -- utils.storySnippet reads this for the magazine view.
    local snippet = utils.storySnippet(story)
    if snippet then
        source.summary = snippet
    end
    return {
        key = story._rss_offline_key,
        title = utils.resolveStoryDocumentTitle(story),
        path = path,
        read = false,
        downloaded = os.time(),
        story = source,
    }
end

-- ────────────────────────────────────────────────────────────
-- Parallel article fetch
-- ────────────────────────────────────────────────────────────

-- Fetching an article is mostly waiting on the sanitizer or the site (3–9 s
-- each), so a feed's articles are fetched by a few forked workers at once,
-- like HtmlResources does with images. A worker only fetches the article
-- HTML (into <dir>/<index>.html); images and the EPUB stay in this process,
-- one story at a time, so worker counts never multiply on a small device.
-- Diffbot and FiveFilters-RapidAPI never run in workers
-- (utils.workerSafeSanitizers): a story that needs them is left without a
-- file, and the sequential pass runs the whole chain for it as before.
local PREFETCH_WORKERS = 3
local PREFETCH_POLL_INTERVAL = 0.5

local function prefetchDir()
    return require("datastorage"):getDataDir() .. "/cache/rssreader_offline_prefetch"
end

local function clearDir(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            os.remove(dir .. "/" .. name)
        end
    end
end

local function countFetched(dir)
    local count = 0
    pcall(function()
        for name in lfs.dir(dir) do
            if name:match("^%d+%.html$") then
                count = count + 1
            end
        end
    end)
    return count
end

-- Killed workers still have to be reaped; check back on them later.
local function reapLater(pids)
    if #pids == 0 then
        return
    end
    local function reap()
        for i = #pids, 1, -1 do
            if ffiutil.isSubProcessDone(pids[i]) then
                table.remove(pids, i)
            end
        end
        if #pids > 0 then
            UIManager:scheduleIn(5, reap)
        end
    end
    UIManager:scheduleIn(5, reap)
end

-- Returns the prefetched article of story `index`, or nil.
function OfflineDownload.readPrefetched(dir, index)
    if not dir then
        return nil
    end
    local file = io.open(dir .. "/" .. tostring(index) .. ".html", "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    if content and content ~= "" then
        return content
    end
    return nil
end

-- Calls on_done(dir) once every worker has finished, or on_done(nil) when
-- there is nothing to gain (one story, no fork) or the run was cancelled.
-- is_cancelled() is checked on every poll; on_progress(done, total) runs
-- whenever another article has landed.
function OfflineDownload.prefetchArticles(builder, stories, is_cancelled, on_progress, on_done)
    if #stories < 2 or type(ffiutil.runInSubProcess) ~= "function" then
        on_done(nil)
        return
    end
    local dir = prefetchDir()
    OfflineStore.ensureDir(dir)
    clearDir(dir)

    local worker_count = math.min(PREFETCH_WORKERS, #stories)
    local buckets = {}
    for i = 1, worker_count do
        buckets[i] = {}
    end
    -- Round-robin, so one slow site does not hold up a whole run of stories.
    for index, story in ipairs(stories) do
        table.insert(buckets[(index - 1) % worker_count + 1], { index = index, story = story })
    end

    local pids = {}
    for _i, bucket in ipairs(buckets) do
        local pid = ffiutil.runInSubProcess(function()
            for _j, task in ipairs(bucket) do
                utils.fetchStoryContent(task.story, builder, function(content)
                    if type(content) ~= "string" or content == "" then
                        return
                    end
                    -- Written under a temporary name and renamed, so the
                    -- parent never counts or reads a half-written file.
                    local final_path = dir .. "/" .. tostring(task.index) .. ".html"
                    local file = io.open(final_path .. ".part", "w")
                    if file then
                        file:write(content)
                        file:close()
                        os.rename(final_path .. ".part", final_path)
                    end
                end, { silent = true, worker = true })
            end
        end)
        if pid then
            table.insert(pids, pid)
        else
            -- No fork for this bucket: the sequential pass fetches its stories.
            logger.warn(LOG_TAG, "Could not fork article worker")
        end
    end
    if #pids == 0 then
        on_done(nil)
        return
    end

    local reported = -1
    local function poll()
        if is_cancelled() then
            for _i, pid in ipairs(pids) do
                ffiutil.terminateSubProcess(pid)
            end
            reapLater(pids)
            on_done(nil)
            return
        end
        for i = #pids, 1, -1 do
            if ffiutil.isSubProcessDone(pids[i]) then
                table.remove(pids, i)
            end
        end
        local done = countFetched(dir)
        if done ~= reported then
            reported = done
            on_progress(done, #stories)
        end
        if #pids == 0 then
            on_done(dir)
        else
            UIManager:scheduleIn(PREFETCH_POLL_INTERVAL, poll)
        end
    end
    UIManager:scheduleIn(PREFETCH_POLL_INTERVAL, poll)
end

-- ────────────────────────────────────────────────────────────
-- Runner
-- ────────────────────────────────────────────────────────────

-- options: the dialog's values (OfflineStore.LAST_RUN_DEFAULTS shape).
-- on_done(summary) runs after the last feed, also after a cancel.
function OfflineDownload.run(builder, selection, options, on_done)
    if #selection == 0 then
        UIManager:show(InfoMessage:new{ text = _("No feeds selected."), timeout = 3 })
        return
    end

    local summary = { stories = 0, failed = 0, feeds_failed = 0, cancelled = false }
    local cancelled = false
    local progress_widget

    local function closeProgress()
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
    end

    local function showProgress(text)
        closeProgress()
        progress_widget = InfoMessage:new{
            text = text .. "\n\n" .. _("Tap to cancel."),
            timeout = nil,
        }
        progress_widget.dismiss_callback = function()
            cancelled = true
        end
        UIManager:show(progress_widget)
        UIManager:forceRePaint()
    end

    local function finish()
        closeProgress()
        summary.cancelled = cancelled
        local text
        if cancelled then
            text = T(_("Download cancelled. %1 stories saved."), summary.stories)
        else
            text = T(_("Downloaded %1 stories."), summary.stories)
        end
        if summary.failed > 0 then
            text = text .. "\n" .. T(_("%1 stories could not be downloaded."), summary.failed)
        end
        if summary.feeds_failed > 0 then
            text = text .. "\n" .. T(_("%1 feeds could not be loaded."), summary.feeds_failed)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
        if options.wifi_off and not cancelled and Device:hasWifiToggle() then
            UIManager:scheduleIn(1, function()
                NetworkMgr:toggleWifiOff(nil, true)
            end)
        end
        if on_done then
            on_done(summary)
        end
    end

    local feed_index = 0
    local runFeed

    local function nextFeed()
        if cancelled then
            finish()
            return
        end
        feed_index = feed_index + 1
        if feed_index > #selection then
            finish()
            return
        end
        UIManager:scheduleIn(0.1, runFeed)
    end

    runFeed = function()
        local entry = selection[feed_index]
        local feed_label = entry.title or tostring(entry.feed_id)
        local header = T(_("Feed %1 / %2: %3"), feed_index, #selection, feed_label)
        showProgress(header .. "\n" .. _("Loading story list…"))

        local dir = OfflineStore.ensureDir(OfflineStore.feedDir(entry.account, entry.feed_id))
        local manifest = OfflineStore.loadManifest(dir) or OfflineStore.newManifest(entry)
        manifest.feed_title = entry.title or manifest.feed_title
        manifest.account_type = entry.account_type or manifest.account_type

        -- Retention is applied in memory first (so deleted stories can be
        -- downloaded again), but the old files only go once the feed has
        -- loaded: a feed that fails keeps what it had.
        local read_before = {}
        for _i, story_entry in ipairs(manifest.stories) do
            if story_entry.read and story_entry.key then
                read_before[story_entry.key] = true
            end
        end
        local removed_paths = OfflineStore.applyRetention(manifest, options.retention)

        -- Stories read here are not downloaded again, even while the server
        -- still has them unread (manual sync, or a sync that failed).
        local skip_keys = OfflineStore.readKeysInQueue(OfflineStore.loadPending(), entry.account)
        if options.unread_only then
            for key in pairs(read_before) do
                skip_keys[key] = true
            end
        end

        local collect = entry.account_type == "local" and collectLocalStories or collectRemoteStories
        local call_ok, ok, stories_or_err = pcall(collect, builder, entry, manifest,
            options.max_per_feed, options.unread_only, skip_keys)
        if not call_ok or not ok then
            logger.warn(LOG_TAG, "Cannot load", feed_label, call_ok and stories_or_err or ok)
            summary.feeds_failed = summary.feeds_failed + 1
            nextFeed()
            return
        end
        OfflineStore.removeFiles(removed_paths)
        OfflineStore.saveManifest(dir, manifest)
        local fetched = type(stories_or_err) == "table" and stories_or_err or {}

        local insert_at = 1
        local story_index = 0
        local prefetched_dir

        local function nextStory()
            if cancelled then
                finish()
                return
            end
            story_index = story_index + 1
            local story = fetched[story_index]
            if not story then
                manifest.updated = os.time()
                OfflineStore.saveManifest(dir, manifest)
                if prefetched_dir then
                    clearDir(prefetched_dir)
                end
                nextFeed()
                return
            end
            showProgress(header .. "\n" .. T(_("Story %1 / %2"), story_index, #fetched)
                .. "\n" .. utils.resolveStoryDocumentTitle(story))

            local raw_content
            if options.content == "feed" then
                raw_content = storyFeedText(story)
            else
                -- nil when no worker got it: the whole chain runs here.
                raw_content = OfflineDownload.readPrefetched(prefetched_dir, story_index)
            end
            utils.fetchStoryContent(story, builder, function(content, err, info)
                local path = content and utils.saveFetchedStory(story, content, info, dir, LOG_TAG)
                if path then
                    insert_at = OfflineStore.insertStory(manifest, manifestEntry(story, path), insert_at)
                    OfflineStore.saveManifest(dir, manifest)
                    summary.stories = summary.stories + 1
                else
                    logger.warn(LOG_TAG, "Story failed", story.title, err)
                    summary.failed = summary.failed + 1
                end
                UIManager:scheduleIn(0.1, nextStory)
            end, {
                silent = true,
                download_images = options.download_images,
                raw_content = raw_content,
            })
        end

        if options.content == "feed" then
            nextStory()
            return
        end
        showProgress(header .. "\n" .. _("Fetching articles…"))
        OfflineDownload.prefetchArticles(builder, fetched, function()
            return cancelled
        end, function(done, total)
            showProgress(header .. "\n" .. T(_("Fetching articles: %1 / %2"), done, total))
        end, function(result_dir)
            prefetched_dir = result_dir
            nextStory()
        end)
    end

    NetworkMgr:runWhenOnline(function()
        -- Read states from earlier offline reading go first (automatic mode),
        -- so "Only unread" does not download those stories again.
        require("rssreader_offline_sync").autoSync(builder, { on_done = nextFeed })
    end)
end

-- ────────────────────────────────────────────────────────────
-- Dialog
-- ────────────────────────────────────────────────────────────

-- Shows the options with the values used last time. Start saves them and
-- runs the download; closing the dialog keeps the old ones.
function OfflineDownload.showDialog(builder, on_done)
    local selection = OfflineStore.getSelection()
    if #selection == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds selected. Use 'Choose feeds…' first."),
            timeout = 3,
        })
        return
    end

    OfflineDownload._showDialogWith(builder, selection, OfflineStore.getLastRun(), on_done)
end

function OfflineDownload._showDialogWith(builder, selection, values, on_done)
    local dialog
    local function row(text, change)
        return {{
            text = text,
            align = "left",
            callback = function()
                change()
                UIManager:close(dialog)
                OfflineDownload._showDialogWith(builder, selection, values, on_done)
            end,
        }}
    end

    local buttons = {
        row(T(_("Stories per feed: %1"), values.max_per_feed), function()
            values.max_per_feed = nextChoice(STORIES_PER_FEED_CHOICES, values.max_per_feed)
        end),
        row(T(_("Only unread: %1"), onOff(values.unread_only)), function()
            values.unread_only = not values.unread_only
        end),
        row(T(_("Content: %1"), values.content == "feed" and _("feed text only (fast)") or _("full article")), function()
            values.content = values.content == "feed" and "full" or "feed"
        end),
        row(T(_("Download images: %1"), onOff(values.download_images)), function()
            values.download_images = not values.download_images
        end),
        row(T(_("Previous downloads: %1"), retentionLabel(values.retention)), function()
            values.retention = nextChoice(RETENTION_CHOICES, values.retention)
        end),
    }
    if Device:hasWifiToggle() then
        table.insert(buttons, row(T(_("Turn Wi-Fi off when done: %1"), onOff(values.wifi_off)), function()
            values.wifi_off = not values.wifi_off
        end))
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
        {
            text = _("Start"),
            is_enter_default = true,
            callback = function()
                UIManager:close(dialog)
                OfflineStore.saveLastRun(values)
                OfflineDownload.run(builder, selection, values, on_done)
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = T(_("Download %1 feeds for offline reading"), #selection),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return OfflineDownload
