local util = require("util")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local qrencode = require("ffi/qrencode")
local http = require("socket.http")
local urlmod = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local FileManager = require("apps/filemanager/filemanager")
local HtmlSanitizer = require("rssreader_html_sanitizer")
local HtmlResources = require("rssreader_html_resources")
local FiveFiltersSanitizer = require("sanitizers/rssreader_sanitizer_fivefilters")
local DiffbotSanitizer = require("sanitizers/rssreader_sanitizer_diffbot")
local InstaparserSanitizer = require("sanitizers/rssreader_sanitizer_instaparser")
local sha2 = require("ffi/sha2")

local utils = {}

local function loadEpubDownloadBackend()
    local candidates = {
        "rssreader_epubdownloadbackend",
        "plugins.rssreader.koplugin.rssreader_epubdownloadbackend",
        "epubdownloadbackend",
        "plugins.newsdownloader.koplugin.epubdownloadbackend",
    }
    for _, module_name in ipairs(candidates) do
        local ok, backend = pcall(require, module_name)
        if ok and backend then
            logger.dbg("RSSReader", "Loaded EPUB backend", module_name)
            return backend
        end
    end
    logger.info("RSSReader", "EpubDownloadBackend not available; EPUB export disabled")
    return nil
end

utils.EpubDownloadBackend = loadEpubDownloadBackend()

local ENTITY_REPLACEMENTS = {
    ["&#8216;"] = "'",
    ["&#8217;"] = "'",
}

local MAGAZINE_SNIPPET_LENGTH = 400

function utils.getStartOfTodayTimestamp()
    local now_t = os.date("*t")
    local start_of_day_t = {
        year = now_t.year,
        month = now_t.month,
        day = now_t.day,
        hour = 0,
        min = 0,
        sec = 0,
        isdst = now_t.isdst -- Respect local timezone
    }
    return os.time(start_of_day_t)
end

function utils.generateQRCodeSVG(url, size)
    size = size or 150
    local ok, grid = qrencode.qrcode(url)
    if not ok or not grid then
        logger.warn("Failed to generate QR code for:", url)
        return nil
    end
    
    local grid_size = #grid
    local sq_size = math.floor(size / grid_size)
    local actual_size = sq_size * grid_size
    
    local svg_parts = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', 
            actual_size, actual_size, actual_size, actual_size),
        string.format('<rect width="%d" height="%d" fill="white"/>', actual_size, actual_size)
    }
    
    for x, col in ipairs(grid) do
        for y, lgn in ipairs(col) do
            if lgn > 0 then
                table.insert(svg_parts, string.format(
                    '<rect x="%d" y="%d" width="%d" height="%d" fill="black"/>',
                    (x - 1) * sq_size, (y - 1) * sq_size, sq_size, sq_size
                ))
            end
        end
    end
    
    table.insert(svg_parts, '</svg>')
    return table.concat(svg_parts)
end

function utils.createURLFooterHTML(url)
    if type(url) ~= "string" or url == "" then
        return ""
    end
    
    local qr_svg = utils.generateQRCodeSVG(url, 150)
    local footer_parts = {
        '<div style="margin-top: 2em; padding-top: 1em; border-top: 2px solid #ccc;">',
        '<p style="font-size: 0.9em; color: #666; margin: 0.5em 0;">',
        '<strong>Source:</strong> <a href="' .. util.htmlEscape(url) .. '">' .. util.htmlEscape(url) .. '</a>',
        '</p>'
    }
    
    if qr_svg then
        table.insert(footer_parts, '<div style="margin-top: 0.5em;">')
        table.insert(footer_parts, qr_svg)
        table.insert(footer_parts, '</div>')
    end
    
    table.insert(footer_parts, '</div>')
    return table.concat(footer_parts)
end

function utils.replaceRightSingleQuoteEntities(text)
    if type(text) ~= "string" then
        return text
    end
    local replaced = text:gsub("&#%d+;", function(entity)
        return ENTITY_REPLACEMENTS[entity] or entity
    end)
    return replaced
end

function utils.findNextIndex(stories, start_index, predicate)
    if not stories or #stories == 0 then
        return nil
    end

    local total = #stories
    for offset = 1, total do
        local candidate = ((start_index + offset - 1) % total) + 1
        local story = stories[candidate]
        if predicate(story) then
            return candidate
        end
    end
    return nil
