local util = require("util")
local Menu = require("ui/widget/menu")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ffiUtil = require("ffi/util")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local http = require("socket.http")
local urlmod = require("socket.url")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local FileManager = require("apps/filemanager/filemanager")

local Screen = Device.screen

local Commons = require("rssreader_commons")
local LocalStore = require("rssreader_local_store")
local StoryViewer = require("rssreader_story_viewer")
local FeedFetcher = require("rssreader_feed_fetcher")
local HtmlSanitizer = require("rssreader_html_sanitizer")
local sha2 = require("ffi/sha2")
local LocalReadState

local MenuBuilder = {}
MenuBuilder.__index = MenuBuilder

local ENTITY_REPLACEMENTS = {
    ["&#8216;"] = "‘",
    ["&#8217;"] = "’",
}

local function replaceRightSingleQuoteEntities(text)
    if type(text) ~= "string" then
        return text
    end
    local replaced = text:gsub("&#%d+;", function(entity)
        return ENTITY_REPLACEMENTS[entity] or entity
    end)
    return replaced
end

local function hasLikelyXmlStructure(content)
    if type(content) ~= "string" then
        return false
    end
    local trimmed = content:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return false
    end
    if trimmed:sub(1, 1) ~= "<" then
        return false
    end
    if trimmed:find("<item", 1, true) or trimmed:find("<entry", 1, true) then
        return true
    end
    if trimmed:find("<rss", 1, true) or trimmed:find("<feed", 1, true) then
        return true
    end
    return false
end

local function fiveFiltersContentIsMeaningful(html)
    if type(html) ~= "string" then
        return false
    end
    local trimmed = html:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return false
    end
    local minimum_length = 200
    return trimmed:len() >= minimum_length
end

local function findNextIndex(stories, start_index, predicate)
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

local function ensureMenuCloseHook(menu_instance)
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

local function parseReadFlag(value)
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

local function normalizeStoryReadState(story)
    if type(story) ~= "table" then
        return
    end
    local read_state = story._rss_is_read
    for _, key in ipairs({ "read_status", "read", "story_read" }) do
        local parsed = parseReadFlag(story[key])
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

local function setStoryReadState(story, is_read)
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
    normalizeStoryReadState(story)
end

local function storyReadState(story)
    if type(story) ~= "table" then
        return nil
    end
    normalizeStoryReadState(story)
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

local function isUnread(story)
    if type(story) ~= "table" then
        return false
    end
    local read_state = storyReadState(story)
    if read_state ~= nil then
        return not read_state
    end
    return true
end

local function formatStoryDate(story)
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
    local ok, formatted = pcall(os.date, "%Y-%m-%d", timestamp)
    if ok then
        return formatted
    end
    return nil
end

local function decoratedStoryTitle(story, decorate)
    local title = replaceRightSingleQuoteEntities(story.story_title or story.title or _("Untitled story"))
    if decorate and isUnread(story) then
        title = string.format("%s • %s", _("NEW"), title)
    end
    local date_label = formatStoryDate(story)
    if date_label then
        return string.format("%s %s %s", title, " • ", date_label)
    end
    return title
end

local function storyUniqueKey(story)
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

local function appendUniqueStory(storage, key_map, story)
    if type(storage) ~= "table" or type(key_map) ~= "table" or type(story) ~= "table" then
        return false
    end
    local key = storyUniqueKey(story)
    if key and key_map[key] then
        return false
    end
    normalizeStoryReadState(story)
    table.insert(storage, story)
    if key then
        key_map[key] = true
    end
    return true
end

local function persistFeedState(menu_instance, feed_node)
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

local function trackMenuPage(menu_instance, feed_node)
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
            persistFeedState(self, feed_node)
        end
        local reader = self._rss_reader
        if reader and type(reader.saveNavigationState) == "function" then
            reader:saveNavigationState()
        end
        return result
    end
    menu_instance._rss_page_tracking = true
    persistFeedState(menu_instance, feed_node)
end

local function restoreMenuPage(menu_instance, feed_node, target_page)
    if not menu_instance then
        return
    end
    trackMenuPage(menu_instance, feed_node)
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

local function buildCacheDirectory()
    local base_dir = DataStorage:getDataDir() .. "/cache/rssreader"
    util.makePath(base_dir)
    return base_dir
end

local function sanitizeFiveFiltersHtml(html)
    if type(html) ~= "string" or html == "" then
        return html
    end
    html = html:gsub("%s*<p>%s*<strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org\">Adblock%s+test</a>%s*</strong>%s*<a%s+href=\"https://blockads%.fivefilters%.org/acceptable%.html\">%(Why%?%)</a>%s*</p>%s*", "")
    return html
end

local function writeStoryHtmlFile(html, filepath)
    if type(html) == "string" and html ~= "" then
        html = sanitizeFiveFiltersHtml(html)
        html = HtmlSanitizer.disableFontSizeDeclarations(html)
    end
    local file = io.open(filepath, "w")
    if not file then
        return false
    end
    file:write("<html><head><meta charset=\"utf-8\"></head><body>")
    file:write(html or "")
    file:write("</body></html>")
    file:close()
    return true
end

local function normalizeStoryLink(story)
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

local function safeFilenameFromStory(story)
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

local function rewriteRelativeResourceUrls(html, page_url)
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

local function shouldUseFiveFilters(builder)
    if not builder or not builder.accounts or not builder.accounts.config then
        return false
    end
    local flag = util.tableGetValue(builder.accounts.config, "features", "use_fivefilters_on_save_open")
    if flag == nil then
        return false
    end
    return flag and true or false
end

local function buildFiveFiltersUrl(link)
    if type(link) ~= "string" or link == "" then
        return nil
    end
    local encoded = util.urlEncode(link)
    if not encoded or encoded == "" then
        return nil
    end
    return string.format("https://ftr.fivefilters.net/makefulltextfeed.php?step=3&fulltext=1&url=%s&max=3&links=preserve&exc=1&submit=Create+Feed", encoded)
end

local function detectFiveFiltersBlocked(content)
    if type(content) ~= "string" then
        return false
    end
    return content:find("URL blocked", 1, true) ~= nil
end

