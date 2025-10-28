local BD = require("ui/bidi")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HtmlSanitizer = require("rssreader_html_sanitizer")
local InfoMessage = require("ui/widget/infomessage")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextViewer = require("ui/widget/textviewer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonTable = require("ui/widget/buttontable")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local HtmlResources = require("rssreader_html_resources")
local urlmod = require("socket.url")

local Screen = Device.screen

local StoryViewer = {}
StoryViewer.__index = StoryViewer

local DEFAULT_STORY_TITLE = _("Untitled story")

local ENTITY_REPLACEMENTS = {
    ["&#8216;"] = "‘",
    ["&#8217;"] = "’",
}

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

local function resolveStoryLink(story)
    if type(story) ~= "table" then
        return nil
    end
    return story.permalink or story.href or story.link or story.story_permalink or story.url
end

local function rewriteRelativeResourceUrls(html, page_url)
    if type(html) ~= "string" or html == "" then
        return html
    end
    if type(page_url) ~= "string" or page_url == "" then
        return html
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
                local resolved = urlmod.absolute(page_url, value)
                if resolved and resolved ~= "" then
                    return prefix .. resolved .. suffix
                end
            end
            return prefix .. value .. suffix
        end)
    end

    absolutizeAttribute("(<%s*[^>]-[Hh][Rr][Ee][Ff]%s*=%s*['\"])%s*(.-)%s*([\"'])")
    absolutizeAttribute("(<%s*[^>]-[Ss][Rr][Cc]%s*=%s*['\"])%s*(.-)%s*([\"'])")

    return html
end

local function storyIsUnread(story)
    if type(story) ~= "table" then
        return false
    end
    if story._rss_is_read ~= nil then
        return not story._rss_is_read
    end
    local fields = { "read_status", "read", "story_read" }
    for _, key in ipairs(fields) do
        local parsed = parseReadFlag(story[key])
        if parsed ~= nil then
            return not parsed
        end
    end
    return true
end

local function replaceRightSingleQuoteEntities(text)
    if type(text) ~= "string" then
        return text
    end
    local replaced = text:gsub("&#%d+;", function(entity)
        return ENTITY_REPLACEMENTS[entity] or entity
    end)
    return replaced
end

local function normalizeImageUrl(value)
    if type(value) == "table" then
        value = value.url or value.href or value.src
    end
    if type(value) ~= "string" then
        return nil
    end
    local util_strip = type(util) == "table" and type(rawget(util, "stripCData")) == "function" and rawget(util, "stripCData") or nil
    if util_strip then
        value = util_strip(value)
    else
        local global_strip = rawget(_G, "stripCData")
        if type(global_strip) == "function" then
            value = global_strip(value)
        end
    end
    value = util.htmlEntitiesToUtf8(value or "")
    value = util.trim(value or "")
    if value == "" or value:find("^data:") then
        return nil
    end
    return value
end

local function pickPreviewImage(story)
    if type(story) ~= "table" then
        return nil
    end
    local tried = {}
    local function consider(value)
        local candidate = normalizeImageUrl(value)
        if candidate and not tried[candidate] then
            return candidate
        end
    end

    local direct_candidates = {
        story.preview_image,
        story.primary_image,
        story.story_image,
        story.image,
        story.thumbnail,
        story.media_thumbnail,
        story.media_content,
    }
    for _, candidate in ipairs(direct_candidates) do
        local chosen = consider(candidate)
        if chosen then
            return chosen
        end
    end

    if type(story.image_urls) == "table" then
        for _, candidate in ipairs(story.image_urls) do
            local chosen = consider(candidate)
            if chosen then
                return chosen
            end
        end
    end

    return nil
end

local function htmlContainsImageSrc(html, image_url)
    if type(html) ~= "string" or type(image_url) ~= "string" then
        return false
    end
    local escaped = image_url:gsub("([^%w])", "%%%1")
    local pattern = "<[Ii][Mm][Gg][^>]-[Ss][Rr][Cc]%s*=%s*[\"']%s*" .. escaped .. "%s*[\"']"
    return html:match(pattern) ~= nil
