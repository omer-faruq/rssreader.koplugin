local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local urlmod = require("socket.url")
local util = require("util")
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
            local ext = absolute_src:match("%.([%w]+)([%?#].*)?$")
            if ext then ext = ext:lower() end

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
    -- Phase 2: download. We're now in a regular Lua for-loop, so
    -- progress_callback may call Trapper:info() and yield safely
    -- back to UIManager between images. That's what gives the user
    -- a live "Downloading image X / N …" widget plus tap-to-cancel.
    -- ------------------------------------------------------------
    local total = #tasks
    local downloads = {}
    local renames = {}
    local cancelled = false

    for i, task in ipairs(tasks) do
        if progress_callback then
            local go_on = progress_callback(i, total)
            if go_on == false then
                cancelled = true
                break
            end
        end

        local headers = downloadFile(task.url, task.image_path)
        if headers then
            -- If we couldn't pick an extension from the URL but the
            -- server told us via Content-Type, rename the file
            -- accordingly. crengine sniffs image format by extension.
            if (not task.ext or task.ext == "") and headers["content-type"] then
                local resolved_ext = mimetype_to_extension[headers["content-type"]:lower()]
                if resolved_ext and resolved_ext ~= "" then
                    local new_filename = string.format("%s.%s", task.imgid, resolved_ext)
                    local new_path = string.format("%s/%s", asset_paths.images_dir, new_filename)
                    local ok, err = os.rename(task.image_path, new_path)
                    if ok then
                        local new_relative_src = string.format("%s/%s", asset_paths.relative_prefix, new_filename)
                        renames[task.relative_src] = new_relative_src
                        task.image_path = new_path
                        task.relative_src = new_relative_src
                    else
                        logger.warn("RSSReader", "Failed to rename image", task.image_path, err)
                    end
                end
            end

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