local function extractFiveFiltersHtml(xml_content)
    if type(xml_content) ~= "string" or xml_content == "" then
        return nil
    end

    local item_block = xml_content:match("<item[^>]*>(.-)</item>")
    if not item_block then
        return nil
    end

    local function extractTagContent(block, tag)
        local pattern = string.format("<%s[^>]*>(.-)</%s>", tag, tag)
        local value = block:match(pattern)
        if not value then
            return nil
        end
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        local cdata = value:match("^<!%[CDATA%[(.*)%]%]>$")
        if cdata then
            value = cdata
        end
        return value
    end

    local title_text = util.htmlEntitiesToUtf8(extractTagContent(item_block, "title") or "")
    local description_text = extractTagContent(item_block, "description") or ""

    if description_text == "" then
        return nil
    end

    description_text = util.htmlEntitiesToUtf8(description_text)
    description_text = description_text:gsub("&lt;", "<"):gsub("&gt;", ">")

    local placeholder_marker = "[unable to retrieve full-text content]"
    if description_text:lower():find(placeholder_marker, 1, true) then
        return nil
    end

    local fragments = {}
    if title_text ~= "" then
        table.insert(fragments, string.format("<h3>%s</h3>", title_text))
    end
    table.insert(fragments, description_text)
    return table.concat(fragments, "")
end

local function rewriteFiveFiltersHtml(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end
    local trimmed = html:gsub("^[%s%c]+", ""):gsub("[%s%c]+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function fetchViaHttp(link, on_complete)
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

local function fetchStoryContent(story, builder, on_complete, options)
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
            local use_fivefilters = shouldUseFiveFilters(builder)

            local function handleOriginalDownload()
                fetchViaHttp(link, function(content, err)
                    if not content then
                        if on_complete then
                            on_complete(nil, err)
                        end
                        return
                    end
                    content = rewriteRelativeResourceUrls(content, link)
                    content = HtmlSanitizer.disableFontSizeDeclarations(content)
                    if on_complete then
                        on_complete(content)
                    end
                end)
            end

            if not use_fivefilters then
                handleOriginalDownload()
                return
            end

            local fivefilters_url = buildFiveFiltersUrl(link)
            if not fivefilters_url then
                handleOriginalDownload()
                return
            end

            fetchViaHttp(fivefilters_url, function(content, err)
                if not content then
                    handleOriginalDownload()
                    return
                end

                if not hasLikelyXmlStructure(content) then
                    handleOriginalDownload()
                    return
                end

                if detectFiveFiltersBlocked(content) then
                    handleOriginalDownload()
                    return
                end

                local fivefilters_html = rewriteFiveFiltersHtml(extractFiveFiltersHtml(content))
                if not fivefilters_html or not fiveFiltersContentIsMeaningful(fivefilters_html) then
                    handleOriginalDownload()
                    return
                end

                if on_complete then
                    on_complete(fivefilters_html)
                end
            end)
        end)
    end)
end

local function downloadStoryToCache(story, builder, on_complete)
    local cache_dir = buildCacheDirectory()
    local filename = safeFilenameFromStory(story)
    local target_path = cache_dir .. "/" .. filename

    fetchStoryContent(story, builder, function(content, err)
        if not content then
            if on_complete then
                on_complete(nil, err)
            end
            return
        end

        if not writeStoryHtmlFile(content, target_path) then
            if on_complete then
                on_complete(nil, "write_error")
            end
            return
        end

        FileManager:openFile(target_path)
        if on_complete then
            on_complete(target_path)
        end
    end)
end

local function determineSaveDirectory(builder)
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

local function buildUniqueTargetPath(directory, filename)
    local base_name = filename:gsub("%.html$", "")
    local candidate = directory .. "/" .. filename
    local counter = 1
    while util.pathExists(candidate) do
        candidate = string.format("%s/%s_%d.html", directory, base_name, counter)
        counter = counter + 1
    end
    return candidate
end

function MenuBuilder:showStory(stories, index, on_action, on_close, options, context)
    self.story_viewer = self.story_viewer or StoryViewer:new()
    local reader = self.reader
    if reader and type(reader.requestFeedStatePreservation) == "function" then
        reader:requestFeedStatePreservation()
    end
    local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
    local current_info = self.reader and self.reader.current_menu_info
    local history_snapshot
    if self.reader and self.reader.history then
        history_snapshot = {}
        for i, entry in ipairs(self.reader.history) do
            history_snapshot[i] = entry
        end
    end
    local story = stories and stories[index]
    if story then
        normalizeStoryReadState(story)
        if isUnread(story) then
            self:handleStoryAction(stories, index, "mark_read", story, context)
        end
    end
    local is_api_context = false
    if context and (context.feed_type == "newsblur" or context.feed_type == "commafeed") then
        is_api_context = true
    end

    local disable_mutators = false
    if options and options.disable_story_mutators and not is_api_context then
        disable_mutators = true
    end
    self.story_viewer:showStory(story, function(action, payload)
        self:handleStoryAction(stories, index, action, payload, context)
    end, function()
        if self.reader and current_menu then
            if current_info and self.reader.current_menu_info ~= current_info then
                self.reader.current_menu_info = current_info
            end
            if history_snapshot and #history_snapshot > 0 and (not self.reader.history or #self.reader.history == 0) and not current_menu._rss_is_root_menu then
                self.reader.history = history_snapshot
            end
            self.reader:updateBackButton(current_menu)
        else
        end
        if context and type(context.refresh) == "function" then
            local should_refresh = context._needs_refresh or context.force_refresh_on_close
            if should_refresh then
                context._needs_refresh = nil
                context.force_refresh_on_close = nil
                context.refresh()
            end
        end
        if on_close then
            on_close()
        end
    end, {
        disable_story_mutators = disable_mutators,
        is_api_version = is_api_context,
    })
end

function MenuBuilder:_updateStoryEntry(context, stories, index)
    if not context or not stories or not index then
        return
    end
    local menu_instance = context.menu_instance
    local story = stories[index]
    if not menu_instance or not story or type(menu_instance) ~= "table" then
        return
    end
    if type(menu_instance.item_table) ~= "table" then
        return
    end
    local entry = menu_instance.item_table[index]
    if not entry then
        return
    end
    local decorate = context.feed_type ~= "local"
    entry.text = decoratedStoryTitle(story, decorate)
    entry.bold = isUnread(story)
    if type(menu_instance.updateItems) == "function" then
        menu_instance:updateItems(nil, true)
    end
end

