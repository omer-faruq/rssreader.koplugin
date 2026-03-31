local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local OPML = {}

-- ---------------------------------------------------------------------------
-- OPML Import
-- ---------------------------------------------------------------------------

-- Decode XML entities in attribute values
local function decodeXmlEntities(s)
    if not s then return nil end
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    return s
end

-- Encode XML entities for export
local function encodeXmlEntities(s)
    if not s then return "" end
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&apos;")
    return s
end

-- Extract a named attribute from a tag string
local function attr(tag, name)
    -- Try double quotes first, then single quotes
    local value = tag:match(name .. '%s*=%s*"([^"]*)"')
    if not value then
        value = tag:match(name .. "%s*=%s*'([^']*)'")
    end
    return decodeXmlEntities(value)
end

-- Parse a flat list of <outline> tags and build a tree structure.
-- OPML groups are <outline> tags without xmlUrl that contain child <outline> tags.
-- Leaf feeds are <outline> tags with xmlUrl.
function OPML.parseOPML(content)
    if not content then
        return nil, "No content"
    end

    -- Extract the <body> section
    local body = content:match("<body>(.-)</body>")
    if not body then
        body = content:match("<body>(.*)")
    end
    if not body then
        return nil, "No <body> found in OPML"
    end

    -- Result: array of groups, each group has title + feeds array
    -- Top-level feeds without a group go into a special ungrouped list
    local groups = {}
    local ungrouped_feeds = {}

    -- Strategy: find top-level outline tags that are groups (contain nested outlines)
    -- and top-level outline tags that are feeds (have xmlUrl)
    -- We process the body line-by-line approach using pattern matching

    -- First, try to find group outlines (ones that have children)
    -- Pattern: <outline ...> ... </outline>  (multi-line, contains child outlines)
    -- Also handle self-closing leaf outlines: <outline ... />

    -- Split into top-level outline blocks
    local pos = 1
    while pos <= #body do
        -- Find the next <outline tag
        local tag_start, tag_end = body:find("<outline%s", pos)
        if not tag_start then break end

        -- Check if this is a self-closing tag
        local self_close_end = body:find("/>", tag_end)
        local open_close_end = body:find(">", tag_end)

        if not open_close_end then break end

        if self_close_end and self_close_end < open_close_end then
            -- Self-closing <outline ... />  => this is a leaf feed
            local tag_str = body:sub(tag_start, self_close_end + 1)
            local xml_url = attr(tag_str, "xmlUrl")
            if xml_url then
                local title = attr(tag_str, "title") or attr(tag_str, "text") or xml_url
                table.insert(ungrouped_feeds, { title = title, url = xml_url })
            end
            pos = self_close_end + 2
        else
            -- Opening tag <outline ...>
            local tag_str = body:sub(tag_start, open_close_end)
            local xml_url = attr(tag_str, "xmlUrl")

            if xml_url then
                -- This is a feed with an opening tag but no children
                local title = attr(tag_str, "title") or attr(tag_str, "text") or xml_url
                table.insert(ungrouped_feeds, { title = title, url = xml_url })
                -- Skip to closing tag or next element
                local close_tag = body:find("</outline>", open_close_end)
                if close_tag then
                    pos = close_tag + 10
                else
                    pos = open_close_end + 1
                end
            else
                -- This is a group/folder outline
                local group_title = attr(tag_str, "title") or attr(tag_str, "text") or "Unnamed Group"

                -- Find the matching </outline> for this group
                -- We need to handle nesting: count open/close outline tags
                local depth = 1
                local search_pos = open_close_end + 1
                local group_end = nil
                while depth > 0 and search_pos <= #body do
                    local next_open = body:find("<outline%s", search_pos) or body:find("<outline>", search_pos)
                    local next_self_close = body:find("<outline[^>]*/>", search_pos)
                    local next_close = body:find("</outline>", search_pos)

                    if not next_close then
                        -- Malformed, break
                        group_end = #body
                        break
                    end

                    -- Determine which comes first
                    if next_self_close and next_self_close < next_close and (not next_open or next_self_close <= next_open) then
                        -- Self-closing tag doesn't change depth
                        local sc_end = body:find("/>", next_self_close)
                        search_pos = sc_end and (sc_end + 2) or (next_self_close + 1)
                    elseif next_open and next_open < next_close then
                        -- Check if this open tag is actually self-closing
                        local tag_region_end = body:find(">", next_open)
                        local tag_sc = body:find("/>", next_open)
                        if tag_sc and tag_region_end and tag_sc < tag_region_end then
                            -- Self-closing, skip
                            search_pos = tag_sc + 2
                        else
                            depth = depth + 1
                            search_pos = (tag_region_end or next_open) + 1
                        end
                    else
                        depth = depth - 1
                        if depth == 0 then
                            group_end = next_close + 9 -- length of "</outline>"
                        end
                        search_pos = next_close + 10
                    end
                end

                if not group_end then
                    group_end = #body
                end

                -- Extract the inner content of the group
                local inner = body:sub(open_close_end + 1, group_end - 10)

                -- Parse child outline tags (feeds inside this group)
                local group_feeds = {}
                for child_tag in inner:gmatch("<outline([^>]-)/>") do
                    local child_url = attr(child_tag, "xmlUrl")
                    if child_url then
                        local child_title = attr(child_tag, "title") or attr(child_tag, "text") or child_url
                        table.insert(group_feeds, { title = child_title, url = child_url })
                    end
                end
                -- Also match <outline ...>...</outline> leaves inside the group
                for child_tag in inner:gmatch("<outline([^>]-)>[^<]*</outline>") do
                    local child_url = attr(child_tag, "xmlUrl")
                    if child_url then
                        local child_title = attr(child_tag, "title") or attr(child_tag, "text") or child_url
                        -- Avoid duplicates
                        local found = false
                        for _, f in ipairs(group_feeds) do
                            if f.url == child_url then found = true; break end
                        end
                        if not found then
                            table.insert(group_feeds, { title = child_title, url = child_url })
                        end
                    end
                end

                if #group_feeds > 0 then
                    table.insert(groups, { title = group_title, feeds = group_feeds })
                end

                pos = group_end + 1
            end
        end
    end

    return {
        groups = groups,
        ungrouped_feeds = ungrouped_feeds,
    }
