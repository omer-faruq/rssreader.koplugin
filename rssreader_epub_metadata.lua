--[[--
Book metadata helpers for the EPUBs built by rssreader_epubdownloadbackend.

Everything here is derived from data the plugin has already downloaded: the
feed entry itself, the article HTML, and the images already written to the
asset cache. No function in this module performs any network request, so
enriching an article's metadata never costs an extra fetch.

Self-contained on purpose: this plugin must keep working on its own, so
nothing is shared with other .koplugin folders.
]]

local util = require("util")

local EpubMetadata = {}

--------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------

local function collapseSpaces(s)
    if not s or s == "" then return "" end
    s = s:gsub("\194\160", " ") -- UTF-8 no-break space, not matched by %s
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function stripTags(s)
    return util.htmlEntitiesToUtf8((s or ""):gsub("<[^>]*>", " "))
end

function EpubMetadata.xmlEsc(s)
    return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

-- Truncate to at most max_chars UTF-8 characters, backing off to a word
-- boundary so the excerpt does not end mid-word.
local function truncateText(text, max_chars)
    local ok, chars = pcall(util.splitToChars, text)
    if not ok or type(chars) ~= "table" or #chars <= max_chars then
        return text
    end
    local truncated = table.concat(chars, "", 1, max_chars)
    local cut = truncated:match("^(.*)%s%S*$")
    if cut and #cut >= #truncated / 2 then
        truncated = cut
    end
    -- Only ASCII punctuation here: %p would risk slicing a UTF-8 sequence.
    truncated = truncated:gsub("[%s,;:%.%-]+$", "")
    return truncated .. "\u{2026}"
end

--- Build a short plain-text excerpt from HTML we already hold.
-- Used both for a feed entry's own summary (which is often HTML) and, when
-- the feed provides none, for the article body itself.
-- @string html source markup
-- @int max_chars character budget (default 320)
-- @treturn string|nil excerpt, or nil when there is not enough prose
function EpubMetadata.buildExcerpt(html, max_chars)
    if type(html) ~= "string" or html == "" then return nil end
    local body = html
    local _, body_open_end = body:find("<body[^>]*>")
    local body_close_start = body:find("</body>")
    if body_open_end and body_close_start and body_close_start > body_open_end then
        body = body:sub(body_open_end + 1, body_close_start - 1)
    end
    body = body:gsub("<script[^>]*>[%s%S]-</script>", " ")
    body = body:gsub("<style[^>]*>[%s%S]-</style>", " ")
    -- Headings and figure captions are labels, not prose: they would make the
    -- excerpt read as a repetition of the title.
    body = body:gsub("<[hH][1-6][^>]*>[%s%S]-</[hH][1-6]%s*>", " ")
    body = body:gsub("<figcaption[^>]*>[%s%S]-</figcaption>", " ")
    body = body:gsub("<figure[^>]*>[%s%S]-</figure>", " ")
    local ok, text = pcall(util.htmlToPlainText, body)
    if not ok or type(text) ~= "string" then return nil end
    text = collapseSpaces(text)
    if #text < 40 then return nil end
    return util.fixUtf8(truncateText(text, max_chars or 320), "")
end

--------------------------------------------------------------------
-- Author
--------------------------------------------------------------------

--- Normalize whatever a backend put in `story.author`.
-- Feeds hand this over as a string, a list of names, or occasionally a
-- callable, so unwrap all three and drop values that cannot be a name.
function EpubMetadata.normalizeAuthor(raw, story)
    if type(raw) == "function" then
        local ok, value = pcall(raw, story)
        raw = ok and value or nil
    end
    if type(raw) == "table" then
        local names = {}
        for _, name in ipairs(raw) do
            if type(name) == "string" and name ~= "" then
                table.insert(names, name)
            end
        end
        raw = #names > 0 and table.concat(names, ", ") or nil
    end
    if type(raw) ~= "string" then return nil end
    local s = collapseSpaces(stripTags(raw))
    s = s:gsub("^[Bb][Yy][%s:]+", "")
    s = collapseSpaces(s)
    if s == "" or #s > 120 then return nil end
    return util.fixUtf8(s, "")
end

-- Reject anything that does not read like a person's name: a wrong byline is
-- worse than none. Only used for the HTML fallback below.
local function sanitizeGuessedAuthor(raw)
    local s = EpubMetadata.normalizeAuthor(raw)
    if not s or #s > 80 then return nil end
    if s:find("http", 1, true) or s:find("@", 1, true) or s:find("|", 1, true) then return nil end
    if s:find("%d%d%d%d") then return nil end -- a year: this is a date line
    local words = 0
    for _ in s:gmatch("%S+") do words = words + 1 end
    if words > 6 then return nil end
    return s
end