function MenuBuilder:_updateFeedCache(context)
    if not context then
        return
    end
    local feed_node = context.feed_node
    if not feed_node then
        return
    end
    if context.menu_instance then
        persistFeedState(context.menu_instance, feed_node)
        return
    end
    local reader = feed_node._rss_reader or self.reader
    if not reader or type(reader.updateFeedState) ~= "function" then
        return
    end
    local account_name = feed_node._account_name
        or (context.account and context.account.name)
        or context.account_name
        or "unknown"
    local stories_copy = util.tableDeepCopy(feed_node._rss_stories or {})
    local story_keys_copy = {}
    for key, value in pairs(feed_node._rss_story_keys or {}) do
        if value then
            story_keys_copy[key] = true
        end
    end
    reader:updateFeedState(account_name, feed_node.id, {
        stories = stories_copy,
        story_keys = story_keys_copy,
        menu_page = context.menu_instance and context.menu_instance.page or feed_node._rss_menu_page,
        current_page = feed_node._rss_page,
        has_more = feed_node._rss_has_more,
    })
end

function MenuBuilder:handleStoryAction(stories, index, action, payload, context)
    local story = stories and stories[index]
    if action == "go_to_link" then
        local payload_table = type(payload) == "table" and payload or {}
        local target_story = payload_table.story or story
        normalizeStoryLink(target_story)

        local function closeCurrentStory()
            if type(payload_table.close_story) == "function" then
                payload_table.close_story()
            end
        end

        local function closeActiveMenu()
            local reader = self.reader
            if reader and reader.current_menu_info and reader.current_menu_info.menu then
                UIManager:close(reader.current_menu_info.menu)
                reader.current_menu_info = nil
            end
        end

        closeCurrentStory()
        closeActiveMenu()

        downloadStoryToCache(target_story, self, function(path, err)
            if err then
                local link = target_story and (target_story.permalink or target_story.href or target_story.link)
                if link then
                    UIManager:show(InfoMessage:new{ text = string.format(_("Opening: %s"), link) })
                end
            end
        end)
        return
    end

    if action == "next_story" then
        local next_index = findNextIndex(stories, index, function()
            return true
        end)
        if next_index then
            self:showStory(stories, next_index, function(next_action, next_payload)
                self:handleStoryAction(stories, next_index, next_action, next_payload, context)
            end, nil, nil, context)
        end
        return
    end

    if action == "next_unread" then
        local next_index = findNextIndex(stories, index, function(story)
            return isUnread(story)
        end)
        if next_index then
            self:showStory(stories, next_index, function(next_action, next_payload)
                self:handleStoryAction(stories, next_index, next_action, next_payload, context)
            end, nil, nil, context)
        else
            UIManager:show(InfoMessage:new{ text = _("No unread stories found.") })
        end
        return
    end

    if action == "open_link" then
        local link = payload
        if link and util.openFileWithCRE then
            util.openFileWithCRE(link)
        elseif link then
            UIManager:show(InfoMessage:new{ text = string.format(_("Opening: %s"), link) })
        end
        return
    end

    if action == "mark_read" then
        if story then
            setStoryReadState(story, true)
            self:_updateStoryEntry(context, stories, index)
            self:_updateFeedCache(context)
            if context and context.feed_type == "local" then
                local feed_identifier = context.feed_identifier or (context.feed_node and (context.feed_node.url or context.feed_node.id))
                if feed_identifier and story._rss_local_key then
                    context.local_read_map = context.local_read_map or {}
                    context.local_read_map = self.local_read_state.markRead(feed_identifier, story._rss_local_key, context.local_read_map)
                    if context.feed_node then
                        context.feed_node._rss_local_read_map = context.local_read_map
                    end
                end
            end
            if context and context.client and context.feed_id and type(context.client.markStoryAsRead) == "function" then
                NetworkMgr:runWhenOnline(function()
                    local ok, err_or_data = context.client:markStoryAsRead(context.feed_id, story)
                    if not ok then
                        setStoryReadState(story, false)
                        self:_updateStoryEntry(context, stories, index)
                        self:_updateFeedCache(context)
                        UIManager:show(InfoMessage:new{ text = err_or_data or _("Failed to update story state."), timeout = 3 })
                    end
                end)
            end
        end
        return
    end

    if action == "mark_unread" then
        if story then
            setStoryReadState(story, false)
            if context and context.client and context.feed_id and type(context.client.markStoryAsUnread) == "function" then
                NetworkMgr:runWhenOnline(function()
                    local ok, err_or_data = context.client:markStoryAsUnread(context.feed_id, story)
                    if ok then
                        self:_updateStoryEntry(context, stories, index)
                        self:_updateFeedCache(context)
                    else
                        setStoryReadState(story, true)
                        self:_updateStoryEntry(context, stories, index)
                        UIManager:show(InfoMessage:new{ text = err_or_data or _("Failed to update story state."), timeout = 3 })
                    end
                end)
            end
            if context and context.feed_type == "local" then
                local feed_identifier = context.feed_identifier or (context.feed_node and (context.feed_node.url or context.feed_node.id))
                if feed_identifier and story._rss_local_key then
                    context.local_read_map = context.local_read_map or {}
                    context.local_read_map = self.local_read_state.markUnread(feed_identifier, story._rss_local_key, context.local_read_map)
                    if context.feed_node then
                        context.feed_node._rss_local_read_map = context.local_read_map
                    end
                end
            end
            self:_updateStoryEntry(context, stories, index)
            self:_updateFeedCache(context)
        end
        return
    end

    if action == "save_story" then
        local payload = type(payload) == "table" and payload or {}
        local target_story = payload.story or story
        if not target_story then
            UIManager:show(InfoMessage:new{ text = _("Could not save story."), timeout = 3 })
            return
        end

        normalizeStoryLink(target_story)
        UIManager:show(InfoMessage:new{ text = _("Saving story..."), timeout = 1 })

        fetchStoryContent(target_story, self, function(content, err)
            if not content then
                UIManager:show(InfoMessage:new{ text = _("Failed to download story."), timeout = 3 })
                return
            end

            local directory = determineSaveDirectory(self)
            if not directory or directory == "" then
                UIManager:show(InfoMessage:new{ text = _("No target folder available."), timeout = 3 })
                return
            end
            util.makePath(directory)

            local filename = safeFilenameFromStory(target_story)
            local target_path = buildUniqueTargetPath(directory, filename)
            if not writeStoryHtmlFile(content, target_path) then
                UIManager:show(InfoMessage:new{ text = _("Failed to save story."), timeout = 3 })
                return
            end

            UIManager:show(InfoMessage:new{ text = string.format(_("Saved to: %s"), target_path), timeout = 3 })
        end, { silent = true })
        return
    end

    if self.reader and type(self.reader.handleStoryAction) == "function" then
        self.reader:handleStoryAction(stories, index, action, payload, context)
    end
end

