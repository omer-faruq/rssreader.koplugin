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

local function downloadFile(url, target_path)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
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

function HtmlResources.downloadAndRewrite(html, page_url, asset_paths)
    if type(html) ~= "string" or html == "" then
        return html, { downloads = {} }
    end
    if not asset_paths then
        return html, { downloads = {} }
    end

    if not resetAssetDirectories(asset_paths) then
        return html, { downloads = {} }
    end

    local seen = {}
    local downloads = {}
    local imagenum = 1

    local function processTag(img_tag)
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

        if seen[absolute_src] then
            return replaceSrcAttribute(img_tag, seen[absolute_src])
        end

        local ext = absolute_src:match("%.([%w]+)([%?#].*)?$")
        if ext then
            ext = ext:lower()
        end

        local imgid = string.format("img%05d", imagenum)
        imagenum = imagenum + 1

        local filename = ext and ext ~= "" and string.format("%s.%s", imgid, ext) or imgid
        local image_path = string.format("%s/%s", asset_paths.images_dir, filename)

        local headers = downloadFile(absolute_src, image_path)
        if not headers then
            return img_tag
        end

        if (not ext or ext == "") and headers["content-type"] then
            local resolved_ext = mimetype_to_extension[headers["content-type"]:lower()]
            if resolved_ext and resolved_ext ~= "" then
                local renamed = string.format("%s.%s", imgid, resolved_ext)
                local new_path = string.format("%s/%s", asset_paths.images_dir, renamed)
                local ok, err = os.rename(image_path, new_path)
                if ok then
                    filename = renamed
                    image_path = new_path
                else
                    logger.warn("RSSReader", "Failed to rename image", image_path, err)
                end
            end
        end

        local relative_src = string.format("%s/%s", asset_paths.relative_prefix, filename)
        seen[absolute_src] = relative_src
        downloads[#downloads + 1] = {
            url = absolute_src,
            path = image_path,
            relative_src = relative_src,
        }

        local updated_tag = replaceSrcAttribute(img_tag, relative_src)
        if original_attribute and original_attribute ~= "src" then
            updated_tag = replaceAttributeValue(updated_tag, original_attribute, relative_src)
        end
        return updated_tag
    end

    local rewritten = html:gsub("(<%s*[Ii][Mm][Gg][^>]*>)", processTag)
    return rewritten, {
        downloads = downloads,
        assets_root = asset_paths.assets_root,
        images_dir = asset_paths.images_dir,
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