end

local function escapeHtmlAttribute(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("[&\"'<>]", {
        ["&"] = "&amp;",
        ['"'] = "&quot;",
        ["'"] = "&#39;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
    }))
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

local function sanitizeHtml(html)
    if type(html) ~= "string" or html == "" then
        return nil
    end
    return HtmlSanitizer.sanitize(html)
end

local function fallbackTextFromStory(story)
    local parts = {}
    local title = replaceRightSingleQuoteEntities(story.story_title or story.title)
    if title then
        table.insert(parts, title)
        table.insert(parts, "")
    end
    local summary = story.story_content or story.summary or story.content
    if summary then
        local plain_text = util.htmlToPlainText(summary)
        table.insert(parts, replaceRightSingleQuoteEntities(plain_text))
    end
    if story.permalink then
        table.insert(parts, "")
        table.insert(parts, string.format(_("Original link: %s"), story.permalink))
    end
    return table.concat(parts, "\n")
end

local function buildToolbarButtons(story, on_action, close_handler, include_close, options)
    local rows = {}
    if on_action then
        local disable_mutators = false  -- Temporarily force disable
        if options then
            if options.is_api_version then
                disable_mutators = false
            elseif options.disable_story_mutators then
                disable_mutators = true
            end
        end
        local allow_mark_unread = true
        if options and options.allow_mark_unread ~= nil then
            allow_mark_unread = options.allow_mark_unread and true or false
        end
        local is_read = not storyIsUnread(story)
        local keep_unread_label = is_read and _("Mark as unread") or _("Keep unread")
        local first_row = {}
        if not disable_mutators and allow_mark_unread then
            table.insert(first_row, {
                text = keep_unread_label,
                callback = function()
                    on_action("mark_unread", story)
                end,
                disabled = not allow_mark_unread,
            })
        end
        if options and options.include_save then
            table.insert(first_row, {
                text = _("Save"),
                callback = function()
                    on_action("save_story", story)
                end,
            })
        end
        if #first_row > 0 then
            table.insert(rows, first_row)
        end

        local navigation_row = {
            {
                text = _("Open"),
                callback = function()
                    on_action("go_to_link", {
                        story = story,
                        close_story = close_handler,
                    })
                end,
                disabled = not story.permalink,
            },
            {
                text = _("Next"),
                callback = function()
                    if close_handler then
                        close_handler()
                    end
                    on_action("next_story", story)
                end,
            },
        }
        if disable_mutators then
            navigation_row[2].disabled = false
        end
        if not disable_mutators then
            table.insert(navigation_row, {
                text = _("Next unread"),
                callback = function()
                    if close_handler then
                        close_handler()
                    end
                    on_action("next_unread", story)
                end,
            })
        end
        table.insert(rows, navigation_row)
    end

    if include_close ~= false then
        table.insert(rows, {
            {
                text = _("Close"),
                callback = function()
                    if close_handler then
                        close_handler()
                    end
                end,
            },
        })
    end

    return rows
end

local story_temp_counter = 0

local function ensureTempDirectory()
    local temp_dir = HtmlResources.ensureBaseDirectory()
    if not temp_dir then
        temp_dir = lfs.currentdir() .. "/cache/rssreader"
        util.makePath(temp_dir)
    end
    return temp_dir
end

local function writeHtmlDocument(html_body, filepath, title)
    local file = io.open(filepath, "w")
    if not file then
        return false
    end
    file:write("<html><head><meta charset=\"utf-8\">")
    if type(title) == "string" and title ~= "" then
        file:write("<title>" .. util.htmlEscape(title) .. "</title>")
    end
    file:write("</head><body>")
    file:write(html_body or "")
    file:write("</body></html>")
    file:close()
    return true
end