function MenuBuilder:collectFeedIdsForNode(node)
    local feed_ids = {}
    if not node then
        return feed_ids
    end

    local function collectFromNode(current_node)
        if current_node.kind == "feed" then
            if current_node.id then
                table.insert(feed_ids, current_node.id)
            end
        elseif current_node.kind == "folder" or current_node.kind == "root" then
            if current_node.children then
                for _, child in ipairs(current_node.children) do
                    collectFromNode(child)
                end
            end
        end
    end

    collectFromNode(node)
    return feed_ids
end

local function triggerHoldCallback(_, item)
    if item and type(item.hold_callback) == "function" then
        item.hold_callback()
    end
    return true
end

function MenuBuilder:createLongPressMenuForNode(account, client, node, normal_callback)
    if not node or node.kind ~= "feed" then
        return
    end

    local account_type = account and account.type
    if account_type ~= "newsblur" and account_type ~= "commafeed" then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = node.title or _("Feed"),
        buttons = {{
            {
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsRead(account, client, node)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:createLongPressMenuForLocalFeed(feed, account_name, normal_callback)
    if not feed then
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = feed.title or feed.url or _("Feed"),
        buttons = {{
            {
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    if type(normal_callback) == "function" then
                        normal_callback()
                    end
                end,
            },
            {
                text = _("Mark all as read"),
                callback = function()
                    UIManager:close(dialog)
                    self:performLocalMarkAllAsRead(feed, account_name)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    return dialog
end

function MenuBuilder:performLocalMarkAllAsRead(feed, account_name)
    if not feed or not feed.url then
        UIManager:show(InfoMessage:new{
            text = _("Feed URL is missing."),
            timeout = 3,
        })
        return
    end

    local title = feed.title or feed.url or _("Feed")
    UIManager:show(InfoMessage:new{
        text = string.format(_("Marking feed '%s' as read..."), title),
        timeout = 1,
    })

    local feed_identifier = feed.url or feed.id or feed.title or "local_feed"
    account_name = account_name or feed._rss_account_name or "local"

    NetworkMgr:runWhenOnline(function()
        local ok, items_or_err = FeedFetcher.fetch(feed.url)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to load feed: %s"), items_or_err or _("unknown")),
                timeout = 3,
            })
            return
        end

        local items = items_or_err or {}
        if type(items) ~= "table" then
            items = {}
        end

        local read_map = self.local_read_state.load(feed_identifier)
        if type(read_map) ~= "table" then
            read_map = {}
        end

        local new_marks = 0
        for _, story in ipairs(items) do
            normalizeStoryReadState(story)
            local key = storyUniqueKey(story)
            if key then
                if not read_map[key] then
                    new_marks = new_marks + 1
                end
                read_map[key] = true
            end
        end

        self.local_read_state.save(feed_identifier, read_map)

        local feed_node = feed._rss_feed_node
        if feed_node then
            feed_node._rss_local_read_map = read_map
            for _, story in ipairs(feed_node._rss_stories or {}) do
                local key = story._rss_local_key or storyUniqueKey(story)
                if key then
                    story._rss_local_key = key
                    setStoryReadState(story, true)
                end
            end
            self:_updateFeedCache({ feed_node = feed_node })
        end

        UIManager:show(InfoMessage:new{
            text = string.format(_("Marked %d item(s) as read."), new_marks),
            timeout = 3,
        })
    end)
end

function MenuBuilder:showMarkAllAsReadDialogForAccount(account)
    local title_text = string.format(_("Mark all stories in account '%s' as read?"), account.name or _("Account"))

    local dialog
    dialog = ButtonDialog:new{
        title = _("Confirm"),
        text = title_text,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Mark all as read"),
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsReadForAccount(account)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function MenuBuilder:performMarkAllAsReadForAccount(account)
    local account_type = account and account.type
    if account_type ~= "newsblur" and account_type ~= "commafeed" then
        UIManager:show(InfoMessage:new{
            text = _("Account type not supported."),
            timeout = 3,
        })
        return
    end

    if not self.accounts or type(self.accounts.getNewsBlurClient) ~= "function" and type(self.accounts.getCommaFeedClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("Account integration is not available."),
            timeout = 3,
        })
        return
    end

    local client
    if account_type == "newsblur" then
        client = self.accounts:getNewsBlurClient(account)
    elseif account_type == "commafeed" then
        client = self.accounts:getCommaFeedClient(account)
    end

    if not client then
        UIManager:show(InfoMessage:new{
            text = _("Unable to access account."),
            timeout = 3,
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load account structure."),
                timeout = 3,
            })
            return
        end

        local feed_ids = self:collectFeedIdsForNode(tree_or_err)
        if #feed_ids == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No feeds found in account."),
                timeout = 3,
            })
            return
        end

        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking %d feed(s) as read..."), #feed_ids),
            timeout = 1,
        })

        local success_count = 0
        local error_messages = {}

        for _, feed_id in ipairs(feed_ids) do
            local mark_ok, err = client:markFeedAsRead(feed_id)
            if mark_ok then
                success_count = success_count + 1
            else
                table.insert(error_messages, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
            end
        end

        if success_count > 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Marked %d feed(s) as read."), success_count),
                timeout = 3,
            })
        end

        if #error_messages > 0 then
            local error_text = table.concat(error_messages, "\n")
            UIManager:show(InfoMessage:new{
                text = string.format(_("Errors occurred:\n%s"), error_text),
                timeout = 5,
            })
        end
    end)
end