end

-- Read an OPML file and return parsed data
function OPML.importFromFile(filepath)
    local f, err = io.open(filepath, "r")
    if not f then
        return nil, "Cannot open file: " .. tostring(err)
    end
    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then
        return nil, "File is empty"
    end

    return OPML.parseOPML(content)
end

-- Serialize a Lua table to a pretty-printed Lua source string
-- (for writing rssreader_local_defaults.lua and rssreader_configuration.lua)
local function serializeValue(val, indent)
    indent = indent or ""
    local next_indent = indent .. "    "
    local t = type(val)

    if t == "string" then
        -- Use %q for safe quoting
        return string.format("%q", val)
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "nil" then
        return "nil"
    elseif t == "table" then
        -- Detect if this is an array or a hash table
        local is_array = true
        local max_index = 0
        for k, _ in pairs(val) do
            if type(k) == "number" and k == math.floor(k) and k > 0 then
                if k > max_index then max_index = k end
            else
                is_array = false
                break
            end
        end
        if is_array and max_index == #val then
            -- Array
            local parts = {}
            table.insert(parts, "{\n")
            for i, v in ipairs(val) do
                table.insert(parts, next_indent .. serializeValue(v, next_indent) .. ",\n")
            end
            table.insert(parts, indent .. "}")
            return table.concat(parts)
        else
            -- Hash table
            local parts = {}
            table.insert(parts, "{\n")
            -- Sort keys for deterministic output
            local keys = {}
            for k, _ in pairs(val) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local v = val[k]
                local key_str
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_str = k
                else
                    key_str = "[" .. serializeValue(k) .. "]"
                end
                table.insert(parts, next_indent .. key_str .. " = " .. serializeValue(v, next_indent) .. ",\n")
            end
            table.insert(parts, indent .. "}")
            return table.concat(parts)
        end
    end
    return "nil"
end

-- Build the Lua source for rssreader_local_defaults.lua from the data table
function OPML.serializeLocalDefaults(data)
    local lines = {}
    table.insert(lines, "return {\n")
    table.insert(lines, "    accounts = {\n")
    -- Sort account names for deterministic output
    local account_names = {}
    for name, _ in pairs(data.accounts) do
        table.insert(account_names, name)
    end
    table.sort(account_names)

    for _, name in ipairs(account_names) do
        local account = data.accounts[name]
        table.insert(lines, '        ["' .. name .. '"] = {\n')

        -- Top-level feeds
        if account.feeds and #account.feeds > 0 then
            table.insert(lines, "            feeds = {\n")
            for _, feed in ipairs(account.feeds) do
                table.insert(lines, string.format('                { title = %q, url = %q },\n', feed.title or "", feed.url or ""))
            end
            table.insert(lines, "            },\n")
        end

        -- Groups
        if account.groups and #account.groups > 0 then
            table.insert(lines, "            groups = {\n")
            for _, group in ipairs(account.groups) do
                table.insert(lines, "                {\n")
                table.insert(lines, string.format('                    title = %q,\n', group.title or ""))
                if group.description then
                    table.insert(lines, string.format('                    description = %q,\n', group.description))
                end
                table.insert(lines, "                    feeds = {\n")
                for _, feed in ipairs(group.feeds or {}) do
                    table.insert(lines, string.format('                        { title = %q, url = %q },\n', feed.title or "", feed.url or ""))
                end
                table.insert(lines, "                    },\n")
                table.insert(lines, "                },\n")
            end
            table.insert(lines, "            },\n")
        end

        table.insert(lines, "        },\n")
    end

    table.insert(lines, "    },\n")
    table.insert(lines, "}\n")
    return table.concat(lines)
