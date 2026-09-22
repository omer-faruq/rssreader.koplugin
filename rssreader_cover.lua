--[==[
Designed EPUB cover for RSS Reader articles.

Paints a fixed-size bitmap laid out as:

    ==========
    [[TITLE]]
    [[IMAGE]]     <- the article lead image, landscape box, centered
    [[AUTHOR]]
    ==========

and returns it as PNG bytes, ready to be stored in the EPUB and pointed at by
<meta name="cover">. The canvas is device independent (the file travels with
the book), so font sizes are given in canvas pixels and un-scaled from the
running device DPI before being handed to Font:getFace().

Text fitting is adapted from the fallback cover patch: shrink the font until
the widest word fits, wrap to a line limit, then truncate the last line with an
ellipsis rather than trying to squeeze the whole title in.
]==]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderImage = require("ui/renderimage")
local RenderText = require("ui/rendertext")
local Screen = require("device").screen
local logger = require("logger")

local RSSReaderCover = {}

--------------------------------------------------------------------
-- Layout constants (canvas pixels)
--------------------------------------------------------------------

local COVER_W, COVER_H = 600, 800
local MARGIN           = 44
local BLOCK_GAP        = 28   -- between title/image/author

-- Text specs, one set for the illustrated cover and one for the text-only one.
-- With no picture to sandwich there is a whole page of white to spend, so the
-- type grows and the title is allowed to run to more lines.
local TITLE_SPEC       = { font = "tfont", bold = true,  max = 44, min = 22, lines = 4 }
local AUTHOR_SPEC      = { font = "cfont", bold = false, max = 36, min = 22, lines = 2 }
local SITE_SPEC        = { font = "cfont", bold = false, max = 26, min = 26, lines = 1 }

local TITLE_SPEC_SOLO  = { font = "tfont", bold = true,  max = 72, min = 30, lines = 8 }
local AUTHOR_SPEC_SOLO = { font = "cfont", bold = false, max = 44, min = 24, lines = 3 }
local SITE_SPEC_SOLO   = { font = "cfont", bold = false, max = 32, min = 32, lines = 1 }

local SITE_GAP         = 10   -- between byline and site line
local SOLO_GAP         = 56   -- between title and byline on a text-only cover

local IMAGE_MAX_H      = 320  -- landscape band, never taller than this
local IMAGE_MIN_H      = 160  -- below this the picture is not worth the room
local LINE_GAP_RATIO   = 0.22 -- extra leading, in em

--------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------

local dpi_scale

-- Font:getFace() scales by screen DPI, which we do not want on a canvas whose
-- size is fixed: undo it so a "44px" title is 44 of these 800 pixels.
local function getFace(name, size)
    if not dpi_scale then
        dpi_scale = Screen:scaleBySize(1000) / 1000
        if dpi_scale <= 0 then dpi_scale = 1 end
    end
    return Font:getFace(name, math.max(8, math.floor(size / dpi_scale + 0.5)))
end

local function textWidth(face, text, bold)
    return RenderText:sizeUtf8Text(0, false, face, text, false, bold).x
end

-- Step the font size down until the widest single word fits max_w.
local function shrinkToFit(text, font, size, min_size, bold, max_w)
    local widest_w, widest_word = 0, nil
    for w in text:gmatch("%S+") do
        local ww = textWidth(getFace(font, size), w, bold)
        if ww > widest_w then widest_w, widest_word = ww, w end
    end
    if not widest_word or widest_w <= max_w then return size end
    while size > min_size do
        size = size - 1
        if textWidth(getFace(font, size), widest_word, bold) <= max_w then break end
    end
    return size
end