function MenuBuilder:showMarkAllAsReadDialog(account, client, node)
    local node_type = node and node.kind or "root"
    local title_text
    if node_type == "feed" then
        title_text = string.format(_("Mark all stories in '%s' as read?"), node.title or _("Feed"))
    elseif node_type == "folder" then
        title_text = string.format(_("Mark all stories in '%s' and subfolders as read?"), node.title or _("Folder"))
    else
        title_text = string.format(_("Mark all stories in account '%s' as read?"), account.name or _("Account"))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = _("Confirm"),
        text = title_text,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Mark all as read"),
                callback = function()
                    UIManager:close(dialog)
                    self:performMarkAllAsRead(account, client, node)
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function MenuBuilder:performMarkAllAsRead(account, client, node)
    local node_type = node and node.kind
    local account_type = account and account.type

    if node_type == "feed" then
        -- Mark single feed as read
        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking feed '%s' as read..."), node.title or _("Feed")),
            timeout = 1,
        })

        NetworkMgr:runWhenOnline(function()
            local ok, err = client:markFeedAsRead(node.id)
            if ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Marked feed '%s' as read."), node.title or _("Feed")),
                    timeout = 3,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Failed to mark feed as read: %s"), err or _("Unknown error")),
                    timeout = 3,
                })
            end
        end)
        return
    elseif node_type == "folder" then
        -- Mark folder as read - try specific API first, fallback to marking all feeds
        UIManager:show(InfoMessage:new{
            text = string.format(_("Marking folder '%s' as read..."), node.title or _("Folder")),
            timeout = 1,
        })

        NetworkMgr:runWhenOnline(function()
            local success = false
            local error_msg = nil

            -- Try folder-specific API call first
            if account_type == "newsblur" and client.markFolderAsRead then
                success, error_msg = client:markFolderAsRead(node.title)
            elseif account_type == "commafeed" and node_type == "folder" then
                -- CommaFeed doesn't support category mark all as read, fall back to individual feeds
                success = false
            elseif account_type == "commafeed" and client.markCategoryAsRead then
                success, error_msg = client:markCategoryAsRead(node.id)
            end

            -- If folder-specific API failed or not available, mark all feeds in folder
            if not success then
                local feed_ids = self:collectFeedIdsForNode(node)
                if #feed_ids == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No feeds found in folder."),
                        timeout = 3,
                    })
                    return
                end

                local success_count = 0
                local errors = {}

                for _, feed_id in ipairs(feed_ids) do
                    local ok, err = client:markFeedAsRead(feed_id)
                    if ok then
                        success_count = success_count + 1
                    else
                        table.insert(errors, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
                    end
                end

                if success_count > 0 then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Marked %d feed(s) in folder as read."), success_count),
                        timeout = 3,
                    })
                end

                if #errors > 0 then
                    local error_text = table.concat(errors, "\n")
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Errors occurred:\n%s"), error_text),
                        timeout = 5,
                    })
                end
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Marked folder '%s' as read."), node.title or _("Folder")),
                    timeout = 3,
                })
            end
        end)
        return
    end

    -- Fallback for account-level or unknown node types
    local feed_ids = self:collectFeedIdsForNode(node)
    if #feed_ids == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds found to mark as read."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Marking %d feed(s) as read..."), #feed_ids),
        timeout = 1,
    })

    NetworkMgr:runWhenOnline(function()
        local success_count = 0
        local error_messages = {}

        for _, feed_id in ipairs(feed_ids) do
            local ok, err = client:markFeedAsRead(feed_id)
            if ok then
                success_count = success_count + 1
            else
                table.insert(error_messages, string.format("Feed %s: %s", tostring(feed_id), err or _("Unknown error")))
            end
        end

        if success_count > 0 then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Marked %d feed(s) as read."), success_count),
                timeout = 3,
            })
        end

        if #error_messages > 0 then
            local error_text = table.concat(error_messages, "\n")
            UIManager:show(InfoMessage:new{
                text = string.format(_("Errors occurred:\n%s"), error_text),
                timeout = 5,
            })
        end
    end)
end

function MenuBuilder:new(opts)
    local options = opts or {}
    local instance = setmetatable({}, MenuBuilder)
    instance.local_store = options.local_store or LocalStore:new()
    if not instance.local_read_state then
        LocalReadState = LocalReadState or require("rssreader_local_readstate")
    end
    instance.local_read_state = LocalReadState
    instance.accounts = options.accounts
    instance.reader = options.reader
    instance.story_viewer = options.story_viewer or StoryViewer:new()
    return instance
end

function MenuBuilder:calculateFolderUnreadCount(node)
    if not node or not node.children then
        return 0
    end
    local total = 0
    for _, child in ipairs(node.children) do
        if child.kind == "feed" then
            total = total + ((child.feed.ps or 0) + (child.feed.nt or 0))
        elseif child.kind == "folder" then
            total = total + self:calculateFolderUnreadCount(child)
        end
    end
    return total
end

function MenuBuilder:showMenu(menu_instance, reopen_func, opts)
    if menu_instance and self.reader then
        menu_instance._rss_reader = self.reader
    end
    if self.reader and type(self.reader.showMenu) == "function" then
        self.reader:showMenu(menu_instance, reopen_func, opts)
    else
        UIManager:show(menu_instance)
    end
end

function MenuBuilder:showLocalFeed(feed, opts)
    opts = opts or {}
    local account_name = opts.account_name or (feed and feed._rss_account_name) or "local"
    if feed then
        feed._rss_account_name = account_name
    end
    if not feed or not feed.url then
        UIManager:show(InfoMessage:new{
            text = _("Feed URL is missing."),
        })
        return
    end

    local feed_id = feed.id or feed.url or feed.title or tostring(feed)
    local feed_node = feed._rss_feed_node or {
        id = feed_id,
        title = feed.title,
        url = feed.url,
        _account_name = account_name,
        _rss_stories = {},
        _rss_story_keys = {},
        _rss_page = 1,
        _rss_has_more = false,
    }
    feed._rss_feed_node = feed_node
    feed_node.url = feed.url
    feed_node._rss_reader = self.reader
    feed_node._account_name = account_name

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account_name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local feed_identifier = feed_node.url or feed.url or feed_node.id or feed_node.title or "local_feed"
    local read_map = feed_node._rss_local_read_map
    if not read_map then
        local loaded_map = self.local_read_state.load(feed_identifier)
        if type(loaded_map) ~= "table" then
            read_map = {}
        else
            read_map = loaded_map
        end
        feed_node._rss_local_read_map = read_map
    end

    local function applyLocalReadState()
        local stories = feed_node._rss_stories or {}
        if type(read_map) ~= "table" then
            read_map = {}
        end
        local valid_keys = {}
        for _, story in ipairs(stories) do
            normalizeStoryReadState(story)
            local key = storyUniqueKey(story)
            if key then
                story._rss_local_key = key
                if read_map[key] then
                    setStoryReadState(story, true)
                else
                    setStoryReadState(story, false)
                end
                table.insert(valid_keys, key)
            else
                story._rss_local_key = nil
                setStoryReadState(story, false)
            end
        end
        read_map = self.local_read_state.prune(feed_identifier, read_map, valid_keys)
        feed_node._rss_local_read_map = read_map
        self.local_read_state.save(feed_identifier, read_map)
    end

    local function finalizeMenu()
        local stories = feed_node._rss_stories or {}
        if #stories == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local context = {
            feed_type = "local",
            feed = feed,
            feed_node = feed_node,
            feed_identifier = feed_identifier,
            local_read_map = read_map,
            refresh = function()
                self:showLocalFeed(feed, {
                    account_name = account_name,
                    menu_page = feed_node._rss_menu_page,
                })
            end,
            force_refresh_on_close = true,
        }

        local entries = {}
        applyLocalReadState()
        for index, story in ipairs(stories) do
            normalizeStoryReadState(story)
            normalizeStoryLink(story)
            local entry_is_unread = isUnread(story)
            table.insert(entries, {
                text = decoratedStoryTitle(story, true),
                bold = entry_is_unread,
                callback = function()
                    self:showStory(stories, index, function(action, payload)
                        self:handleStoryAction(stories, index, action, payload, context)
                    end, nil, nil, context)
                end,
            })
        end

        local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
        local menu_instance
        if current_menu and current_menu._rss_feed_node == feed_node then
            menu_instance = current_menu
            if menu_instance.setTitle then
                menu_instance:setTitle(feed_node.title or _("Feed"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
        else
            menu_instance = Menu:new{
                title = feed_node.title or _("Feed"),
                item_table = entries,
                multilines_forced = true,
            }
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                self:showLocalFeed(feed, {
                    account_name = account_name,
                })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
            persistFeedState(menu_instance, feed_node)
        end

        restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)
    end

    NetworkMgr:runWhenOnline(function()
        local ok, items_or_err = FeedFetcher.fetch(feed.url)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Failed to load feed: %s"), items_or_err or _("unknown")),
            })
            if self.reader and type(self.reader.goBack) == "function" then
                self.reader:goBack()
            end
            return
        end

        local items = items_or_err or {}
        if type(items) ~= "table" then
            items = {}
        end
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local previous_menu_page = feed_node._rss_menu_page
        feed_node._rss_stories = {}
        feed_node._rss_story_keys = {}
        feed_node._rss_page = 1
        feed_node._rss_has_more = false
        for _, story in ipairs(items) do
            appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
        end
        feed_node._rss_menu_page = previous_menu_page
        feed_node.title = feed.title or _("Feed")

        applyLocalReadState()
        finalizeMenu()
    end)