end

-- Build the Lua source for rssreader_configuration.lua from the config table
function OPML.serializeConfiguration(config)
    local lines = {}
    table.insert(lines, "return {\n")
    table.insert(lines, "    accounts = {\n")

    for _, account in ipairs(config.accounts or {}) do
        table.insert(lines, "        {\n")
        table.insert(lines, string.format('            name = %q,\n', account.name or ""))
        table.insert(lines, string.format('            type = %q,\n', account.type or "local"))
        table.insert(lines, string.format("            active = %s,\n", tostring(account.active ~= false)))
        if account.font_size then
            table.insert(lines, string.format("            font_size = %d,\n", account.font_size))
        end
        if account.text_alignment then
            table.insert(lines, string.format('            text_alignment = %q,\n', account.text_alignment))
        end
        if account.auto_mark_as_read ~= nil then
            table.insert(lines, string.format("            auto_mark_as_read = %s,\n", tostring(account.auto_mark_as_read)))
        end
        if account.fetch_full_article_on_open ~= nil then
            table.insert(lines, string.format("            fetch_full_article_on_open = %s,\n", tostring(account.fetch_full_article_on_open)))
        end
        if account.auth then
            table.insert(lines, "            auth = {\n")
            if account.auth.base_url then
                table.insert(lines, string.format('                base_url = %q,\n', account.auth.base_url))
            end
            if account.auth.username then
                table.insert(lines, string.format('                username = %q,\n', account.auth.username))
            end
            if account.auth.password then
                table.insert(lines, string.format('                password = %q,\n', account.auth.password))
            end
            table.insert(lines, "            },\n")
        end
        if account.special_feeds then
            table.insert(lines, "            special_feeds = {\n")
            for _, sf in ipairs(account.special_feeds) do
                table.insert(lines, "                {\n")
                if sf.id then
                    table.insert(lines, string.format('                    id = %q,\n', sf.id))
                end
                if sf.title then
                    table.insert(lines, string.format('                    title = %q,\n', sf.title))
                end
                table.insert(lines, "                },\n")
            end
            table.insert(lines, "            },\n")
        end
        table.insert(lines, "            options = {\n")
        if account.options then
            for k, v in pairs(account.options) do
                if v == nil then
                    table.insert(lines, string.format("                %s = nil,\n", k))
                else
                    table.insert(lines, string.format("                %s = %s,\n", k, serializeValue(v)))
                end
            end
        else
            table.insert(lines, "                default_folder = nil,\n")
        end
        table.insert(lines, "            },\n")
        table.insert(lines, "        },\n")
    end

    table.insert(lines, "    },\n")

    -- Sanitizers
    if config.sanitizers then
        table.insert(lines, "    sanitizers = {\n")
        for _, san in ipairs(config.sanitizers) do
            table.insert(lines, "        {\n")
            if san.order then
                table.insert(lines, string.format("            order = %d,\n", san.order))
            end
            if san.type then
                table.insert(lines, string.format('            type = %q,\n', san.type))
            end
            table.insert(lines, string.format("            active = %s,\n", tostring(san.active == true)))
            if san.token then
                table.insert(lines, string.format('            token = %q,\n', san.token))
            end
            if san.base_url then
                table.insert(lines, string.format('            base_url = %q,\n', san.base_url))
            end
            table.insert(lines, "        },\n")
        end
        table.insert(lines, "    },\n")
    end

    -- Encoding converters
    if config.encoding_converters then
        table.insert(lines, "    encoding_converters = {\n")
        for _, conv in ipairs(config.encoding_converters) do
            table.insert(lines, "        {\n")
            if conv.order then
                table.insert(lines, string.format("            order = %d,\n", conv.order))
            end
            if conv.type then
                table.insert(lines, string.format('            type = %q,\n', conv.type))
            end
            table.insert(lines, string.format("            active = %s,\n", tostring(conv.active == true)))
            if conv.api_key then
                table.insert(lines, string.format('            api_key = %q,\n', conv.api_key))
            end
            if conv.path then
                table.insert(lines, string.format('            path = %q,\n', conv.path))
            end
            if conv.use_cache ~= nil then
                table.insert(lines, string.format("            use_cache = %s,\n", tostring(conv.use_cache)))
            end
            table.insert(lines, "        },\n")
        end
        table.insert(lines, "    },\n")
    end

    -- Features
    if config.features then
        table.insert(lines, "\n    features = {\n")
        if config.features.default_folder_on_save then
            table.insert(lines, string.format('        default_folder_on_save = %q,\n', config.features.default_folder_on_save))
        else
            table.insert(lines, "        default_folder_on_save = nil,\n")
        end
        if config.features.download_images_when_sanitize_successful ~= nil then
            table.insert(lines, string.format("        download_images_when_sanitize_successful = %s,\n",
                tostring(config.features.download_images_when_sanitize_successful)))
        end
        if config.features.download_images_when_sanitize_unsuccessful ~= nil then
            table.insert(lines, string.format("        download_images_when_sanitize_unsuccessful = %s,\n",
                tostring(config.features.download_images_when_sanitize_unsuccessful)))
        end
        if config.features.show_images_in_preview ~= nil then
            table.insert(lines, string.format("        show_images_in_preview = %s,\n",
                tostring(config.features.show_images_in_preview)))
        end
        table.insert(lines, "    },\n")
    end

    table.insert(lines, "}\n")
    return table.concat(lines)
