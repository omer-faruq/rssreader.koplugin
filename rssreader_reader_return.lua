--[[--
Reader-side "back to the RSS list" affordances.

A story opened from a feed list is written to the RSS cache and handed to
FileManager:openFile(), which spawns a real ReaderUI: from that point on the
RSS menus are gone and the only ways back are the main menu (Search tab) or a
user-assigned gesture. This module adds cheaper ways back, all optional:

  * a small floating button painted on every page (view module),
  * a tap zone in the same corner (view modules never receive events, so the
    tap has to be registered separately),
  * an "end of article" dialog replacing the stock end-of-document one,
  * the hardware Back key, when there is nothing left to go back to inside
    the article itself.

Everything here is best-effort. Any failure is logged and swallowed so the rest
of the plugin keeps working, and every hook is instance-level (never a patch of
a core module), so it dies together with the ReaderUI instance it was set up on.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local ReaderReturn = {}

-- Run fn(...) and never let it escape. Returns ok, result.
local function try(what, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        logger.warn("RSSReader ReaderReturn:", what, "failed:", res)
        return false
    end
    return true, res
end

--------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------

-- The button and its tap zone only mean something on a touchscreen: with keys
-- only there is nothing to tap, so the button would be pure decoration eating
-- screen space and refresh time. Default them off there -- the Back key hook
-- and the end-of-article dialog are what those devices get instead. Still
-- togglable, in case someone wants the button as a visual reminder.
local touch_default = Device:isTouchDevice() and true or false

local BOOL_SETTINGS = {
    enabled     = { key = "rssreader_reader_return_enabled",   default = true },
    button      = { key = "rssreader_reader_return_button",    default = touch_default },
    tap_zone    = { key = "rssreader_reader_return_tapzone",   default = touch_default },
    end_of_book = { key = "rssreader_reader_return_endofbook", default = true },
    back_key    = { key = "rssreader_reader_return_backkey",   default = true },
}

local CORNER_SETTING = "rssreader_reader_return_corner"
local HINT_SETTING = "rssreader_reader_return_hint_shown"
-- Bottom right is the least contested corner. Both right-hand corners sit
-- inside DTAP_ZONE_FORWARD (x = 1/4 .. 1, full height), so either way we take a
-- bite out of next-page; but the top strip is also the menu zone
-- (DTAP_ZONE_MENU is full width, h = 1/8), the top right corner is where the
-- dogear bookmark indicator is painted, and the Gestures plugin ships
-- tap_top_right_corner = toggle_bookmark by default -- while
-- tap_right_bottom_corner ships with no action at all.
local DEFAULT_CORNER = "bottom_right"

ReaderReturn.CORNERS = {
    { id = "top_left",     text = _("Top left") },
    { id = "top_right",    text = _("Top right") },
    { id = "bottom_left",  text = _("Bottom left") },
    { id = "bottom_right", text = _("Bottom right") },
}

function ReaderReturn.isOn(name)
    local spec = BOOL_SETTINGS[name]
    if not spec or not G_reader_settings then
        return false
    end
    if spec.default then
        return G_reader_settings:nilOrTrue(spec.key)
    end
    return G_reader_settings:isTrue(spec.key)
end

function ReaderReturn.toggle(name)
    local spec = BOOL_SETTINGS[name]
    if not spec or not G_reader_settings then
        return
    end
    G_reader_settings:saveSetting(spec.key, not ReaderReturn.isOn(name))
end

function ReaderReturn.getCorner()
    if not G_reader_settings then
        return DEFAULT_CORNER
    end
    local value = G_reader_settings:readSetting(CORNER_SETTING, DEFAULT_CORNER)
    for _, corner in ipairs(ReaderReturn.CORNERS) do
        if corner.id == value then
            return value
        end
    end
    return DEFAULT_CORNER
end

function ReaderReturn.getCornerText()
    local current = ReaderReturn.getCorner()
    for _, corner in ipairs(ReaderReturn.CORNERS) do
        if corner.id == current then
            return corner.text
        end
    end
    return current
end

function ReaderReturn.setCorner(id)
    if G_reader_settings then
        G_reader_settings:saveSetting(CORNER_SETTING, id)
    end
end

--------------------------------------------------------------------
-- Which document is "an RSS article"?
--------------------------------------------------------------------

-- Only documents opened *from a feed list* count. Sanitized links (the "Open
-- Sanitized" link popup button, ExternalAPI) land in the very same cache
-- directory but are opened from inside some other book, where returning to the
-- RSS list would be the wrong move -- hence an explicit marker instead of a
-- path check. Module state survives the FileManager -> ReaderUI instance swap
-- (package.loaded outlives both) and dies with the process, which is also when
-- the saved navigation state stops being worth restoring.
local marked_article = nil

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return (path:gsub("\\", "/"):gsub("//+", "/"))
end

function ReaderReturn.markArticle(path)
    marked_article = normalizePath(path)
end

function ReaderReturn.forgetArticle()
    marked_article = nil
end

function ReaderReturn.isArticle(path)
    local normalized = normalizePath(path)
    return marked_article ~= nil and normalized ~= nil and normalized == marked_article
end

--------------------------------------------------------------------
-- The floating button (a view module: painted on every page, never
-- receives events -- the tap zone below does that part)
--------------------------------------------------------------------

local ButtonOverlay = {}
ButtonOverlay.__index = ButtonOverlay

function ButtonOverlay.new()
    local icon_size = Screen:scaleBySize(18)
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        padding = Size.padding.button,
        margin = 0,
        HorizontalGroup:new{
            align = "center",
            IconWidget:new{
                icon = "chevron.left",
                width = icon_size,
                height = icon_size,
                alpha = true,
            },
            HorizontalSpan:new{ width = Size.span.horizontal_small },
            TextWidget:new{
                text = "RSS",
                face = Font:getFace("cfont", 14),
            },
        },
    }
    return setmetatable({ frame = frame }, ButtonOverlay)
end

-- ReaderView assigns .view to every view module it registers, so a bottom
-- corner can sit above the status bar instead of on top of it.
local function footerHeight(view)
    if not view or not view.footer_visible or not view.footer then
        return 0
    end
    local ok, height = pcall(view.footer.getHeight, view.footer)
    if ok and type(height) == "number" then
        return height
    end
    return 0
end

function ButtonOverlay:getGeom()
    local size = self.frame:getSize()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local gap = Size.padding.large
    local corner = ReaderReturn.getCorner()
    local x = gap
    local y = gap
    if corner == "top_right" or corner == "bottom_right" then
        x = screen_w - size.w - gap
    end
    if corner == "bottom_left" or corner == "bottom_right" then
        y = screen_h - size.h - gap - footerHeight(self.view)
    end
    return Geom:new{ x = x, y = y, w = size.w, h = size.h }
end

function ButtonOverlay:paintTo(bb, x, y)
    local ok, geom = try("button paint", self.getGeom, self)
    if not ok or not geom then
        return
    end
    self.dimen = geom
    -- The button relays itself out on every paint, its tap zone does not. Watch
    -- for drift (rotation, the status bar being toggled, a footer mode with a
    -- different height) and let the owner realign them.
    local last = self.last_geom
    if self.on_geom_change and (not last or last.x ~= geom.x or last.y ~= geom.y
            or last.w ~= geom.w or last.h ~= geom.h) then
        self.last_geom = geom
        self.on_geom_change()
    end
    self.frame:paintTo(bb, x + geom.x, y + geom.y)
end

-- Called by ReaderView on rotation/resize; geometry is recomputed on every
-- paint anyway, we only have to drop the cached one.
function ButtonOverlay:resetLayout()
    self.dimen = nil
end

--------------------------------------------------------------------
-- Going back
--------------------------------------------------------------------

function ReaderReturn.returnToList(plugin)
    if not plugin or type(plugin.openAccountList) ~= "function" then
        return false
    end
    -- The RSS menus are plain widgets shown by UIManager, so they simply stack
    -- on top of the reader: closing the list drops the user straight back into
    -- the article, at the position they left it. Opening another story from
    -- there goes through ReaderUI:showReader(), which tears this reader down
    -- for us. force_restore because an article can easily be read for longer
    -- than the 30 min freshness window of the saved feed state.
    local ok = try("reopening the RSS list", function()
        plugin:openAccountList({ force_restore = true })
    end)
    return ok
end

--------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------

local function installButton(plugin)
    if not ReaderReturn.isOn("button") then
        return
    end
    local view = plugin.ui and plugin.ui.view
    if not view or type(view.registerViewModule) ~= "function" then
        return
    end
    local overlay = ButtonOverlay.new()
    -- registerViewModule sets overlay.view, which getGeom needs to clear the
    -- status bar in a bottom corner: register before measuring.
    view:registerViewModule("rssreader_return", overlay)
    plugin._rss_return_overlay = overlay
    local geom = overlay:getGeom()
    -- Seeded so the first paint does not count as drift.
    overlay.last_geom = geom
    overlay.on_geom_change = function()
        UIManager:nextTick(function()
            ReaderReturn.refreshTouchZone(plugin)
        end)
    end
    -- The page underneath has already been painted by the time ReaderReady
    -- fires, so ask for a repaint of just the button's area.
    UIManager:setDirty(plugin.ui, "ui", geom)
end

local function installTouchZone(plugin)
    if not ReaderReturn.isOn("tap_zone") then
        return
    end
    local ui = plugin.ui
    if not Device:isTouchDevice() or not ui or type(ui.registerTouchZones) ~= "function" then
        return
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local zone
    local overlay = plugin._rss_return_overlay
    if overlay then
        -- Hit area == the visible button plus a finger-sized margin.
        local geom = overlay:getGeom()
        local slack = Screen:scaleBySize(8)
        zone = {
            ratio_x = math.max(0, geom.x - slack) / screen_w,
            ratio_y = math.max(0, geom.y - slack) / screen_h,
            ratio_w = math.min(1, (geom.w + 2 * slack) / screen_w),
            ratio_h = math.min(1, (geom.h + 2 * slack) / screen_h),
        }
    else
        -- Button hidden: fall back to an invisible corner the size of
        -- KOReader's own corner gesture zones (DTAP_ZONE_TOP_LEFT = 1/8).
        local corner = ReaderReturn.getCorner()
        zone = {
            ratio_x = (corner == "top_right" or corner == "bottom_right") and 7/8 or 0,
            ratio_y = (corner == "bottom_left" or corner == "bottom_right") and 7/8 or 0,
            ratio_w = 1/8,
            ratio_h = 1/8,
        }
    end

    ui:registerTouchZones({
        {
            id = "rssreader_return_tap",
            ges = "tap",
            screen_zone = zone,
            -- Anything that would otherwise swallow a tap in a corner. Listing
            -- a zone that does not exist (the corner ones come from the
            -- Gestures plugin) is harmless: DepGraph just creates an inert
            -- node. tap_link is deliberately left out so links keep winning.
            overrides = {
                "readerhighlight_tap",
                "readermenu_ext_tap",
                "readermenu_tap",
                "readerfooter_tap",
                "readerconfigmenu_ext_tap",
                "readerconfigmenu_tap",
                "tap_top_left_corner",
                "tap_top_right_corner",
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "tap_forward",
                "tap_backward",
            },
            handler = function()
                return ReaderReturn.returnToList(plugin)
            end,
        },
    })
end

-- Re-register after a rotation: registerTouchZones() replaces a zone with the
-- same id, and the stored ratios need recomputing because the button lays
-- itself out against the *new* screen size on its next paint. Must run after
-- ReaderUI:onScreenResize() has done its own rescaling, hence the nextTick in
-- the caller.
function ReaderReturn.refreshTouchZone(plugin)
    if not plugin or not plugin._rss_return_active then
        return
    end
    try("refreshing the tap zone", installTouchZone, plugin)
end

function ReaderReturn.showEndOfArticleDialog(plugin)
    local dialog
    dialog = ButtonDialog:new{
        name = "rssreader_end_of_article",
        title = _("You've reached the end of the article.\nWhat would you like to do?"),
        title_align = "center",
        buttons = {
            {{
                text = _("Back to RSS list"),
                callback = function()
                    UIManager:close(dialog)
                    ReaderReturn.returnToList(plugin)
                end,
            }},
            {
                {
                    text = _("Go to beginning"),
                    callback = function()
                        UIManager:close(dialog)
                        if plugin.ui and plugin.ui.gotopage then
                            plugin.ui.gotopage:onGoToBeginning()
                        end
                    end,
                },
                {
                    text = _("File browser"),
                    callback = function()
                        UIManager:close(dialog)
                        local ui = plugin.ui
                        local file = ui and ui.document and ui.document.file
                        -- Delayed, like ReaderStatus does, so as not to tear
                        -- down the instance we are running inside of.
                        UIManager:nextTick(function()
                            ui:onClose()
                            ui:showFileManager(file)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

local function installEndOfBook(plugin)
    if not ReaderReturn.isOn("end_of_book") then
        return
    end
    local status = plugin.ui and plugin.ui.status
    -- ReaderStatus builds its end-of-document dialog inline with no extension
    -- point, and it is registered before the plugins, so the event never
    -- reaches us in time. Wrap the instance method instead.
    if not status or type(status.onEndOfBook) ~= "function" or status._rss_return_wrapped then
        return
    end
    local original = status.onEndOfBook
    status._rss_return_wrapped = true
    status.onEndOfBook = function(this, ...)
        if plugin._rss_return_active and ReaderReturn.isOn("end_of_book") then
            if try("end of article dialog", ReaderReturn.showEndOfArticleDialog, plugin) then
                return true
            end
        end
        return original(this, ...)
    end
end

-- Is there somewhere to go back to *inside* the article (followed links,
-- jumps)? If so the stock Back handling is still the useful one; we only want
-- the "nothing left, shall I quit KOReader?" case.
local function hasInDocumentHistory(ui)
    local link_stack = ui.link and ui.link.location_stack
    if type(link_stack) == "table" and #link_stack > 0 then
        return true
    end
    local back_stack = ui.back and ui.back.location_stack
    if type(back_stack) == "table" and #back_stack > 0 then
        return true
    end
    return false
end

local function installBackKey(plugin)
    if not ReaderReturn.isOn("back_key") or not Device:hasKeys() then
        return
    end
    local back = plugin.ui and plugin.ui.back
    -- Same story as ReaderStatus: ReaderBack:onBack() always returns true and
    -- is registered before the plugins, so wrapping the instance is the only
    -- way in. This is what gives key-only devices (Kindle 4's Back button,
    -- Kobo/Kindle page-key devices) a shortcut without stealing a key that
    -- something else already owns.
    if not back or type(back.onBack) ~= "function" or back._rss_return_wrapped then
        return
    end
    local original = back.onBack
    back._rss_return_wrapped = true
    back.onBack = function(this, ...)
        if plugin._rss_return_active and ReaderReturn.isOn("back_key")
                and not hasInDocumentHistory(plugin.ui) then
            if ReaderReturn.returnToList(plugin) then
                return true
            end
        end
        return original(this, ...)
    end
end

local function showFirstRunHint()
    if not G_reader_settings or G_reader_settings:isTrue(HINT_SETTING) then
        return
    end
    local tappable = ReaderReturn.isOn("tap_zone") and Device:isTouchDevice()
    local text
    if tappable and ReaderReturn.isOn("button") then
        text = _("Tap the RSS button to go back to your feed list.")
    elseif tappable then
        text = _("Tap the corner to go back to your feed list.")
    elseif ReaderReturn.isOn("back_key") and Device:hasKeys() then
        text = _("Press Back to return to your feed list.")
    else
        -- Nothing to point at; don't burn the one-time hint on a no-op.
        return
    end
    G_reader_settings:saveSetting(HINT_SETTING, true)
    UIManager:show(Notification:new{ text = text })
end

--------------------------------------------------------------------
-- Entry point (called from RSSReader:onReaderReady)
--------------------------------------------------------------------

function ReaderReturn.setup(plugin)
    if not ReaderReturn.isOn("enabled") then
        return
    end
    local ui = plugin and plugin.ui
    -- No document means we are the FileManager-side instance of the plugin.
    if not ui or not ui.document then
        return
    end
    if not ReaderReturn.isArticle(ui.document.file) then
        return
    end

    plugin._rss_return_active = true

    try("installing the button", installButton, plugin)
    try("installing the tap zone", installTouchZone, plugin)
    try("installing the end-of-article hook", installEndOfBook, plugin)
    try("installing the Back key hook", installBackKey, plugin)
    try("showing the first-run hint", showFirstRunHint)
end

--------------------------------------------------------------------
-- Settings UI (mirrors the style of MenuBuilder:showSettingsPopup)
--------------------------------------------------------------------

local function checkmarked(is_on, text)
    return is_on and ("✓ " .. text) or text
end

function ReaderReturn.showCornerPopup(on_close)
    local dialog
    local buttons = {}
    local current = ReaderReturn.getCorner()
    for _, corner in ipairs(ReaderReturn.CORNERS) do
        table.insert(buttons, {{
            text = checkmarked(corner.id == current, corner.text),
            background = Blitbuffer.COLOR_WHITE,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                ReaderReturn.setCorner(corner.id)
                if on_close then on_close() end
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Corner"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ReaderReturn.showSettings()
    local dialog
    local function entry(text, callback)
        return {{
            text = text,
            background = Blitbuffer.COLOR_WHITE,
            align = "left",
            callback = callback,
        }}
    end
    local function toggleEntry(name, text)
        return entry(checkmarked(ReaderReturn.isOn(name), text), function()
            UIManager:close(dialog)
            ReaderReturn.toggle(name)
            ReaderReturn.showSettings()
        end)
    end

    dialog = ButtonDialog:new{
        title = _("Return to RSS from an article"),
        buttons = {
            toggleEntry("enabled", _("Enabled")),
            toggleEntry("button", _("Show floating button")),
            toggleEntry("tap_zone", _("Corner tap returns to the list")),
            entry(string.format(_("Corner: %s"), ReaderReturn.getCornerText()), function()
                UIManager:close(dialog)
                ReaderReturn.showCornerPopup(function()
                    ReaderReturn.showSettings()
                end)
            end),
            toggleEntry("end_of_book", _("Ask at end of article")),
            toggleEntry("back_key", _("Back key returns to the list")),
            entry(_("Close"), function()
                UIManager:close(dialog)
            end),
        },
    }
    UIManager:show(dialog)
end

return ReaderReturn