end

function MenuBuilder:buildAccountEntries(accounts, open_callback)
    local entries = {}
    for index, account in ipairs(accounts or {}) do
        local title = Commons.accountTitle(account)
        local holds_items = {}
        
        -- Add account info for all accounts
        table.insert(holds_items, {
            text = _("Account info"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = string.format("%s\n(%s)", title, account.type or "unknown"),
                })
            end,
        })
        
        -- Add Open option for local accounts
        if account.type == "local" then
            table.insert(holds_items, {
                text = _("Open"),
                callback = function()
                    if open_callback then
                        open_callback(account)
                    end
                end,
            })
        end
        
        -- Add Mark all as read for API accounts
        if account.type == "newsblur" or account.type == "commafeed" then
            table.insert(holds_items, {
                text = _("Mark all as read"),
                callback = function()
                    self:showMarkAllAsReadDialogForAccount(account)
                end,
            })
        elseif account.type == "local" then
            -- Keep the existing delete feed placeholder for local accounts
            table.insert(holds_items, {
                text = _("Delete feed (future feature)"),
                keep_menu_open = true,
                callback = function()
                    -- TODO: Implement feed deletion for local accounts
                    UIManager:show(InfoMessage:new{
                        text = _("Feed deletion not yet implemented for local accounts."),
                        timeout = 3,
                    })
                end,
            })
        end
        
        table.insert(entries, {
            text = title,
            callback = function()
                if open_callback then
                    open_callback(account)
                end
            end,
            holds = holds_items,
        })
    end
    table.insert(entries, {
        text = _("Settings"),
        keep_menu_open = true,
        callback = function()
            self:showSettingsPopup()
        end,
    })
    return entries
end

function MenuBuilder:showSettingsPopup()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Settings"),
        buttons = {
            {{
                text = _("Clear cache"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    self:clearCacheDirectory()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function MenuBuilder:clearCacheDirectory()
    local cache_dir = buildCacheDirectory()
    local ok, err = ffiUtil.purgeDir(cache_dir)
    if not ok then
        logger.warn("RSSReader", "Failed to clear cache directory", err)
        UIManager:show(InfoMessage:new{
            text = _("Failed to clear cache."),
        })
        return
    end

    util.makePath(cache_dir)
    UIManager:show(InfoMessage:new{
        text = _("Cache cleared."),
    })
end

function MenuBuilder:openAccount(reader, account)
    local account_type = account and account.type
    if account_type == "local" then
        self:showLocalAccount(account)
        return
    elseif account_type == "newsblur" then
        self:showNewsBlurAccount(account)
        return
    elseif account_type == "commafeed" then
        self:showCommaFeedAccount(account)
        return
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Account '%s' is not implemented yet."), Commons.accountTitle(account)),
    })
end

function MenuBuilder:showLocalAccount(account)
    local groups = {}
    local feeds = {}
    local account_name = (account and account.name) or "local"
    if account and account.name then
        groups = self.local_store:listGroups(account.name)
        feeds = self.local_store:listFeeds(account.name)
    else
        logger.warn("RSSReader", "Account or account.name is nil")
    end
    local entries = {}
    for feed_index, feed in ipairs(feeds) do
        local feed_title = feed.title or (feed.url or _("Unnamed feed"))
        local function openFeed()
            self:showLocalFeed(feed, {
                account_name = account_name,
            })
        end
        table.insert(entries, {
            text = feed_title,
            callback = openFeed,
            hold_callback = function()
                self:createLongPressMenuForLocalFeed(feed, account_name, openFeed)
            end,
            hold_keep_menu_open = true,
        })
    end
    for group_index, group in ipairs(groups) do
        local title = group.title or string.format(_("Local Group %d"), group_index)
        table.insert(entries, {
            text = string.format(_("%s (group)"), title),
            callback = function()
                self:showLocalGroup(group, account and account.name)
            end,
            hold_callback = function()
                self:showLocalGroup(group, account and account.name)
            end,
        })
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No local feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = Commons.accountTitle(account),
        item_table = entries,
    }
    menu_instance.onMenuHold = triggerHoldCallback
    self:showMenu(menu_instance, function()
        self:showLocalAccount(account)
    end)
end

function MenuBuilder:showLocalGroup(group, account_name)
    local feeds = (group and group.feeds) or {}
    local entries = {}
    for feed_index, feed in ipairs(feeds) do
        local function openFeed()
            self:showLocalFeed(feed, {
                account_name = account_name,
            })
        end
        table.insert(entries, {
            text = feed.title or (feed.url or _("Unnamed feed")),
            callback = openFeed,
            hold_callback = function()
                self:createLongPressMenuForLocalFeed(feed, account_name, openFeed)
            end,
            hold_keep_menu_open = true,
        })
    end

    if #entries == 0 then
        entries = {
            {
                text = _("No feeds in this group."),
                keep_menu_open = true,
                callback = function()
                    if self.reader and type(self.reader.goBack) == "function" then
                        self.reader:goBack()
                    end
                end,
            },
        }
    end

    local menu_instance = Menu:new{
        title = group and (group.title or _("Local Group")) or _("Local Group"),
        item_table = entries,
    }
    menu_instance.onMenuHold = triggerHoldCallback
    self:showMenu(menu_instance, function()
        self:showLocalGroup(group, account_name)
    end)
end

function MenuBuilder:showNewsBlurAccount(account)
    if not self.accounts or type(self.accounts.getNewsBlurClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("NewsBlur integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getNewsBlurClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open NewsBlur account."),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load NewsBlur subscriptions."),
            })
            return
        end

        self:showNewsBlurNode(account, client, tree_or_err)
    end)