local function writeHtmlToTempFile(html, title)
    local temp_dir = ensureTempDirectory()
    story_temp_counter = (story_temp_counter + 1) % 100000
    local filename = string.format("story_%d_%d.html", os.time(), story_temp_counter)
    local filepath = temp_dir .. "/" .. filename
    if writeHtmlDocument(html, filepath, title) then
        return filepath
    end
    return nil
end

function StoryViewer:new(opts)
    local instance = setmetatable({}, self)
    if opts then
        for key, value in pairs(opts) do
            instance[key] = value
        end
    end
    return instance
end

function StoryViewer:_showFallback(story, on_action, on_close, options)
    local text = fallbackTextFromStory(story)
    local close_scheduled = false
    local text_viewer

    local function closeViewer()
        if close_scheduled then
            return
        end
        close_scheduled = true
        if text_viewer then
            UIManager:close(text_viewer)
        end
        if on_close then
            on_close()
        end
    end

    local button_options = {
        include_save = true,
        disable_story_mutators = options and options.disable_story_mutators,
        is_api_version = options and options.is_api_version,
        allow_mark_unread = options and options.allow_mark_unread,
    }
    local buttons = on_action and buildToolbarButtons(story, on_action, closeViewer, false, button_options) or nil

    text_viewer = TextViewer:new{
        title = replaceRightSingleQuoteEntities(story.story_title or story.title or DEFAULT_STORY_TITLE),
        title_multilines = true,
        text = text,
        buttons_table = buttons,
        add_default_buttons = true,
    }

    UIManager:show(text_viewer)

    text_viewer.close_callback = function()
        if close_scheduled then
            return
        end
        close_scheduled = true
        if on_close then
            on_close()
        end
    end
end

