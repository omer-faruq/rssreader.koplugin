local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local urlmod = require("socket.url")
local util = require("util")
local ffiutil = require("ffi/util")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local DataStorage = require("datastorage")

local HtmlResources = {}

local mimetype_to_extension = {
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/svg+xml"] = "svg",
    ["image/webp"] = "webp",
    ["image/avif"] = "avif",
    ["image/bmp"] = "bmp",
}

-- Extensions we accept from the URL itself. Anything else (".php", a dotted
-- path segment, no extension at all) is left to the Content-Type header:
-- crengine sniffs image format by extension, so a wrong one is worse than
-- none.
local known_image_extensions = {
    jpg = true, jpeg = true, png = true, gif = true, svg = true,
    webp = true, avif = true, bmp = true, ico = true, tif = true, tiff = true,
}

local function extensionFromUrl(absolute_src)
    -- Cut the query and fragment off first: "pic.png?w=600" is a PNG.
    local path_only = absolute_src:match("^([^%?#]*)")
    local ext = path_only and path_only:match("%.(%w+)$")
    if not ext then
        return nil
    end
    ext = ext:lower()
    if not known_image_extensions[ext] then
        return nil
    end
    return ext
end

local function matchAttribute(tag, attribute)
    local pattern = attribute:gsub("%-", "%%-")
    return tag:match(pattern .. '%s*=%s*"([^"]*)"')
        or tag:match(pattern .. "%s*=%s*'([^']*)'")
end