end

function MenuBuilder:showNewsBlurNode(account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local unread_count = self:calculateFolderUnreadCount(child)
            local display_title = child.title or _("Untitled folder")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            local normal_callback = function()
                self:showNewsBlurNode(account, client, child)
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
            })
        elseif child.kind == "feed" then
            local unread_count = (child.feed.ps or 0) + (child.feed.nt or 0)
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            local normal_callback = function()
                self:showNewsBlurFeed(account, client, child)
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("NewsBlur"),
        item_table = entries,
        onMenuHold = triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        self:showNewsBlurNode(account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = triggerHoldCallback
    end
end

function MenuBuilder:showNewsBlurFeed(account, client, feed_node, opts)
    opts = opts or {}
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
            end
            if type(stored_state.current_page) == "number" then
                feed_node._rss_page = stored_state.current_page
            end
            feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page
    if opts.reuse then
        fetch_page = nil
    elseif opts.page then
        fetch_page = opts.page
    elseif feed_node._rss_page == 0 then
        fetch_page = 1
    end

    local function finalizeMenu()
        local stories = feed_node._rss_stories or {}
        if #stories == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local context = {
            feed_type = "newsblur",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                self:showNewsBlurFeed(account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local entries = {}
        for index, story in ipairs(stories) do
            normalizeStoryReadState(story)
            normalizeStoryLink(story)
            table.insert(entries, {
                text = decoratedStoryTitle(story, true),
                bold = isUnread(story),
                callback = function()
                    self:showStory(stories, index, function(action, payload)
                        self:handleStoryAction(stories, index, action, payload, context)
                    end, nil, { disable_story_mutators = true }, context)
                end,
            })
        end

        local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
        local menu_instance
        if current_menu and current_menu._rss_feed_node == feed_node then
            menu_instance = current_menu
            if menu_instance.setTitle then
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("NewsBlur"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("NewsBlur"),
                item_table = entries,
                multilines_forced = true,
            }
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                self:showNewsBlurFeed(account, client, feed_node, { reuse = true })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
            persistFeedState(menu_instance, feed_node)
        end

        if menu_instance and menu_instance.page_info then
            local next_page = (feed_node._rss_page or 1) + 1
            local existing_button_index
            for idx = #menu_instance.page_info, 1, -1 do
                local widget = menu_instance.page_info[idx]
                if widget and widget._rss_is_more_button then
                    existing_button_index = idx
                    break
                end
            end
            if existing_button_index then
                table.remove(menu_instance.page_info, existing_button_index)
                table.remove(menu_instance.page_info, existing_button_index - 1)
            end
            if feed_node._rss_has_more then
                local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
                local load_more_button = Button:new{
                    text = _("More"),
                    bordersize = 0,
                    show_parent = menu_instance.show_parent or menu_instance,
                    callback = function()
                        self:showNewsBlurFeed(account, client, feed_node, { page = next_page })
                    end,
                }
                load_more_button._rss_is_more_button = true
                table.insert(menu_instance.page_info, spacer)
                table.insert(menu_instance.page_info, load_more_button)
            end
            if menu_instance.page_info.resetLayout then
                menu_instance.page_info:resetLayout()
            end
        end

        restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)
    end

    if fetch_page then
        NetworkMgr:runWhenOnline(function()
            local ok, data_or_err = client:fetchStories(feed_node.id, { page = fetch_page })
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = data_or_err or _("Failed to load stories."),
                })
                return
            end
            local batch = (data_or_err and data_or_err.stories) or {}
            if fetch_page == 1 then
                feed_node._rss_stories = {}
                feed_node._rss_story_keys = {}
            end
            if #batch == 0 then
                if fetch_page == 1 and #feed_node._rss_stories == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No stories available."),
                    })
                    feed_node._rss_has_more = false
                    return
                end
                feed_node._rss_has_more = false
                if fetch_page > 1 then
                    UIManager:show(InfoMessage:new{
                        text = _("No more stories available."),
                    })
                end
            else
                feed_node._rss_page = fetch_page
                for _, story in ipairs(batch) do
                    appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
                end
                local more = false
                if data_or_err and data_or_err.more_stories ~= nil then
                    more = data_or_err.more_stories and true or false
                else
                    more = #batch > 0
                end
                feed_node._rss_has_more = more
            end
            finalizeMenu()
        end)
        return
    end

    finalizeMenu()
end

function MenuBuilder:showCommaFeedAccount(account)
    if not self.accounts or type(self.accounts.getCommaFeedClient) ~= "function" then
        UIManager:show(InfoMessage:new{
            text = _("CommaFeed integration is not available."),
        })
        return
    end

    local client, err = self.accounts:getCommaFeedClient(account)
    if not client then
        UIManager:show(InfoMessage:new{
            text = err or _("Unable to open CommaFeed account."),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, tree_or_err = client:buildTree()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = tree_or_err or _("Failed to load CommaFeed subscriptions."),
            })
            return
        end

        self:showCommaFeedNode(account, client, tree_or_err)
    end)
end