end

function utils.ensureMenuCloseHook(menu_instance)
    if not menu_instance or menu_instance._rss_close_wrapped then
        return
    end
    local original_close = menu_instance.close_callback
    menu_instance.close_callback = function(...)
        menu_instance._rss_feed_node = nil
        if original_close then
            original_close(...)
        end
    end
    menu_instance._rss_close_wrapped = true
end

function utils.parseReadFlag(value)
    local value_type = type(value)
    if value_type == "boolean" then
        return value
    elseif value_type == "number" then
        if value == 0 then
            return false
        elseif value == 1 then
            return true
        end
    elseif value_type == "string" then
        local lowered = value:lower()
        if lowered == "0" or lowered == "false" then
            return false
        elseif lowered == "1" or lowered == "true" then
            return true
        end
    end
    return nil
end

function utils.normalizeStoryReadState(story)
    if type(story) ~= "table" then
        return
    end
    local read_state = story._rss_is_read
    for _, key in ipairs({ "read_status", "read", "story_read" }) do
        local parsed = utils.parseReadFlag(story[key])
        if parsed ~= nil then
            story[key] = parsed
            if read_state == nil then
                read_state = parsed
            end
        end
    end
    if read_state ~= nil then
        story._rss_is_read = read_state
    end
end

function utils.setStoryReadState(story, is_read)
    if type(story) ~= "table" then
        return
    end
    story.read_status = is_read and true or false
    story.read = is_read and true or false
    story.story_read = is_read and true or false
    story._rss_is_read = is_read and true or false
    if is_read then
        story._rss_marked_read = true
    else
        story._rss_marked_read = nil
    end
    utils.normalizeStoryReadState(story)
end

function utils.storyReadState(story)
    if type(story) ~= "table" then
        return nil
    end
    utils.normalizeStoryReadState(story)
    if story._rss_is_read ~= nil then
        return story._rss_is_read
    end
    if story.read_status ~= nil then
        return story.read_status and true or false
    end
    if story.read ~= nil then
        return story.read and true or false
    end
    if story.story_read ~= nil then
        return story.story_read and true or false
    end
    return nil
end

function utils.isUnread(story)
    if type(story) ~= "table" then
        return false
    end
    local read_state = utils.storyReadState(story)
    if read_state ~= nil then
        return not read_state
    end
    return true
end

function utils.formatStoryDate(story, include_time)
    if type(story) ~= "table" then
        return nil
    end
    local timestamp = story.timestamp or story.created_on_time or story.date
    if not timestamp then
        return nil
    end
    if type(timestamp) == "string" then
        local numeric = tonumber(timestamp)
        if numeric then
            timestamp = numeric
        else
            return timestamp
        end
    end
    if type(timestamp) ~= "number" then
        return nil
    end
    if timestamp > 10000 then
        timestamp = timestamp / 1000
    end
    local format_string = include_time and "%Y-%m-%d %H:%M" or "%Y-%m-%d"
    local ok, formatted = pcall(os.date, format_string, timestamp)
    if ok then
        return formatted
    end
    return nil
end

function utils.decoratedStoryTitle(story, decorate)
    local title = utils.replaceRightSingleQuoteEntities(story.story_title or story.title or _("Untitled story"))
    if decorate and utils.isUnread(story) then
        title = string.format("%s • %s", _("NEW"), title)
    end

    if (story._from_virtual_feed or story._is_from_virtual_feed) and story.feed_title and story.feed_title ~= "" then
        local feed_prefix = story.feed_title
        if #feed_prefix > 5 then
            feed_prefix = feed_prefix:sub(1, 5)
        end
        title = "[" .. feed_prefix .. "]" .. " • " .. title
    end  

    local date_label = utils.formatStoryDate(story)
    if date_label then
        return string.format("%s %s %s", title, " • ", date_label)
    end
    return title
end

function utils.storySnippet(story, max_chars)
    max_chars = max_chars or MAGAZINE_SNIPPET_LENGTH
    local raw_html = story.story_content or story.content or story.summary
    if type(raw_html) ~= "string" or raw_html == "" then
        return nil
    end
    local plain = util.htmlToPlainText(raw_html)
    if not plain or plain == "" then
        return nil
    end
    plain = plain:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if plain == "" then
        return nil
    end
    if #plain > max_chars then
        plain = plain:sub(1, max_chars) .. "…"
    end
    return utils.replaceRightSingleQuoteEntities(plain)