-- Wrap to at most max_lines. Returns the lines ({text, w}); anything that did
-- not fit is marked by ellipsizing the last line.
local function wrapLines(text, face, bold, max_w, max_lines)
    local lines, words = {}, {}
    for w in text:gmatch("%S+") do table.insert(words, w) end

    local space_w = textWidth(face, " ", bold)
    local cur_text, cur_w = "", 0
    local truncated = false

    local function flush()
        if cur_text ~= "" then
            table.insert(lines, { text = cur_text, w = cur_w })
            cur_text, cur_w = "", 0
        end
    end

    for i, word in ipairs(words) do
        local word_w = textWidth(face, word, bold)
        if word_w > max_w then
            -- A single word wider than the line: hard-truncate it.
            flush()
            if #lines >= max_lines then truncated = true; break end
            local cut = RenderText:truncateTextByWidth(word, face, max_w, false, bold)
            table.insert(lines, { text = cut, w = textWidth(face, cut, bold) })
            if i < #words then truncated = true end
        elseif cur_text == "" then
            cur_text, cur_w = word, word_w
        elseif cur_w + space_w + word_w <= max_w then
            cur_text = cur_text .. " " .. word
            cur_w = cur_w + space_w + word_w
        else
            flush()
            if #lines >= max_lines then
                truncated = true
                break
            end
            cur_text, cur_w = word, word_w
        end
    end
    if #lines < max_lines then
        flush()
    elseif cur_text ~= "" then
        truncated = true
    end

    if truncated and #lines > 0 then
        local last = lines[#lines]
        local cut = RenderText:truncateTextByWidth(last.text, face, max_w, false, bold)
        lines[#lines] = { text = cut, w = textWidth(face, cut, bold) }
    end

    return lines
end

-- Measure a text block without drawing it: returns a table the drawer consumes.
-- max_h, when given, also caps the line count to what actually fits that height.
local function measureBlock(text, spec, max_w, max_h)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end

    local size = shrinkToFit(text, spec.font, spec.max, spec.min, spec.bold, max_w)
    local face = getFace(spec.font, size)
    local ref = RenderText:sizeUtf8Text(0, false, face, "Ag", false, spec.bold)
    local line_h = ref.y_top + ref.y_bottom
    local gap = math.max(2, math.floor(size * LINE_GAP_RATIO))

    local max_lines = spec.lines
    if max_h then
        local fits = math.floor((max_h + gap) / (line_h + gap))
        if fits < 1 then return nil end
        if fits < max_lines then max_lines = fits end
    end

    local lines = wrapLines(text, face, spec.bold, max_w, max_lines)
    if #lines == 0 then return nil end

    return {
        lines = lines,
        face = face,
        bold = spec.bold,
        y_top = ref.y_top,
        line_h = line_h,
        gap = gap,
        height = #lines * line_h + (#lines - 1) * gap,
    }
end

-- Draw a measured block, each line centered horizontally inside [x, x + w].
local function drawBlock(bb, block, x, y, w)
    local cur_y = y
    for i, line in ipairs(block.lines) do
        local lx = x + math.max(0, math.floor((w - line.w) / 2))
        RenderText:renderUtf8Text(bb, lx, cur_y + block.y_top, block.face, line.text,
                                  false, block.bold, Blitbuffer.COLOR_BLACK)
        cur_y = cur_y + block.line_h + (i < #block.lines and block.gap or 0)
    end
end

--------------------------------------------------------------------
-- Image helpers
--------------------------------------------------------------------

-- Decode the lead image so that it *fills* the band, then hand back the crop
-- to take out of it: scale by the larger of the two ratios (so neither side
-- falls short, small images included), keep the aspect ratio, and cut the
-- overflow off the long axis. Returns bb plus the source rectangle to blit.
--
-- When the pixel size is known up front we let MuPDF decode straight at the
-- scaled size, so a 4000px press photo never becomes a 30 MB blitbuffer.
local function decodeToFill(data, mimetype, src_w, src_h, box_w, box_h)
    local bb
    if src_w and src_h and src_w > 0 and src_h > 0 then
        local scale = math.max(box_w / src_w, box_h / src_h)
        local tw = math.max(box_w, math.ceil(src_w * scale))
        local th = math.max(box_h, math.ceil(src_h * scale))
        local ok, res = pcall(RenderImage.renderImageData, RenderImage, data, #data, false, tw, th)
        if ok then bb = res end
    end
    if not bb then
        local ok, res = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
        if not ok or not res then
            logger.info("RSSReaderCover: image decode failed", mimetype, res)
            return nil
        end
        bb = res
        local w, h = bb:getWidth(), bb:getHeight()
        if w > 0 and h > 0 then
            local scale = math.max(box_w / w, box_h / h)
            local tw = math.max(box_w, math.ceil(w * scale))
            local th = math.max(box_h, math.ceil(h * scale))
            if tw ~= w or th ~= h then
                local ok2, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, tw, th, true)
                if ok2 and scaled then bb = scaled end
            end
        end
    end

    local w, h = bb:getWidth(), bb:getHeight()
    local crop_w = math.min(box_w, w)
    local crop_h = math.min(box_h, h)
    -- Centered horizontally; slightly above center vertically, which is where
    -- the subject of a cropped photo usually sits.
    local off_x = math.floor((w - crop_w) / 2)
    local off_y = math.floor((h - crop_h) * 0.35)
    return bb, off_x, off_y, crop_w, crop_h
end

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

--- Build the cover and return it as PNG bytes.
-- @string title article title (may be long: it gets wrapped and ellipsized)
-- @string author byline, or nil
-- @string site source site, shown under the byline (and standing in for it
--   when the article carries no byline, which is what the EPUB metadata does)
-- @table image { content = <bytes>, mimetype = <string>, w = <int>, h = <int> }, or nil
-- @string out_path scratch path the PNG is written to and read back from
-- @treturn string PNG bytes, or nil plus a reason
function RSSReaderCover.build(title, author, site, image, out_path)
    local ok, png, err = pcall(function()
        local text_w = COVER_W - 2 * MARGIN

        -- Mirror the EPUB metadata: byline when there is one, otherwise the
        -- site takes the author slot rather than leaving the cover unsigned.
        if type(author) ~= "string" or author:match("^%s*$") then
            author, site = site, nil
        end
        if type(site) == "string" and type(author) == "string"
                and site:lower() == author:lower() then
            site = nil
        end

        local has_image = image ~= nil and image.content ~= nil
        local title_spec  = has_image and TITLE_SPEC  or TITLE_SPEC_SOLO
        local author_spec = has_image and AUTHOR_SPEC or AUTHOR_SPEC_SOLO
        local site_spec   = has_image and SITE_SPEC   or SITE_SPEC_SOLO

        -- The signature is measured first: whatever it does not take is what
        -- the title may grow into.
        local author_block = measureBlock(author, author_spec, text_w)
        local site_block = measureBlock(site, site_spec, text_w)

        local reserved = 0
        if author_block then
            reserved = reserved + author_block.height + (has_image and BLOCK_GAP or SOLO_GAP)
        end
        if site_block then reserved = reserved + site_block.height + SITE_GAP end
        if has_image then reserved = reserved + IMAGE_MIN_H + BLOCK_GAP end

        local title_block = measureBlock(title, title_spec, text_w,
                                         COVER_H - 2 * MARGIN - reserved)
        if not title_block and not author_block and not site_block and not has_image then
            return nil, "nothing_to_draw"
        end

        local bb = Blitbuffer.new(COVER_W, COVER_H, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)

        if not has_image then
            -- Nothing to sandwich: center the text on the page instead of
            -- pinning it to the edges around an empty middle.
            local total = title_block and title_block.height or 0
            if author_block then total = total + SOLO_GAP + author_block.height end
            if site_block then total = total + SITE_GAP + site_block.height end

            local y = math.max(MARGIN, math.floor((COVER_H - total) / 2))
            if title_block then
                drawBlock(bb, title_block, MARGIN, y, text_w)
                y = y + title_block.height
            end
            if author_block then
                y = y + SOLO_GAP
                drawBlock(bb, author_block, MARGIN, y, text_w)
                y = y + author_block.height
            end
            if site_block then
                y = y + SITE_GAP
                drawBlock(bb, site_block, MARGIN, y, text_w)
            end
        else

            -- Title sits under the top margin, author above the bottom one; the
            -- image gets whatever is left in between, capped to a landscape band.
            local top_y = MARGIN
            if title_block then
                drawBlock(bb, title_block, MARGIN, top_y, text_w)
                top_y = top_y + title_block.height
            end

            local bottom_y = COVER_H - MARGIN
            if site_block then
                bottom_y = bottom_y - site_block.height
                drawBlock(bb, site_block, MARGIN, bottom_y, text_w)
                bottom_y = bottom_y - SITE_GAP
            end
            if author_block then
                bottom_y = bottom_y - author_block.height
                drawBlock(bb, author_block, MARGIN, bottom_y, text_w)
            end

            local band_top = top_y + (title_block and BLOCK_GAP or 0)
            local band_h = bottom_y - ((author_block or site_block) and BLOCK_GAP or 0) - band_top
            if band_h > IMAGE_MAX_H then
                band_top = band_top + math.floor((band_h - IMAGE_MAX_H) / 2)
                band_h = IMAGE_MAX_H
            end
            if band_h >= 60 then
                local img_bb, off_x, off_y, iw, ih =
                    decodeToFill(image.content, image.mimetype,
                                 image.w, image.h, text_w, band_h)
                if img_bb then
                    -- iw/ih fall short of the band only if the decoder handed
                    -- back something smaller than asked; center what we got.
                    local ix = MARGIN + math.floor((text_w - iw) / 2)
                    local iy = band_top + math.floor((band_h - ih) / 2)
                    bb:blitFrom(img_bb, ix, iy, off_x, off_y, iw, ih)
                    img_bb:free()
                end
            end

        end

        bb:writePNG(out_path)
        bb:free()

        local fh = io.open(out_path, "rb")
        if not fh then return nil, "png_read_failed" end
        local data = fh:read("*a")
        fh:close()
        os.remove(out_path)
        if not data or data == "" then return nil, "png_empty" end
        return data
    end)

    if not ok then
        logger.warn("RSSReaderCover: build failed", png)
        return nil, "cover_build_error"
    end
    return png, err
end

return RSSReaderCover