end

-- ---------------------------------------------------------------------------
-- OPML Export
-- ---------------------------------------------------------------------------

-- Generate OPML XML from the local defaults data
function OPML.generateOPML(local_defaults_data, title)
    title = title or "KOReader RSS Feeds"
    local lines = {}
    table.insert(lines, '<?xml version="1.0" encoding="UTF-8"?>')
    table.insert(lines, '<opml version="2.0">')
    table.insert(lines, "  <head>")
    table.insert(lines, "    <title>" .. encodeXmlEntities(title) .. "</title>")
    table.insert(lines, "    <dateCreated>" .. os.date("!%a, %d %b %Y %H:%M:%S GMT") .. "</dateCreated>")
    table.insert(lines, "  </head>")
    table.insert(lines, "  <body>")

    local accounts = local_defaults_data.accounts or {}
    for account_name, account in pairs(accounts) do
        table.insert(lines, '    <outline text="' .. encodeXmlEntities(account_name) .. '" title="' .. encodeXmlEntities(account_name) .. '">')

        -- Top-level feeds in this account
        if account.feeds then
            for _, feed in ipairs(account.feeds) do
                local feed_title = encodeXmlEntities(feed.title or feed.url or "")
                local feed_url = encodeXmlEntities(feed.url or "")
                table.insert(lines, '      <outline type="rss" text="' .. feed_title .. '" title="' .. feed_title .. '" xmlUrl="' .. feed_url .. '"/>')
            end
        end

        -- Groups
        if account.groups then
            for _, group in ipairs(account.groups) do
                local group_title = encodeXmlEntities(group.title or "Unnamed")
                table.insert(lines, '      <outline text="' .. group_title .. '" title="' .. group_title .. '">')
                for _, feed in ipairs(group.feeds or {}) do
                    local feed_title = encodeXmlEntities(feed.title or feed.url or "")
                    local feed_url = encodeXmlEntities(feed.url or "")
                    table.insert(lines, '        <outline type="rss" text="' .. feed_title .. '" title="' .. feed_title .. '" xmlUrl="' .. feed_url .. '"/>')
                end
                table.insert(lines, "      </outline>")
            end
        end

        table.insert(lines, "    </outline>")
    end

    table.insert(lines, "  </body>")
    table.insert(lines, "</opml>")
    return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- File path helpers
-- ---------------------------------------------------------------------------

function OPML.getPluginDir()
    local path = package.searchpath("rssreader_opml", package.path)
    if path then
        return path:match("(.*/)")
    end
    return lfs.currentdir() .. "/plugins/rssreader.koplugin/"
end

function OPML.getDefaultImportPath()
    return OPML.getPluginDir() .. "import.opml"
end

function OPML.getDefaultExportPath()
    return OPML.getPluginDir() .. "export.opml"
end

-- ---------------------------------------------------------------------------
-- High-level import: merge OPML into existing config files
-- ---------------------------------------------------------------------------

-- Load current configuration
function OPML.loadConfiguration()
    package.loaded["rssreader_configuration"] = nil
    local ok, config = pcall(require, "rssreader_configuration")
    if ok and type(config) == "table" then
        return config
    end
    return { accounts = {} }