end

function utils.buildStoryEntryText(story, decorate, view_mode)
    local title = utils.decoratedStoryTitle(story, decorate)
    if view_mode == "magazine" or view_mode == "cards" then
        local snippet = utils.storySnippet(story)
        if snippet then
            return title .. "\n  •  " .. snippet
        end
    end
    return title
end

function utils.resolveStoryFeedId(context, story)
    if context and context.feed_id then
        return context.feed_id
    end
    if type(story) ~= "table" then
        return nil
    end
    local feed_identifier = story.story_feed_id or story.feed_id or story.storyFeedId or story.feedId
    if feed_identifier ~= nil then
        return tostring(feed_identifier)
    end
    return nil
end

function utils.storyUniqueKey(story)
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
            key = string.format("local:%s", sha2.md5(table.concat(pieces, "::")))
        end
    end
    if key == nil then
        return nil
    end
    return tostring(key)
end

function utils.appendUniqueStory(storage, key_map, story)
    if type(storage) ~= "table" or type(key_map) ~= "table" or type(story) ~= "table" then
        return false
    end
    local key = utils.storyUniqueKey(story)
    if key and key_map[key] then
        return false
    end
    utils.normalizeStoryReadState(story)
    table.insert(storage, story)
    if key then
        key_map[key] = true
    end
    return true
end

function utils.persistFeedState(menu_instance, feed_node)
    if not menu_instance or not feed_node then
        return
    end
    local reader = menu_instance._rss_reader
    if type(reader) ~= "table" or type(reader.updateFeedState) ~= "function" then
        return
    end
    local stories_copy = feed_node._rss_stories and util.tableDeepCopy(feed_node._rss_stories) or {}
    local story_keys_copy = {}
    for key, value in pairs(feed_node._rss_story_keys or {}) do
        if value then
            story_keys_copy[key] = true
        end
    end
    reader:updateFeedState(feed_node._account_name or "unknown", feed_node.id, {
        menu_page = menu_instance.page,
        current_page = feed_node._rss_page or 0,
        has_more = feed_node._rss_has_more or false,
        stories = stories_copy,
        story_keys = story_keys_copy,
    })
    if type(reader.saveNavigationState) == "function" then
        reader:saveNavigationState()
    end
end

function utils.trackMenuPage(menu_instance, feed_node)
    if not menu_instance then
        return
    end
    menu_instance._rss_reader = menu_instance._rss_reader or (feed_node and feed_node._rss_reader)
    if feed_node then
        feed_node._rss_menu_page = menu_instance.page
    end
    if menu_instance._rss_page_tracking then
        return
    end
    local original_onGotoPage = menu_instance.onGotoPage
    if type(original_onGotoPage) ~= "function" then
        return
    end
    menu_instance.onGotoPage = function(self, page)
        local result = original_onGotoPage(self, page)
        if feed_node then
            feed_node._rss_menu_page = self.page
            utils.persistFeedState(self, feed_node)
        end
        local reader = self._rss_reader
        if reader and type(reader.saveNavigationState) == "function" then
            reader:saveNavigationState()
        end
        return result
    end
    menu_instance._rss_page_tracking = true
    utils.persistFeedState(menu_instance, feed_node)
end

function utils.restoreMenuPage(menu_instance, feed_node, target_page)
    if not menu_instance then
        return
    end
    utils.trackMenuPage(menu_instance, feed_node)
    if type(target_page) ~= "number" then
        return
    end
    local reader = menu_instance._rss_reader
    local function clampPage(page_value)
        if type(page_value) ~= "number" then
            return nil
        end
        if page_value < 1 then
            page_value = 1
        end
        local page_count = menu_instance.page_num
        if type(page_count) == "number" and page_count > 0 and page_value > page_count then
            page_value = page_count
        end
        return page_value
    end

    local desired_page = clampPage(target_page)
    local function applyPage(page_value)
        if not page_value or not menu_instance then
            return
        end
        if menu_instance.page ~= page_value then
            menu_instance:onGotoPage(page_value)
        elseif feed_node then
            feed_node._rss_menu_page = page_value
        end
        if reader and feed_node and type(reader.updateFeedState) == "function" then
            reader:updateFeedState(feed_node._account_name or "unknown", feed_node.id, {
                menu_page = page_value,
            })
        end
    end

    applyPage(desired_page)

    local function scheduleApplyPage(page_value, remaining_attempts)
        if not page_value or remaining_attempts <= 0 then
            return
        end
        UIManager:nextTick(function()
            if not menu_instance or type(menu_instance.page) ~= "number" then
                return
            end
            applyPage(page_value)
            scheduleApplyPage(page_value, remaining_attempts - 1)
        end)
    end

    scheduleApplyPage(desired_page, 3)
