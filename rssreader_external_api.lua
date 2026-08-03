local util = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local _ = require("gettext")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local ExternalAPI = {}

local function loadRSSReaderConfig()
    package.loaded["rssreader_configuration"] = nil
    local ok, config = pcall(require, "rssreader_configuration")
    if ok and type(config) == "table" then
        return config
    end
    return {
        accounts = {},
        sanitizers = {
            { type = "fivefilters", active = true, order = 1 },
            { type = "diffbot", active = false, order = 2 },
            { type = "instaparser", active = false, order = 3 },
        },
        features = {}
    }
end

function ExternalAPI.isAvailable()
    local ok, utils = pcall(require, "rssreader_menu_utils")
    if not ok or not utils then
        return false
    end
    return utils.EpubDownloadBackend ~= nil
end

function ExternalAPI.openSanitized(url, title, on_complete)
    if not ExternalAPI.isAvailable() then
        logger.warn("RSSReader ExternalAPI: not available")
        if on_complete then
            on_complete(nil, "rssreader_not_available")
        end
        return
    end
    
    local utils = require("rssreader_menu_utils")
    
    local fake_story = {
        permalink = url,
        href = url,
        link = url,
        title = title or url,
        _skip_title_heading = true,
    }
    
    local config = loadRSSReaderConfig()
    local builder = {
        accounts = {
            config = config
        }
    }
    
    NetworkMgr:runWhenOnline(function()
        utils.downloadStoryToCache(fake_story, builder, on_complete)
    end)
end

function ExternalAPI.saveSanitized(url, title, target_directory, on_complete)
    if not ExternalAPI.isAvailable() then
        logger.warn("RSSReader ExternalAPI: not available")
        if on_complete then
            on_complete(nil, "rssreader_not_available")
        end
        return
    end
    
    local utils = require("rssreader_menu_utils")
    
    local fake_story = {
        permalink = url,
        href = url,
        link = url,
        title = title or url,
    }
    
    local config = loadRSSReaderConfig()
    local builder = {
        accounts = {
            config = config
        }
    }
    
    if target_directory and target_directory ~= "" and util.pathExists(target_directory) then
        if not builder.accounts.config.features then
            builder.accounts.config.features = {}
        end
        builder.accounts.config.features.sanitized_save_path = target_directory
    end
    
    NetworkMgr:runWhenOnline(function()
        local save_dir = utils.determineSanitizedSaveDirectory(builder)
        
        local info = InfoMessage:new{
            text = _("Downloading and sanitizing link..."),
            timeout = 2,
        }
        UIManager:show(info)
        UIManager:forceRePaint()
        
        local filename = utils.safeFilenameFromStory(fake_story)
        local base_name = filename:gsub("%.html$", "")
        
        local download_images = false
        if builder.accounts and builder.accounts.config then
            download_images = util.tableGetValue(builder.accounts.config, "features", "download_images_when_sanitize_successful")
            if download_images == nil then download_images = true end
        end
        
        utils.fetchStoryContent(fake_story, builder, function(content, err, fetch_info)
            UIManager:close(info)
            UIManager:forceRePaint()
            
            if not content then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Failed to download link: %s"), err or "unknown error"),
                    timeout = 3,
                })
                if on_complete then
                    on_complete(nil, err)
                end
                return
            end
            
            local images_requested = download_images and (fetch_info and fetch_info.images_requested)
            local html_for_epub = fetch_info and fetch_info.html_for_epub
            local should_create_epub = images_requested and type(html_for_epub) == "string" and html_for_epub ~= ""
            local local_assets = fetch_info and fetch_info.local_assets
            
            local page_title = content:match([[<title[^>]*>(.-)</title>]])
            if page_title then
                page_title = util.htmlToPlainTextIfHtml(page_title)
            end
            
            if not page_title or page_title == "" then
                page_title = title or url
            end
            
            local title_for_filename = page_title
            if not title_for_filename or title_for_filename == "" then
                title_for_filename = url
            end
            
            title_for_filename = title_for_filename:gsub("^%s+", ""):gsub("%s+$", "")
            
            local safe_title = utils.sanitizeFilenameComponent(title_for_filename)
            local title_filename = safe_title .. ".html"
            
            if page_title then
                page_title = page_title:gsub("^%s+", ""):gsub("%s+$", "")
            end
            
            if should_create_epub and utils.EpubDownloadBackend then
                if html_for_epub and page_title and page_title ~= "" then
                    local new_title_tag = "<title>" .. util.htmlEscape(page_title) .. "</title>"
                    html_for_epub = html_for_epub:gsub("<title[^>]*>.-</title>", new_title_tag)
                end
                
                local epub_path = utils.buildUniqueTargetPathWithExtension(save_dir, safe_title, "epub")
                
                local UI = require("ui/trapper")
                UI:reset()
                
                local ok, result_or_err = pcall(function()
                    return utils.EpubDownloadBackend:createEpub(
                        epub_path,
                        html_for_epub,
                        url,
                        download_images,
                        _("Creating EPUB..."),
                        true,
                        nil,
                        nil,
                        local_assets
                    )
                end)
                
                UIManager:nextTick(function()
                    UIManager:close(UIManager:getTopmostVisibleWidget())
                    
                    if ok and result_or_err then
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Saved to: %s"), epub_path),
                            timeout = 3,
                        })
                        if on_complete then
                            on_complete(epub_path, nil)
                        end
                    else
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Failed to create EPUB: %s"), result_or_err or "unknown error"),
                            timeout = 3,
                        })
                        if on_complete then
                            on_complete(nil, result_or_err or "epub_creation_failed")
                        end
                    end
                end)
            else
                local html_path = utils.buildUniqueTargetPathWithExtension(save_dir, safe_title, "html")
                
                if page_title and page_title ~= "" then
                    local new_title_tag = "<title>" .. util.htmlEscape(page_title) .. "</title>"
                    content = content:gsub("<title[^>]*>.-</title>", new_title_tag)
                end
                
                local file = io.open(html_path, "w")
                if file then
                    file:write(content)
                    file:close()
                    
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Saved to: %s"), html_path),
                        timeout = 3,
                    })
                    if on_complete then
                        on_complete(html_path, nil)
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Failed to save file"),
                        timeout = 3,
                    })
                    if on_complete then
                        on_complete(nil, "file_write_failed")
                    end
                end
            end
        end)
    end)
end

return ExternalAPI