function StoryViewer:showStory(story, on_action, on_close, options)
    if type(story) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Could not open story."),
        })
        return
    end

    if on_action and story and not story._rss_marked_read then
        story._rss_marked_read = true
        logger.warn("DEBUG: story viewer calling on_action mark_read for story", story.id or story.title)
        on_action("mark_read", story)
    end

    local html = story.story_content or story.content
    if type(html) == "string" and html ~= "" then
        html = HtmlSanitizer.disableFontSizeDeclarations(html)
    end
    html = sanitizeHtml(html)
    html = replaceRightSingleQuoteEntities(html)
    if not html then
        self:_showFallback(story, on_action, on_close, options)
        return
    end

    -- Add H3 title at the beginning of HTML content with author and date
    local base_title = replaceRightSingleQuoteEntities(story.story_title or story.title or DEFAULT_STORY_TITLE)
    local heading_title = base_title
    local raw_author = story.author or story.creator
    local author
    if type(raw_author) == "function" then
        local ok, value = pcall(raw_author, story)
        if ok then
            raw_author = value
        else
            raw_author = nil
        end
    end
    if type(raw_author) == "table" then
        raw_author = table.concat(raw_author, ", ")
    end
    if type(raw_author) == "string" and raw_author ~= "" then
        author = raw_author
    end
    if author then
        author = replaceRightSingleQuoteEntities(author)
        heading_title = heading_title .. " - " .. author
    end
    local date_str = formatStoryDate(story)
    if date_str then
        heading_title = heading_title .. " - " .. date_str
    end
    local heading_html = "<h3>" .. heading_title .. "</h3>"

    local show_images = options and options.show_images_in_preview and true or false
    local screen_width = Device.screen:getWidth()

    local preview_image_url
    if show_images then
        preview_image_url = pickPreviewImage(story)
        if preview_image_url and htmlContainsImageSrc(html, preview_image_url) then
            preview_image_url = nil
        end
    end

    local preview_fragment = ""
    if preview_image_url then
        local escaped_url = escapeHtmlAttribute(preview_image_url)
        local alt_text = escapeHtmlAttribute(base_title or "")
        local min_width_px = 0
        if type(screen_width) == "number" and screen_width > 0 then
            min_width_px = math.floor(5 * screen_width / 6)
        end
        local width_style = ""
        local width_attr = ""
        if min_width_px > 0 then
            width_style = string.format("width:%dpx;", min_width_px)
            width_attr = string.format(' width="%d"', min_width_px)
        end
        preview_fragment = string.format('<figure class="rss-preview-image" style="display:flex;justify-content:center;margin:0 0 1em;"><img src="%s" alt="%s"%s style="%smax-width:100%%;height:auto;"/></figure><br>', escaped_url, alt_text, width_attr, width_style)
    end

    html = heading_html .. preview_fragment .. (html or "")

    local temp_dir = ensureTempDirectory()
    local asset_cleanup
    local assets_root

    if show_images then
        local story_link = resolveStoryLink(story)
        if story_link then
            html = rewriteRelativeResourceUrls(html, story_link)
        end

        local asset_paths = HtmlResources.prepareAssetPaths(temp_dir, string.format("preview_%d", os.time()))
        if asset_paths then
            local rewritten, assets = HtmlResources.downloadAndRewrite(html, story_link, asset_paths)
            if rewritten and rewritten ~= "" then
                html = rewritten
            end
            if assets and assets.assets_root then
                assets_root = assets.assets_root
                asset_cleanup = function()
                    HtmlResources.cleanupAssets(assets_root)
                    assets_root = nil
                end
            end
        end
    end

    local temp_file = writeHtmlToTempFile(html, base_title)
    if not temp_file then
        if asset_cleanup then
            asset_cleanup()
        end
        self:_showFallback(story, on_action, on_close, options)
        return
    end

    local screen_height = Device.screen:getHeight()
    local width = screen_width - Size.padding.fullscreen * 2
    local height = screen_height - Size.padding.fullscreen * 2
    local title = base_title

    local dialog = WidgetContainer:extend{}
    local viewer_dialog

    local function closeAll()
        if viewer_dialog then
            UIManager:close(viewer_dialog)
            viewer_dialog = nil
        end
        UIManager:setDirty(nil, "full")
        if asset_cleanup then
            asset_cleanup()
        end
        if on_close then
            on_close()
        end
    end

    local button_rows = buildToolbarButtons(story, on_action, closeAll, true, {
        include_save = true,
        disable_story_mutators = options and options.disable_story_mutators,
        is_api_version = options and options.is_api_version,
        allow_mark_unread = options and options.allow_mark_unread,
    })
    local button_table = ButtonTable:new{
        width = width,
        buttons = button_rows,
        zero_sep = true,
    }

    local button_padding = Size.padding.default
    local button_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = button_padding,
        bordersize = 0,
        [1] = button_table,
    }

    local button_height = button_table:getSize().h + button_padding * 2
    local html_height = height - Size.padding.large * 2 - button_height
    if html_height < Screen:scaleBySize(120) then
        html_height = Screen:scaleBySize(120)
    end

    local html_widget = ScrollHtmlWidget:new{
        dialog = nil,
        width = width,
        height = html_height,
        html_body = html,
        css = nil,
        is_xhtml = true,
        html_resource_directory = temp_dir,
    }

    local html_container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        bordersize = 0,
        [1] = html_widget,
    }

    local content_group = VerticalGroup:new{}
    content_group[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        bordersize = 0,
        [1] = TitleBar:new{
            title = BD.wrap(title),
        },
    }
    table.insert(content_group, html_container)
    table.insert(content_group, button_frame)

    viewer_dialog = dialog:new{
        _is_story_viewer = true,
        dimen = Geom:new{ x = 0, y = 0, w = width, h = height },
        [1] = content_group,
    }

    html_widget.dialog = viewer_dialog

    button_table.show_parent = viewer_dialog

    UIManager:show(viewer_dialog)
    UIManager:setDirty(viewer_dialog, "full")

    viewer_dialog.close_callback = function()
        pcall(os.remove, temp_file)
        if on_close then
            on_close()
        end
    end
end

return StoryViewer