end

function utils.buildCacheDirectory()
    local base_dir = DataStorage:getDataDir() .. "/cache/rssreader"
    util.makePath(base_dir)
    return base_dir
end

function utils.ensureActiveDirectory(target_dir)
    if type(target_dir) ~= "string" or target_dir == "" then
        return
    end
    if lfs.attributes(target_dir, "mode") ~= "directory" then
        return
    end
    if FileManager and FileManager.instance and FileManager.instance.file_chooser and type(FileManager.instance.file_chooser.changeToPath) == "function" then
        FileManager.instance.file_chooser:changeToPath(target_dir)
    end
    if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
        G_reader_settings:saveSetting("lastdir", target_dir)
    end
end

function utils.pickActiveDirectory(cache_dir)
    local home_dir = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home_dir) == "string" and home_dir ~= "" and util.directoryExists(home_dir) then
        return home_dir
    end
    local device_home = Device and Device.home_dir
    if type(device_home) == "string" and device_home ~= "" and util.directoryExists(device_home) then
        return device_home
    end
    if type(cache_dir) == "string" and cache_dir ~= "" and util.directoryExists(cache_dir) then
        return cache_dir
    end
end

function utils.getFeatureFlag(builder, key)
    if not builder or not builder.accounts or not builder.accounts.config then
        return nil
    end
    return util.tableGetValue(builder.accounts.config, "features", key)
end

function utils.shouldDownloadImages(builder, sanitized_successful)
    local key = sanitized_successful and "download_images_when_sanitize_successful" or "download_images_when_sanitize_unsuccessful"
    local flag = utils.getFeatureFlag(builder, key)
    return flag == true
end