--- Best-effort byline read from the article markup.
-- Only a fallback: feeds that expose an author field should use that instead.
-- Never fetches the original page to look for one.
function EpubMetadata.extractAuthorFromHtml(html)
    if type(html) ~= "string" or html == "" then return nil end
    local head = html:sub(1, 20000)
    for tag in head:gmatch("<[Mm][Ee][Tt][Aa][^>]*>") do
        local key = tag:match('[Nn]ame%s*=%s*"([^"]*)"') or tag:match("[Nn]ame%s*=%s*'([^']*)'")
                 or tag:match('[Pp]roperty%s*=%s*"([^"]*)"') or tag:match("[Pp]roperty%s*=%s*'([^']*)'")
        if key and (key:lower() == "author" or key:lower() == "article:author") then
            local content = tag:match('[Cc]ontent%s*=%s*"([^"]*)"')
                         or tag:match("[Cc]ontent%s*=%s*'([^']*)'")
            local author = content and sanitizeGuessedAuthor(content)
            if author then return author end
        end
    end
    -- Explicitly marked-up bylines only. Class-name guessing ("byline",
    -- "author") matches too much feed boilerplate to be trustworthy.
    for _, pattern in ipairs({
        '<%a+[^>]-itemprop%s*=%s*["\']author["\'][^>]*>([%s%S]-)</',
        '<%a+[^>]-rel%s*=%s*["\']author["\'][^>]*>([%s%S]-)</',
    }) do
        local inner = head:match(pattern)
        local author = inner and sanitizeGuessedAuthor(inner)
        if author then return author end
    end
    return nil
end

--------------------------------------------------------------------
-- Feed entry -> EPUB metadata
--------------------------------------------------------------------

-- Same field names the pool serializes and the story viewer's preview picker
-- uses, so every backend's naming is covered.
local IMAGE_FIELDS = {
    "preview_image", "primary_image", "story_image",
    "image", "thumbnail", "media_thumbnail", "media_content",
}

--- Collect the metadata a feed entry already carries, for createEpub.
-- @tparam table story a story record from any backend
-- @treturn table { author, summary, cover_url }, fields absent when unknown
function EpubMetadata.fromStory(story)
    if type(story) ~= "table" then return {} end

    local summary = story.summary or story.description
    if type(summary) ~= "string" or summary == "" then summary = nil end

    local cover_url
    for _, field in ipairs(IMAGE_FIELDS) do
        local value = story[field]
        if type(value) == "string" and value ~= "" then
            cover_url = value
            break
        end
    end
    if not cover_url and type(story.image_urls) == "table" then
        for _, candidate in ipairs(story.image_urls) do
            if type(candidate) == "string" and candidate ~= "" then
                cover_url = candidate
                break
            end
        end
    end

    return {
        author = EpubMetadata.normalizeAuthor(story.author or story.creator, story),
        summary = summary,
        cover_url = cover_url,
    }
end

--------------------------------------------------------------------
-- Cover selection
--------------------------------------------------------------------

--- Read pixel dimensions out of the first bytes of an image file.
-- Returns width, height, or nil for formats we cannot parse cheaply.
function EpubMetadata.imageDimensions(data)
    if type(data) ~= "string" or #data < 10 then return nil end
    if #data >= 24 and data:sub(2, 4) == "PNG" then
        local w1, w2, w3, w4, h1, h2, h3, h4 = data:byte(17, 24)
        return ((w1 * 256 + w2) * 256 + w3) * 256 + w4,
               ((h1 * 256 + h2) * 256 + h3) * 256 + h4
    end
    if data:sub(1, 3) == "GIF" then
        local w1, w2, h1, h2 = data:byte(7, 10)
        return w2 * 256 + w1, h2 * 256 + h1 -- little-endian
    end
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local pos = 3
        while pos + 8 <= #data do
            if data:byte(pos) ~= 0xFF then
                pos = pos + 1
            else
                local marker = data:byte(pos + 1)
                -- Padding and standalone markers carry no length field.
                if marker == 0xFF or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
                    pos = pos + 2
                else
                    local len = data:byte(pos + 2) * 256 + data:byte(pos + 3)
                    if len < 2 then return nil end
                    -- SOF0..SOF15, minus DHT (C4), JPG (C8) and DAC (CC).
                    if marker >= 0xC0 and marker <= 0xCF
                            and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                        local h1, h2, w1, w2 = data:byte(pos + 5, pos + 8)
                        return w1 * 256 + w2, h1 * 256 + h2
                    end
                    pos = pos + 2 + len
                end
            end
        end
    end
    return nil
end

-- Reading the header is enough for PNG and GIF; JPEG needs to walk its
-- segments, and the SOF marker sits past the EXIF thumbnail on some cameras.
local HEADER_BYTES = 65536