function MenuBuilder:showCommaFeedNode(account, client, node)
    local children = node and node.children or {}
    local entries = {}
    for _, child in ipairs(children) do
        if child.kind == "folder" then
            local normal_callback = function()
                self:showCommaFeedNode(account, client, child)
            end
            table.insert(entries, {
                text = child.title or _("Untitled folder"),
                callback = normal_callback,
            })
        elseif child.kind == "feed" then
            local normal_callback = function()
                self:showCommaFeedFeed(account, client, child)
            end
            local unread_count = child.feed.unreadCount or 0
            local display_title = child.title or _("Untitled feed")
            if unread_count > 0 then
                display_title = display_title .. " (" .. tostring(unread_count) .. ")"
            end
            table.insert(entries, {
                text = display_title,
                callback = normal_callback,
                hold_callback = function()
                    self:createLongPressMenuForNode(account, client, child, normal_callback)
                end,
                hold_keep_menu_open = true,
            })
        end
    end

    local function menu_hold_handler(_, item)
        if item and type(item.hold_callback) == "function" then
            item.hold_callback()
        end
        return true
    end

    if #entries == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No feeds available."),
        })
        return
    end

    local menu_instance = Menu:new{
        title = node and node.title or (account and account.name) or _("CommaFeed"),
        item_table = entries,
        onMenuHold = triggerHoldCallback,
    }
    self:showMenu(menu_instance, function()
        self:showCommaFeedNode(account, client, node)
    end)

    if menu_instance then
        menu_instance.onMenuHold = triggerHoldCallback
    end
end

function MenuBuilder:showCommaFeedFeed(account, client, feed_node, opts)
    opts = opts or {}
    feed_node._rss_stories = feed_node._rss_stories or {}
    feed_node._rss_story_keys = feed_node._rss_story_keys or {}
    feed_node._rss_page = feed_node._rss_page or 0
    feed_node._account_name = account.name
    feed_node._rss_reader = self.reader

    if self.reader and type(self.reader.getFeedState) == "function" then
        local stored_state = self.reader:getFeedState(account.name, feed_node.id)
        if stored_state then
            if type(stored_state.stories) == "table" and #stored_state.stories > 0 then
                feed_node._rss_stories = util.tableDeepCopy(stored_state.stories)
                feed_node._rss_story_keys = util.tableDeepCopy(stored_state.story_keys or {})
                feed_node._rss_page = stored_state.current_page or feed_node._rss_page
                feed_node._rss_has_more = stored_state.has_more or feed_node._rss_has_more
            end
            if type(stored_state.menu_page) == "number" then
                feed_node._rss_menu_page = feed_node._rss_menu_page or stored_state.menu_page
                if not opts.menu_page then
                    opts.menu_page = stored_state.menu_page
                end
            end
        end
    end

    local fetch_page
    if opts.reuse then
        fetch_page = nil
    elseif opts.page then
        fetch_page = opts.page
    elseif feed_node._rss_page == 0 then
        fetch_page = 1
    end

    local function finalizeMenu()
        local stories = feed_node._rss_stories or {}
        if #stories == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No stories available."),
            })
            return
        end

        local context = {
            feed_type = "commafeed",
            account = account,
            client = client,
            feed_node = feed_node,
            feed_id = feed_node.id,
            refresh = function()
                self:showCommaFeedFeed(account, client, feed_node, { reuse = true })
            end,
            force_refresh_on_close = false,
        }

        local entries = {}
        for index, story in ipairs(stories) do
            normalizeStoryLink(story)
            table.insert(entries, {
                text = decoratedStoryTitle(story, true),
                bold = isUnread(story),
                callback = function()
                    self:showStory(stories, index, function(action, payload)
                        self:handleStoryAction(stories, index, action, payload, context)
                    end, nil, { disable_story_mutators = true }, context)
                end,
            })
        end

        local current_menu = self.reader and self.reader.current_menu_info and self.reader.current_menu_info.menu
        local menu_instance
        if current_menu and current_menu._rss_feed_node == feed_node then
            menu_instance = current_menu
            if menu_instance.setTitle then
                menu_instance:setTitle(feed_node.title or (account and account.name) or _("CommaFeed"))
            end
            if menu_instance.switchItemTable then
                menu_instance:switchItemTable(nil, entries)
            end
        else
            menu_instance = Menu:new{
                title = feed_node.title or (account and account.name) or _("CommaFeed"),
                item_table = entries,
                multilines_forced = true,
            }
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
            self:showMenu(menu_instance, function()
                self:showCommaFeedFeed(account, client, feed_node, { reuse = true })
            end)
        end

        if menu_instance then
            context.menu_instance = menu_instance
            menu_instance._rss_feed_node = feed_node
            ensureMenuCloseHook(menu_instance)
            trackMenuPage(menu_instance, feed_node)
        end

        if menu_instance and menu_instance.page_info then
            local next_page = (feed_node._rss_page or 1) + 1
            local existing_button_index
            for idx = #menu_instance.page_info, 1, -1 do
                local widget = menu_instance.page_info[idx]
                if widget and widget._rss_is_more_button then
                    existing_button_index = idx
                    break
                end
            end
            if existing_button_index then
                table.remove(menu_instance.page_info, existing_button_index)
                table.remove(menu_instance.page_info, existing_button_index - 1)
            end
            if feed_node._rss_has_more then
                local spacer = HorizontalSpan:new{ width = Screen:scaleBySize(16) }
                local load_more_button = Button:new{
                    text = _("More"),
                    bordersize = 0,
                    show_parent = menu_instance.show_parent or menu_instance,
                    callback = function()
                        self:showCommaFeedFeed(account, client, feed_node, { page = next_page })
                    end,
                }
                load_more_button._rss_is_more_button = true
                table.insert(menu_instance.page_info, spacer)
                table.insert(menu_instance.page_info, load_more_button)
            end
            if menu_instance.page_info.resetLayout then
                menu_instance.page_info:resetLayout()
            end
        end

        restoreMenuPage(menu_instance, feed_node, opts.menu_page or feed_node._rss_menu_page)
    end

    if fetch_page then
        NetworkMgr:runWhenOnline(function()
            local ok, data_or_err = client:fetchStories(feed_node.id, { page = fetch_page })
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = data_or_err or _("Failed to load stories."),
                })
                return
            end
            local batch = (data_or_err and data_or_err.stories) or {}
            if fetch_page == 1 then
                feed_node._rss_stories = {}
                feed_node._rss_story_keys = {}
            end
            if #batch == 0 then
                if fetch_page == 1 and #feed_node._rss_stories == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No stories available."),
                    })
                    feed_node._rss_has_more = false
                    return
                end
                feed_node._rss_has_more = false
                if fetch_page > 1 then
                    UIManager:show(InfoMessage:new{
                        text = _("No more stories available."),
                    })
                end
            else
                feed_node._rss_page = fetch_page
                for _, story in ipairs(batch) do
                    appendUniqueStory(feed_node._rss_stories, feed_node._rss_story_keys, story)
                end
                local more = false
                if data_or_err and data_or_err.more_stories ~= nil then
                    more = data_or_err.more_stories and true or false
                else
                    more = #batch > 0
                end
                feed_node._rss_has_more = more
            end
            finalizeMenu()
        end)
        return
    end

    finalizeMenu()
end

return MenuBuilder