function utils.collectActiveSanitizers(builder)
    if not builder or not builder.accounts or not builder.accounts.config then
        return nil
    end
    local configured = builder.accounts.config.sanitizers
    if type(configured) ~= "table" then
        return nil
    end
    local ordered = {}
    for _, entry in ipairs(configured) do
        if type(entry) == "table" and entry.type and entry.active ~= false then
            ordered[#ordered + 1] = entry
        end
    end
    table.sort(ordered, function(a, b)
        local ao = type(a.order) == "number" and a.order or math.huge
        local bo = type(b.order) == "number" and b.order or math.huge
        if ao == bo then
            return tostring(a.type) < tostring(b.type)
        end
        return ao < bo
    end)
    if #ordered == 0 then
        return nil
    end
    return ordered
end

function utils.writeStoryHtmlFile(html, filepath, title, url)
    if type(html) == "string" and html ~= "" then
        html = HtmlSanitizer.disableFontSizeDeclarations(html)
    end
    local file = io.open(filepath, "w")
    if not file then
        return false
    end
    file:write("<html><head><meta charset=\"utf-8\">")
    if type(title) == "string" and title ~= "" then
        local escaped_title = util.htmlEscape(title)
        if escaped_title and escaped_title ~= "" then
            file:write("<title>" .. escaped_title .. "</title>")
        end
    end
    file:write("</head><body>")
    file:write(html or "")
    
    local footer = utils.createURLFooterHTML(url)
    if footer ~= "" then
        file:write(footer)
    end
    
    file:write("</body></html>")
    file:close()
    return true
end

function utils.wrapHtmlForEpub(html, title)
    if type(html) ~= "string" or html == "" then
        return nil
    end
    local escaped_title = util.htmlEscape(title or "")
    if not escaped_title or escaped_title == "" then
        escaped_title = "Untitled"
    end
    return table.concat({
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
        "<!DOCTYPE html>",
        "<html xmlns=\"http://www.w3.org/1999/xhtml\">",
        "<head><meta charset=\"utf-8\"/>",
        "<title>" .. escaped_title .. "</title>",
        "</head><body>",
        html,
        "</body></html>",
    })
end

function utils.normalizeStoryLink(story)
    if type(story) ~= "table" then
        return
    end
    if type(story.permalink) == "string" and story.permalink ~= "" then
        return
    end

    local candidates = {
        story.story_permalink,
        story.story_permalink,
        story.original_url,
        story.url,
        story.href,
        story.link,
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "string" and candidate ~= "" then
            story.permalink = candidate
            return
        end
    end
end

function utils.safeFilenameFromStory(story)
    if not story then
        return string.format("story_%d.html", os.time())
    end
    local title = story.story_title or story.title or story.permalink or "story"
    title = title:gsub("[^%w%._-]", "_")
    if title == "" then
        title = "story"
    end
    return string.format("%s_%d.html", title:sub(1, 64), os.time())
end

function utils.resolveStoryDocumentTitle(story)
    if type(story) ~= "table" then
        return _("Untitled story")
    end
    local title = story.story_title or story.title or story.permalink or _("Untitled story")
    if type(title) ~= "string" or title == "" then
        title = _("Untitled story")
    end
    return utils.replaceRightSingleQuoteEntities(title)
end

function utils.rewriteRelativeResourceUrls(html, page_url)
    if type(html) ~= "string" or html == "" then
        return html
    end
    if type(page_url) ~= "string" or page_url == "" then
        return html
    end

    local base = page_url
    local base_href = html:match("<[Bb][Aa][Ss][Ee]%s+[^>]-[Hh][Rr][Ee][Ff]%s*=%s*['\"]%s*(.-)%s*['\"]")
    if base_href and base_href ~= "" then
        local parsed_base = urlmod.parse(base_href)
        if parsed_base and parsed_base.scheme then
            base = urlmod.build(parsed_base)
        else
            base = urlmod.absolute(page_url, base_href)
        end
    end

    local function isRelativeTarget(value)
        if not value or value == "" then
            return false
        end
        local first = value:sub(1, 1)
        if first == "#" or first == "?" then
            return false
        end
        if value:match("^[%w][%w%+%-.]*:") then
            return false
        end
        return true
    end

    local function absolutizeAttribute(pattern)
        html = html:gsub(pattern, function(prefix, value, suffix)
            if isRelativeTarget(value) then
                local resolved = urlmod.absolute(base, value)
                return prefix .. resolved .. suffix
            end
            return prefix .. value .. suffix
        end)
    end

    absolutizeAttribute("(<%s*[^>]-[Hh][Rr][Ee][Ff]%s*=%s*['\"])%s*(.-)%s*([\"'])")
    absolutizeAttribute("(<%s*[^>]-[Ss][Rr][Cc]%s*=%s*['\"])%s*(.-)%s*([\"'])")

    return html
end

function utils.shouldUseFiveFilters(builder)
    if not builder or not builder.accounts or not builder.accounts.config then
        return false
    end
    local flag = util.tableGetValue(builder.accounts.config, "features", "use_fivefilters_on_save_open")
    if flag == nil then
        return false
    end
    return flag and true or false
end

function utils.fetchViaHttp(link, on_complete)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, status_code, _, status_text = http.request{
        url = link,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader RSSReader",
        },
    }
    socketutil:reset_timeout()

    if not ok or tostring(status_code):sub(1, 1) ~= "2" then
        logger.warn("RSSReader", "Failed to download story", link, status_text or status_code)
        if on_complete then
            on_complete(nil, status_text or status_code or "download_failed")
        end
        return
    end

    local content = table.concat(sink)
    if not content or content == "" then
        if on_complete then
            on_complete(nil, "empty_content")
        end
        return
    end

    if on_complete then
        on_complete(content)
    end
end

function utils.fetchStoryContent(story, builder, on_complete, options)
    local link = story and (story.permalink or story.href or story.link)
    if not link or link == "" then
        if on_complete then
            on_complete(nil, "missing_link")
        end
        return
    end

    local silent = options and options.silent
    if not silent then
        UIManager:show(InfoMessage:new{ text = _("Downloading article..."), timeout = 1 })
    end

    NetworkMgr:runWhenOnline(function()
        UIManager:nextTick(function()
            local configured_sanitizers = utils.collectActiveSanitizers(builder)
            if (not configured_sanitizers or #configured_sanitizers == 0) and utils.shouldUseFiveFilters(builder) then
                configured_sanitizers = { { type = "fivefilters" } }
            end

            local function finalizeContent(raw_html, sanitized_successful)
                if not raw_html then
                    if on_complete then
                        on_complete(nil, "empty_content")
                    end
                    return
                end

                raw_html = utils.rewriteRelativeResourceUrls(raw_html, link)
                raw_html = HtmlSanitizer.disableFontSizeDeclarations(raw_html)

                local title = utils.resolveStoryDocumentTitle(story)
                if type(raw_html) == "string" and raw_html ~= "" and type(title) == "string" and title ~= "" then
                    local heading = string.format("<h3>%s</h3>", util.htmlEscape(title))
                    raw_html = heading .. raw_html
                end

                local html_for_epub = raw_html

                local download_info
                local images_requested = utils.shouldDownloadImages(builder, sanitized_successful)
                if images_requested then
                    local asset_base_dir = options and options.asset_base_dir or utils.buildCacheDirectory()
                    local asset_base_name = options and options.asset_base_name or string.format("story_%d", os.time())
                    local asset_paths = HtmlResources.prepareAssetPaths(asset_base_dir, asset_base_name)
                    if asset_paths then
                        local rewritten, assets = HtmlResources.downloadAndRewrite(raw_html, link, asset_paths)
                        if rewritten then
                            raw_html = rewritten
                        end
                        download_info = download_info or {}
                        download_info.assets = assets
                        download_info.assets_root = assets and assets.assets_root
                        download_info.asset_paths = asset_paths
                    else
                        logger.warn("RSSReader", "Failed to prepare asset directories for images")
                    end
                end

                local epub_document = utils.wrapHtmlForEpub(html_for_epub, utils.resolveStoryDocumentTitle(story))

                download_info = download_info or {}
                download_info.sanitized_successful = sanitized_successful and true or false
                download_info.images_requested = images_requested and true or false
                download_info.html_for_epub = epub_document or html_for_epub
                download_info.original_url = link

                if on_complete then
                    on_complete(raw_html, nil, download_info)
                end
            end

            local function handleOriginalDownload()
                utils.fetchViaHttp(link, function(content, err)
                    if not content then
                        if on_complete then
                            on_complete(nil, err)
                        end
                        return
                    end
                    finalizeContent(content, false)
                end)
            end

            if not configured_sanitizers or #configured_sanitizers == 0 then
                handleOriginalDownload()
                return
            end

            local function processSanitizer(index)
                local sanitizer = configured_sanitizers[index]
                if not sanitizer then
                    handleOriginalDownload()
                    return
                end

                local sanitizer_type = sanitizer.type and sanitizer.type:lower() or ""
                if sanitizer_type == "fivefilters" then
                    local fivefilters_url = FiveFiltersSanitizer.buildUrl(link)
                    if not fivefilters_url then
                        processSanitizer(index + 1)
                        return
                    end

                    utils.fetchViaHttp(fivefilters_url, function(content, err)
                        if not content then
                            processSanitizer(index + 1)
                            return
                        end

                        if not FiveFiltersSanitizer.hasLikelyXmlStructure(content) then
                            processSanitizer(index + 1)
                            return
                        end

                        if FiveFiltersSanitizer.detectBlocked(content) then
                            processSanitizer(index + 1)
                            return
                        end

                        local fivefilters_html = FiveFiltersSanitizer.rewriteHtml(FiveFiltersSanitizer.extractHtml(content))
                        if not fivefilters_html or not FiveFiltersSanitizer.contentIsMeaningful(fivefilters_html) then
                            processSanitizer(index + 1)
                            return
                        end

                        finalizeContent(fivefilters_html, true)
                    end)
                elseif sanitizer_type == "diffbot" then
                    local diffbot_url = DiffbotSanitizer.buildUrl(sanitizer, link)
                    if not diffbot_url then
                        logger.info("RSSReader", "Diffbot sanitizer misconfigured; skipping")
                        processSanitizer(index + 1)
                        return
                    end

                    DiffbotSanitizer.fetchContent(diffbot_url, function(content, err)
                        if not content then
                            processSanitizer(index + 1)
                            return
                        end

                        local diffbot_html, diffbot_meta = DiffbotSanitizer.parseResponse(content)
                        if type(diffbot_meta) == "table" then
                            -- no-op; retained for compatibility, meta ignored currently
                        end
                        if not diffbot_html or not DiffbotSanitizer.contentIsMeaningful(diffbot_html) then
                            processSanitizer(index + 1)
                            return
                        end

                        finalizeContent(diffbot_html, true)
                    end)
                elseif sanitizer_type == "instaparser" then
                    InstaparserSanitizer.fetchArticle(sanitizer, link, function(content, err)
                        if not content then
                            processSanitizer(index + 1)
                            return
                        end

                        local instaparser_html = InstaparserSanitizer.parseResponse(content)
                        if not instaparser_html or not InstaparserSanitizer.contentIsMeaningful(instaparser_html) then
                            processSanitizer(index + 1)
                            return
                        end

                        finalizeContent(instaparser_html, true)
                    end)
                else
                    logger.info("RSSReader", "Unknown sanitizer type", sanitizer.type)
                    processSanitizer(index + 1)
                end
            end

            processSanitizer(1)
        end)
    end)
end

function utils.downloadStoryToCache(story, builder, on_complete)
    local cache_dir = utils.buildCacheDirectory()
    local filename = utils.safeFilenameFromStory(story)
    local target_path = cache_dir .. "/" .. filename
    local base_name = filename:gsub("%.html$", "")

    utils.fetchStoryContent(story, builder, function(content, err)
        if not content then
            if on_complete then
                on_complete(nil, err)
            end
            return
        end

        local story_url = story.permalink or story.href or story.link or ""
        if not utils.writeStoryHtmlFile(content, target_path, utils.resolveStoryDocumentTitle(story), story_url) then
            if on_complete then
                on_complete(nil, "write_error")
            end
            return
        end

        FileManager:openFile(target_path)
        if on_complete then
            on_complete(target_path)
        end
    end, {
        asset_base_dir = cache_dir,
        asset_base_name = base_name,
    })
end

function utils.determineSaveDirectory(builder)
    if builder.accounts and builder.accounts.config then
        local predefined = util.tableGetValue(builder.accounts.config, "features", "default_folder_on_save")
        if type(predefined) == "string" and predefined ~= "" and util.pathExists(predefined) then
            return predefined
        end
    end
    if G_reader_settings then
        local home_dir = G_reader_settings:readSetting("home_dir")
        if type(home_dir) == "string" and home_dir ~= "" and util.pathExists(home_dir) then
            return home_dir
        end
    end
    local ui = builder.reader and builder.reader.ui
    if ui then
        local chooser_path = ui.file_chooser and ui.file_chooser.path
        if type(chooser_path) == "string" and chooser_path ~= "" and util.pathExists(chooser_path) then
            return chooser_path
        end
        if type(ui.getLastDirFile) == "function" then
            local last_dir = ui:getLastDirFile()
            if type(last_dir) == "string" and last_dir ~= "" and util.pathExists(last_dir) then
                return last_dir
            end
        end
    end
    return lfs.currentdir()
end

function utils.buildUniqueTargetPath(directory, filename)
    local base_name = filename:gsub("%.html$", "")
    local candidate = directory .. "/" .. filename
    local counter = 1
    while util.pathExists(candidate) do
        candidate = string.format("%s/%s_%d.html", directory, base_name, counter)
        counter = counter + 1
    end
    return candidate
end

function utils.buildUniqueTargetPathWithExtension(directory, base_name, extension)
    local sanitized_base = base_name:gsub("[^%w%._-]", "_")
    local candidate = string.format("%s/%s.%s", directory, sanitized_base, extension)
    local counter = 1
    while util.pathExists(candidate) do
        candidate = string.format("%s/%s_%d.%s", directory, sanitized_base, counter, extension)
        counter = counter + 1
    end
    return candidate
end

function utils.triggerHoldCallback(_, item)
    if item and type(item.hold_callback) == "function" then
        item.hold_callback()
    end
    return true
end

return utils