local function parsePixelLength(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local trimmed = value:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil
    end
    local number_part, unit_part = trimmed:match("^([%d%.]+)%s*([%a%%]*)$")
    if not number_part then
        return nil
    end
    if unit_part and unit_part ~= "" then
        unit_part = unit_part:lower()
        if unit_part ~= "px" then
            return nil
        end
    end
    return tonumber(number_part)
end

local function parseStylePixelLength(style, property)
    if type(style) ~= "string" or style == "" then
        return nil
    end
    local lowered = style:lower()
    local value = lowered:match(property .. "%s*:%s*([^;]+)")
    if value then
        return parsePixelLength(value)
    end
    return nil
end

local function isTinyPixelImage(tag)
    local width_attr = matchAttribute(tag, "width")
    local height_attr = matchAttribute(tag, "height")
    local style_attr = matchAttribute(tag, "style")

    local width = parsePixelLength(width_attr) or parseStylePixelLength(style_attr, "width")
    local height = parsePixelLength(height_attr) or parseStylePixelLength(style_attr, "height")

    if width and width <= 1 and height and height <= 1 then
        return true
    end

    return false
end

local function ensureDirectory(path)
    local ok, err = util.makePath(path)
    if not ok then
        logger.warn("RSSReader", "Failed to create directory", path, err)
        return false
    end
    return true
end

function HtmlResources.ensureBaseDirectory()
    local base_dir = DataStorage:getDataDir() .. "/cache/rssreader"
    if ensureDirectory(base_dir) then
        return base_dir
    end
    return nil
end

local function wipeDirectoryContents(path)
    local attr = lfs.attributes(path, "mode")
    if attr ~= "directory" then
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full = path .. "/" .. entry
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                wipeDirectoryContents(full)
                local ok, err = lfs.rmdir(full)
                if not ok then
                    logger.warn("RSSReader", "Failed to remove directory", full, err)
                end
            else
                local ok, err = os.remove(full)
                if not ok then
                    logger.warn("RSSReader", "Failed to remove file", full, err)
                end
            end
        end
    end
end

local function resetAssetDirectories(asset_paths)
    if not asset_paths or not asset_paths.assets_root then
        return false
    end
    if lfs.attributes(asset_paths.assets_root, "mode") == "directory" then
        wipeDirectoryContents(asset_paths.assets_root)
    end
    return ensureDirectory(asset_paths.images_dir)
end

function HtmlResources.prepareAssetPaths(base_dir, base_name)
    if type(base_dir) ~= "string" or base_dir == "" then
        return nil
    end
    if type(base_name) ~= "string" or base_name == "" then
        base_name = tostring(os.time())
    end
    base_name = base_name:gsub("[^%w%._-]", "_")
    local assets_root = string.format("%s/assets/%s", base_dir, base_name)
    return {
        base_dir = base_dir,
        base_name = base_name,
        assets_root = assets_root,
        images_dir = assets_root .. "/images",
        relative_prefix = string.format("assets/%s/images", base_name),
    }
end

local function replaceAttributeValue(tag, attribute, new_value)
    local attr_pattern = attribute:gsub("%-", "%%-")
    local updated, count = tag:gsub(attr_pattern .. '%s*=%s*"([^"]*)"', attribute .. '="' .. new_value .. '"', 1)
    if count == 0 then
        updated = tag:gsub(attr_pattern .. "%s*=%s*'([^']*)'", attribute .. "='" .. new_value .. "'", 1)
    end
    return updated
end

local function replaceSrcAttribute(tag, new_src)
    local function replacer(prefix, attr, _, suffix)
        return prefix .. attr .. new_src .. suffix
    end

    local replaced, count = tag:gsub('([%s<])([Ss][Rr][Cc]%s*=%s*")([^"]*)(")', replacer, 1)
    if count == 0 then
        replaced, count = tag:gsub("([%s<])([Ss][Rr][Cc]%s*=%s*')([^']*)(')", replacer, 1)
    end
    if count == 0 then
        replaced = tag:gsub("(<%s*[Ii][Mm][Gg])", "%1 src=\"" .. new_src .. "\"", 1)
    end
    return replaced
end

-- Per-image download timeouts. We deliberately use values shorter than
-- socketutil.LARGE_BLOCK_TIMEOUT (10s) / LARGE_TOTAL_TIMEOUT (30s): a single
-- slow image must not stall the whole article download for tens of seconds.
local IMAGE_BLOCK_TIMEOUT = 5
local IMAGE_TOTAL_TIMEOUT = 10

-- Image downloads are latency-bound: nearly all the time of a single request
-- is spent waiting for DNS, the TCP/TLS handshake and the remote server, so
-- fetching N images one after the other costs roughly N times the latency of
-- one. We fan the work out to a few forked worker processes instead (see
-- downloadTasksInParallel). The image bytes never travel through a pipe:
-- every worker writes straight to its own file in images_dir, and the parent
-- picks the results up from the filesystem.
local DEFAULT_WORKERS = 4
local MAX_WORKERS = 8
local POLL_INTERVAL = 0.25 -- seconds between "are the workers done?" checks

local function downloadFile(url, target_path)
    local sink = {}
    socketutil:set_timeout(IMAGE_BLOCK_TIMEOUT, IMAGE_TOTAL_TIMEOUT)
    local ok, status_code, headers, status_text = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
        logger.info("RSSReader", "Image download failed", url, status_text or status_code)
        return nil
    end

    local directory = target_path:match("^(.*)/")
    if directory and directory ~= "" then
        ensureDirectory(directory)
    end

    local file = io.open(target_path, "wb")
    if not file then
        logger.warn("RSSReader", "Unable to open image path for writing", target_path)
        return nil
    end
    file:write(table.concat(sink))
    file:close()

    return headers or {}
end

local function extensionFromContentType(content_type)
    if type(content_type) ~= "string" then
        return nil
    end
    -- "image/jpeg; charset=binary" -> "image/jpeg"
    local mimetype = content_type:lower():match("^%s*([^;%s]+)")
    if not mimetype then
        return nil
    end
    return mimetype_to_extension[mimetype]
end

-- Download one task to a temporary ".part" file and only then move it to its
-- final name. The detour buys us two things: the extension may only be known
-- from the Content-Type header (crengine sniffs image format by extension),
-- and a half-written file is never visible under the name the HTML points at
-- -- which is what lets the parent count finished downloads by listing the
-- directory while the workers are still running.
-- Returns the final file name (not the path) and its full path, or nil.
local function performDownload(task, images_dir)
    local part_path = task.image_path .. ".part"
    local headers = downloadFile(task.url, part_path)
    if not headers then
        os.remove(part_path)
        return nil
    end

    local ext = task.ext
    if not ext or ext == "" then
        ext = extensionFromContentType(headers["content-type"])
    end
    local filename = (ext and ext ~= "")
        and string.format("%s.%s", task.imgid, ext)
        or task.imgid
    local final_path = string.format("%s/%s", images_dir, filename)

    local ok, err = os.rename(part_path, final_path)
    if not ok then
        logger.warn("RSSReader", "Failed to rename image", part_path, err)
        os.remove(part_path)
        return nil
    end
    return filename, final_path
end

local function listFinishedFiles(images_dir)
    local by_imgid = {}
    local count = 0
    local ok = pcall(function()
        for entry in lfs.dir(images_dir) do
            if entry ~= "." and entry ~= ".." and not entry:find("%.part$") then
                local imgid = entry:match("^(img%d+)")
                if imgid then
                    by_imgid[imgid] = entry
                    count = count + 1
                end
            end
        end
    end)
    if not ok then
        return {}, 0
    end
    return by_imgid, count
end

-- kill()ed children still have to be reaped. Hand the leftovers to UIManager
-- (the same approach as Trapper:dismissableRunInSubprocess) instead of
-- blocking the UI here waiting for them.
local function collectWorkersLater(pids)
    if #pids == 0 then
        return
    end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or not UIManager then
        return
    end
    local pending = {}
    for _, pid in ipairs(pids) do
        table.insert(pending, pid)
    end
    local collect
    collect = function()
        for i = #pending, 1, -1 do
            if ffiutil.isSubProcessDone(pending[i]) then
                table.remove(pending, i)
            end
        end
        if #pending > 0 then
            UIManager:scheduleIn(5, collect)
        end
    end
    UIManager:scheduleIn(5, collect)
end

-- Fan the downloads out to `worker_count` forked processes.
-- Returns ran, cancelled: ran == false means forking is unavailable and the
-- caller has to fall back to the sequential loop.
local function downloadTasksInParallel(tasks, images_dir, worker_count, options)
    if type(ffiutil.runInSubProcess) ~= "function" then
        return false, false
    end

    local total = #tasks
    local progress_callback = options.progress_callback
    local yield_callback = options.yield_callback

    -- Round-robin, so a worker that draws a slow host does not also get all
    -- the images that happen to sit next to it in the document.
    local buckets = {}
    for i = 1, worker_count do
        buckets[i] = {}
    end
    for i = 1, total do
        local bucket = buckets[(i - 1) % worker_count + 1]
        bucket[#bucket + 1] = tasks[i]
    end

    local pids = {}
    for _, bucket in ipairs(buckets) do
        if #bucket > 0 then
            local pid = ffiutil.runInSubProcess(function()
                for _, task in ipairs(bucket) do
                    performDownload(task, images_dir)
                end
            end)
            if pid then
                pids[#pids + 1] = pid
            else
                -- fork() failed: this bucket is on us, right here.
                logger.warn("RSSReader", "Could not fork image download worker")
                for _, task in ipairs(bucket) do
                    performDownload(task, images_dir)
                end
            end
        end
    end

    local cancelled = false
    local reported = -1
    while #pids > 0 do
        for i = #pids, 1, -1 do
            if ffiutil.isSubProcessDone(pids[i]) then
                table.remove(pids, i)
            end
        end

        local _, done = listFinishedFiles(images_dir)
        if progress_callback and done ~= reported then
            reported = done
            -- Keep the caller's "image X / N" wording meaningful: report the
            -- next image being worked on, not the last one that landed.
            if progress_callback(math.min(done + 1, total), total) == false then
                cancelled = true
            end
        end
        if cancelled or #pids == 0 then
            break
        end

        if yield_callback then
            if yield_callback(POLL_INTERVAL) == false then
                cancelled = true
                break
            end
        else
            socket.sleep(POLL_INTERVAL)
        end
    end

    if cancelled then
        for _, pid in ipairs(pids) do
            ffiutil.terminateSubProcess(pid)
        end
        collectWorkersLater(pids)
    end

    return true, cancelled
end

local function resolveUrl(src, base_url)
    if not src or src == "" then
        return nil
    end
    if src:find("^data:") then
        return nil
    end
    if src:find("^[%w][%w%+%-.]*:") then
        return src
    end
    if not base_url or base_url == "" then
        return nil
    end
    return urlmod.absolute(base_url, src)
end

function HtmlResources.downloadAndRewrite(html, page_url, asset_paths, options)
    if type(html) ~= "string" or html == "" then
        return html, { downloads = {} }
    end
    if not asset_paths then
        return html, { downloads = {} }
    end

    if not resetAssetDirectories(asset_paths) then
        return html, { downloads = {} }
    end

    options = options or {}
    local progress_callback = options.progress_callback

    local seen = {}      -- absolute_src -> relative_src (for in-document de-dup)
    local tasks = {}     -- ordered list of unique downloads to perform later
    local imagenum = 1

    -- ------------------------------------------------------------
    -- Phase 1: scan & rewrite. Pure Lua; no I/O, no coroutine yields.
    -- This is safe to run inside a `string.gsub` replacement: gsub is
    -- a C function and yielding from a Lua callback nested inside C
    -- silently fails under our Trapper:wrap coroutine, so we MUST NOT
    -- call progress_callback (which calls Trapper:info -> yield) here.
    -- ------------------------------------------------------------
    local function scanTag(img_tag)
        if isTinyPixelImage(img_tag) then
            return ""
        end

        local original_src
        local original_attribute

        local function consider(value, attribute)
            if value and value ~= "" then
                original_src = value
                original_attribute = attribute
                return true
            end
            return false
        end

        consider(img_tag:match('[%s<][Ss][Rr][Cc]%s*=%s*"([^"]*)"'), "src")
        if not original_src then
            consider(img_tag:match("[%s<][Ss][Rr][Cc]%s*=%s*'([^']*)'"), "src")
        end

        if not original_src then
            local data_attributes = { "data-src", "data-original", "data-lazy-src" }
            for _, attribute in ipairs(data_attributes) do
                local pattern_base = attribute:gsub("%-", "%%-")
                if consider(img_tag:match(pattern_base .. '%s*=%s*"([^"]*)"'), attribute) then
                    break
                end
                if consider(img_tag:match(pattern_base .. "%s*=%s*'([^']*)'"), attribute) then
                    break
                end
            end
        end

        if not original_src then
            return img_tag
        end

        local absolute_src = resolveUrl(original_src, page_url)
        if not absolute_src then
            return img_tag
        end

        local relative_src = seen[absolute_src]
        if not relative_src then
            local ext = extensionFromUrl(absolute_src)

            local imgid = string.format("img%05d", imagenum)
            imagenum = imagenum + 1

            local filename = ext and ext ~= "" and string.format("%s.%s", imgid, ext) or imgid
            local image_path = string.format("%s/%s", asset_paths.images_dir, filename)
            relative_src = string.format("%s/%s", asset_paths.relative_prefix, filename)

            seen[absolute_src] = relative_src
            tasks[#tasks + 1] = {
                url = absolute_src,
                imgid = imgid,
                ext = ext,
                image_path = image_path,
                relative_src = relative_src,
            }
        end

        local updated_tag = replaceSrcAttribute(img_tag, relative_src)
        if original_attribute and original_attribute ~= "src" then
            updated_tag = replaceAttributeValue(updated_tag, original_attribute, relative_src)
        end
        return updated_tag
    end

    local rewritten = html:gsub("(<%s*[Ii][Mm][Gg][^>]*>)", scanTag)

    -- ------------------------------------------------------------
    -- Phase 2: download. Either in a few forked workers (the default), or,
    -- when forking is unavailable or a single worker was requested, in a
    -- plain Lua for-loop. Either way we are out of `string.gsub`, so
    -- progress_callback may call Trapper:info() and yield safely back to
    -- UIManager between images. That's what gives the user a live
    -- "Downloading image X / N ..." widget plus tap-to-cancel.
    -- ------------------------------------------------------------
    local total = #tasks
    local downloads = {}
    local renames = {}
    local cancelled = false
    local finished = {} -- task -> final file name

    local worker_count = tonumber(options.workers) or DEFAULT_WORKERS
    worker_count = math.max(1, math.min(MAX_WORKERS, math.floor(worker_count)))
    worker_count = math.min(worker_count, total)

    local ran_in_parallel = false
    if worker_count > 1 then
        local ran, was_cancelled = downloadTasksInParallel(tasks, asset_paths.images_dir, worker_count, options)
        if ran then
            ran_in_parallel = true
            cancelled = was_cancelled
            local by_imgid = listFinishedFiles(asset_paths.images_dir)
            for _, task in ipairs(tasks) do
                finished[task] = by_imgid[task.imgid]
            end
        end
    end

    if not ran_in_parallel then
        for i, task in ipairs(tasks) do
            if progress_callback then
                local go_on = progress_callback(i, total)
                if go_on == false then
                    cancelled = true
                    break
                end
            end
            finished[task] = performDownload(task, asset_paths.images_dir)
        end
    end

    -- The name a file ended up with may differ from the one phase 1 wrote
    -- into the HTML (when the extension could only come from Content-Type),
    -- so collect those for phase 3.
    for _, task in ipairs(tasks) do
        local filename = finished[task]
        if filename then
            local relative_src = string.format("%s/%s", asset_paths.relative_prefix, filename)
            if relative_src ~= task.relative_src then
                renames[task.relative_src] = relative_src
                task.relative_src = relative_src
            end
            task.image_path = string.format("%s/%s", asset_paths.images_dir, filename)
            downloads[#downloads + 1] = {
                url = task.url,
                path = task.image_path,
                relative_src = task.relative_src,
            }
        end
    end

    -- ------------------------------------------------------------
    -- Phase 3: patch HTML for any extension-from-headers renames.
    -- Plain literal-string substitution; no callback, no yields.
    -- ------------------------------------------------------------
    if next(renames) then
        for old_src, new_src in pairs(renames) do
            local escaped_old = old_src:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            local escaped_new = new_src:gsub("%%", "%%%%")
            rewritten = rewritten:gsub(escaped_old, escaped_new)
        end
    end

    return rewritten, {
        downloads = downloads,
        assets_root = asset_paths.assets_root,
        images_dir = asset_paths.images_dir,
        cancelled = cancelled,
    }
end

function HtmlResources.cleanupAssets(assets_root)
    if type(assets_root) ~= "string" or assets_root == "" then
        return
    end
    wipeDirectoryContents(assets_root)
    local ok, err = lfs.rmdir(assets_root)
    if not ok then
        logger.debug("RSSReader", "Unable to remove asset directory (may be fine)", assets_root, err)
    end
end

return HtmlResources