end

-- Load current local defaults
function OPML.loadLocalDefaults()
    local path = package.searchpath("rssreader_local_defaults", package.path)
    if not path then
        return { accounts = {} }
    end
    local chunk, err = loadfile(path)
    if not chunk then
        return { accounts = {} }
    end
    local ok2, data = pcall(chunk)
    if not ok2 or type(data) ~= "table" then
        return { accounts = {} }
    end
    return data
end

function OPML.getLocalDefaultsPath()
    local path = package.searchpath("rssreader_local_defaults", package.path)
    if path then return path end
    return OPML.getPluginDir() .. "rssreader_local_defaults.lua"
end

function OPML.getConfigurationPath()
    local path = package.searchpath("rssreader_configuration", package.path)
    if path then return path end
    return OPML.getPluginDir() .. "rssreader_configuration.lua"
end

-- Perform the import: parse OPML, create a new local account, write both files
-- account_name: the name for the new local account
-- Returns true on success, or nil + error message
function OPML.performImport(opml_path, account_name)
    -- Parse OPML
    local parsed, err = OPML.importFromFile(opml_path)
    if not parsed then
        return nil, err
    end

    local total_feeds = #(parsed.ungrouped_feeds or {})
    for _, g in ipairs(parsed.groups or {}) do
        total_feeds = total_feeds + #(g.feeds or {})
    end
    if total_feeds == 0 then
        return nil, "No feeds found in OPML file"
    end

    -- Load existing data
    local config = OPML.loadConfiguration()
    local local_defaults = OPML.loadLocalDefaults()

    if not config.accounts then config.accounts = {} end
    if not local_defaults.accounts then local_defaults.accounts = {} end

    -- Check for duplicate account name
    for _, acc in ipairs(config.accounts) do
        if acc.name == account_name then
            return nil, string.format("Account '%s' already exists in configuration", account_name)
        end
    end

    -- Add account to configuration
    table.insert(config.accounts, {
        name = account_name,
        type = "local",
        active = true,
        options = {
            default_folder = nil,
        },
    })

    -- Build local defaults entry
    local new_account = {}
    if parsed.ungrouped_feeds and #parsed.ungrouped_feeds > 0 then
        new_account.feeds = parsed.ungrouped_feeds
    end
    if parsed.groups and #parsed.groups > 0 then
        new_account.groups = parsed.groups
    end
    local_defaults.accounts[account_name] = new_account

    -- Write configuration file
    local config_path = OPML.getConfigurationPath()
    local config_content = OPML.serializeConfiguration(config)
    local f1, e1 = io.open(config_path, "w")
    if not f1 then
        return nil, "Cannot write configuration: " .. tostring(e1)
    end
    f1:write(config_content)
    f1:close()

    -- Write local defaults file
    local defaults_path = OPML.getLocalDefaultsPath()
    local defaults_content = OPML.serializeLocalDefaults(local_defaults)
    local f2, e2 = io.open(defaults_path, "w")
    if not f2 then
        return nil, "Cannot write local defaults: " .. tostring(e2)
    end
    f2:write(defaults_content)
    f2:close()

    logger.info("RSSReader OPML", "Imported", total_feeds, "feeds into account", account_name)
    return true, total_feeds
end

-- Perform export: read local defaults, generate OPML, write to file
function OPML.performExport(opml_path)
    local local_defaults = OPML.loadLocalDefaults()
    if not local_defaults.accounts or not next(local_defaults.accounts) then
        return nil, "No local accounts found to export"
    end

    local content = OPML.generateOPML(local_defaults, "KOReader RSS Feeds")
    local f, err = io.open(opml_path, "w")
    if not f then
        return nil, "Cannot write OPML file: " .. tostring(err)
    end
    f:write(content)
    f:close()

    -- Count total feeds exported
    local total = 0
    for _, account in pairs(local_defaults.accounts) do
        if account.feeds then
            total = total + #account.feeds
        end
        if account.groups then
            for _, g in ipairs(account.groups) do
                total = total + #(g.feeds or {})
            end
        end
    end

    logger.info("RSSReader OPML", "Exported", total, "feeds to", opml_path)
    return true, total
end

-- Find OPML files in the plugin directory
function OPML.findOPMLFiles()
    local dir = OPML.getPluginDir()
    local files = {}
    for entry in lfs.dir(dir) do
        if entry:match("%.opml$") or entry:match("%.xml$") then
            table.insert(files, {
                name = entry,
                path = dir .. entry,
            })
        end
    end
    table.sort(files, function(a, b) return a.name < b.name end)
    return files
end

return OPML
