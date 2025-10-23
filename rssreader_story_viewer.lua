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

local Screen = Device.screen

local StoryViewer = {}
StoryViewer.__index = StoryViewer

local DEFAULT_STORY_TITLE = _("Untitled story")

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
        local disable_mutators = true  -- Temporarily force disable
        local first_row = {}
        if not disable_mutators then
            table.insert(first_row, {
                text = _("Mark as unread"),
                callback = function()
                    on_action("mark_unread", story)
                end,
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
                    on_action("go_to_link", story)
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
    local temp_dir = lfs.currentdir() .. "/cache/rssreader"
    util.makePath(temp_dir)
    return temp_dir
end

local function writeHtmlDocument(html_body, filepath)
    local file = io.open(filepath, "w")
    if not file then
        return false
    end
    file:write("<html><head><meta charset=\"utf-8\"></head><body>")
    file:write(html_body or "")
    file:write("</body></html>")
    file:close()
    return true
end

local function writeHtmlToTempFile(html)
    local temp_dir = ensureTempDirectory()
    story_temp_counter = (story_temp_counter + 1) % 100000
    local filename = string.format("story_%d_%d.html", os.time(), story_temp_counter)
    local filepath = temp_dir .. "/" .. filename
    if writeHtmlDocument(html, filepath) then
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

    local temp_file = writeHtmlToTempFile(html)
    if not temp_file then
        self:_showFallback(story, on_action, on_close, options)
        return
    end

    local screen_width = Device.screen:getWidth()
    local screen_height = Device.screen:getHeight()
    local width = screen_width - Size.padding.fullscreen * 2
    local height = screen_height - Size.padding.fullscreen * 2
    local title = replaceRightSingleQuoteEntities(story.story_title or story.title or DEFAULT_STORY_TITLE)

    local dialog = WidgetContainer:extend{}
    local viewer_dialog

    local function closeAll()
        if viewer_dialog then
            UIManager:close(viewer_dialog)
            viewer_dialog = nil
        end
        UIManager:setDirty(nil, "full")
        if on_close then
            on_close()
        end
    end

    local button_rows = buildToolbarButtons(story, on_action, closeAll, true, {
        include_save = true,
        disable_story_mutators = options and options.disable_story_mutators,
    })
    local button_table = ButtonTable:new{
        width = width,
        buttons = button_rows,
        zero_sep = true,
    }

    local button_height = button_table:getSize().h
    local html_height = height - Size.padding.large * 2 - button_height - Size.padding.default
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
        html_resource_directory = ensureTempDirectory(),
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
    table.insert(content_group, VerticalSpan:new{ width = Size.padding.default })
    table.insert(content_group, button_table)

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