local function measureLocalImage(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(HEADER_BYTES)
    f:close()
    return EpubMetadata.imageDimensions(data)
end

local function isCoverShaped(w, h)
    if not (w and h) or w <= 0 or h <= 0 then return false end
    local ratio = w / h
    -- Big enough to be an illustration, and not a banner strip or a rule.
    return w >= 300 and h >= 200 and ratio >= 0.4 and ratio <= 3.0
end

--- Pick the cover image among the images referenced by the article.
--
-- In order of confidence:
--  1. the image the feed itself nominates (media:thumbnail, media:content,
--     an image enclosure, itunes:image, JSON-Feed image) - this is the
--     thumbnail the reader shows, so it is what the user expects to see;
--  2. the first image already cached on disk whose real pixel size makes it
--     look like an illustration rather than an icon or a banner;
--  3. the first image whose markup declares a large enough size.
--
-- @tparam table images image records built by createEpub
-- @string cover_url image URL nominated by the feed entry, may be nil
-- @treturn string|nil imgid to use as the EPUB cover
function EpubMetadata.pickCoverImgid(images, cover_url)
    if type(images) ~= "table" or #images == 0 then return nil end

    if type(cover_url) == "string" and cover_url ~= "" then
        for _, img in ipairs(images) do
            if img.src == cover_url and img.mimetype ~= "image/svg+xml" then
                return img.imgid
            end
        end
    end

    for _, img in ipairs(images) do
        if img.local_path and img.mimetype ~= "image/svg+xml" then
            local w, h = measureLocalImage(img.local_path)
            if isCoverShaped(w, h) then
                return img.imgid
            end
        end
    end

    -- Nothing on disk to measure (images still to be fetched): fall back to
    -- whatever the markup declared.
    for _, img in ipairs(images) do
        if img.mimetype ~= "image/svg+xml" and isCoverShaped(img.width, img.height) then
            return img.imgid
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Chapters from heading levels
--------------------------------------------------------------------

--- Give every heading an id and collect it as a TOC entry.
-- @string body article markup
-- @treturn string rewritten markup
-- @treturn table entries, each { level, title, id }
function EpubMetadata.extractHeadings(body)
    local entries = {}
    local counter = 0
    local rewritten = body:gsub("<[hH]([1-6])([^>]*)>([%s%S]-)</[hH]%1%s*>",
        function(level, attrs, inner)
            local text = collapseSpaces(stripTags(inner))
            if text == "" then return nil end -- untouched: nothing to label it with
            local id = attrs:match('[%s]id%s*=%s*"([^"]*)"')
                    or attrs:match("[%s]id%s*=%s*'([^']*)'")
            if not id or id == "" then
                counter = counter + 1
                id = string.format("toc%03d", counter)
                attrs = attrs .. string.format(' id="%s"', id)
            end
            table.insert(entries, { level = tonumber(level), title = text, id = id })
            return "<h" .. level .. attrs .. ">" .. inner .. "</h" .. level .. ">"
        end)
    return rewritten, entries
end

--- Map the heading levels actually used onto consecutive depths, so an
-- article built out of <h2>/<h3> still starts at TOC depth 1.
-- @treturn int maximum depth
function EpubMetadata.normalizeLevels(entries)
    local used = {}
    for _, e in ipairs(entries) do used[e.level] = true end
    local sorted = {}
    for level in pairs(used) do table.insert(sorted, level) end
    table.sort(sorted)
    local depth_of = {}
    for i, level in ipairs(sorted) do depth_of[level] = i end
    local max_depth = 0
    for _, e in ipairs(entries) do
        e.depth = depth_of[e.level]
        if e.depth > max_depth then max_depth = e.depth end
    end
    return max_depth
end

--- Build a nested NCX navMap out of the collected headings.
-- @tparam table entries from extractHeadings, after normalizeLevels
-- @string content_href file the anchors live in
function EpubMetadata.buildNavMap(entries, content_href)
    local parts = {}
    local play = 0
    local open = 0 -- navPoints currently left open
    local function indent(n) return string.rep("  ", n + 2) end
    for _, e in ipairs(entries) do
        -- Never skip a level: <h1> followed by <h3> must not produce a hole.
        local depth = math.min(e.depth, open + 1)
        while open >= depth do
            table.insert(parts, indent(open - 1) .. "</navPoint>\n")
            open = open - 1
        end
        play = play + 1
        local pad = indent(depth - 1)
        table.insert(parts, string.format(
            '%s<navPoint id="navpoint-%d" playOrder="%d">\n'
            .. '%s  <navLabel><text>%s</text></navLabel>\n'
            .. '%s  <content src="%s#%s"/>\n',
            pad, play, play, pad, EpubMetadata.xmlEsc(e.title),
            pad, content_href, EpubMetadata.xmlEsc(e.id)))
        open = depth
    end
    while open > 0 do
        table.insert(parts, indent(open - 1) .. "</navPoint>\n")
        open = open - 1
    end
    return table.concat(parts)
end

return EpubMetadata
