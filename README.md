# RSS Reader Plugin

The KOReader **RSS Reader** plugin lets you follow RSS feeds from a single screen. For everyday use you only need to define your account and pick the local feeds you care about.

https://github.com/user-attachments/assets/9fa52ff9-2e5a-47f1-a207-db5e2cd80d7e

## Who Is It For?
- **Readers who want to add their own RSS accounts**
- **Users who prefer to use the local feed bundles**

These scenarios require you to know only two files. Both are provided as `.sample.lua` templates; rename them after editing so the plugin can load them.

## Supported Account Types

The plugin supports several account types:
- **Local**: Offline RSS feeds stored locally
- **NewsBlur**: Online RSS aggregator (requires premium subscription for full access)
- **CommaFeed**: Self-hosted or cloud-based RSS aggregator (**Recommended**)
- **FreshRSS**: Self-hosted RSS aggregator
- **Miniflux**: Self-hosted minimalist RSS aggregator with native API support
- **Fever API**: Generic API compatible with other services

### Why CommaFeed is Recommended
CommaFeed offers the most comprehensive feature set for RSS reading on KOReader:
- ✅ **Online sync** – Access your feeds from any device with automatic read state synchronization
- ✅ **Virtual aggregated views** – View all feeds or all unread items from all subscriptions in one list
- ✅ **Category-level aggregation** – Each folder/category has its own "All Feeds" and "All Unread" views
- ✅ **Free tier available** – Use the official hosted service at [commafeed.com](https://www.commafeed.com) or self-host
- ✅ **Full API support** – Mark as read, pagination, and all core features work seamlessly
- ✅ **Starring** – Star/unstar articles, synced through CommaFeed's API
- ✅ **Tags** – Browse articles by tag and edit a story's tags directly, synced through CommaFeed's API

Other services like NewsBlur, FreshRSS, and Miniflux are fully supported with similar features. FreshRSS additionally supports favourites (starring). Miniflux provides native API support with folder/category organization and mark as read functionality.

## Files You Need to Edit
- **`rssreader_configuration.sample.lua` → rename to `rssreader_configuration.lua`**: Describe your accounts and per-account preferences.
  - Provide the name, service type (`local`, `newsblur`, `commafeed`, `freshrss`, `miniflux`, `fever`), login details, and options.
  - Add as many entries as you like, even multiple accounts for the same service type.
  - Use the `active` field to temporarily disable or re-enable an account.
  - After editing, reload the plugin inside KOReader to see your changes in the account list.
- **`rssreader_local_defaults.sample.lua` → rename to `rssreader_local_defaults.lua`**: Contains the default local RSS bundles.
  - Add or remove any groups and feeds you like.
  - Update titles, descriptions, and URLs to match your interests.
  - Make sure the account keys (e.g., `"Sample"`, `"Local 2"`) match the `name` values defined in `rssreader_configuration.lua` so KOReader can link them.

The other Lua files handle internal logic. End users do not need to open or modify them.

## Quick Start
- Open **RSS Reader** from KOReader’s main menu ("Search" part).
- The account list reflects the entries you configured; tap to open, long-press for more options.
- In the feed list, a tap performs the action you configured (see "Tap Action on Feed Items" below), while a long press always shows all options: preview, open directly, save, and toggle read/unread.
- For local accounts, the groups and feeds defined in your renamed `rssreader_local_defaults.lua` appear. Editing the URLs here is how you add new sources.

## Refreshing
Feed trees and story lists have a menu icon in the top left corner of the title bar with **Refresh** and **Mark all as read**; on devices with a hardware **Menu** key, that key opens it too. Where mark-all is not available (NewsBlur virtual feeds, CommaFeed tags, FreshRSS *Today (Unread)*) the icon is a plain refresh button. There is no need to close and reopen the plugin to pull new articles:
- **In a feed tree** (account root or any folder) – The whole tree is fetched again, with fresh unread counts, and you stay in the same folder. Going Back afterwards shows the fresh counts on the levels above too
- **In a story list** – The first page of stories is fetched again and the list jumps back to its first page. For a local feed, a failed refresh keeps the list that is already on screen
- A refresh does not add a navigation step: Back still goes up one level
- **Mark all as read** marks the tree or folder (after a confirmation) or the feed on screen read, like the long-press action, then shows the updated unread counts or un-bolds the list
- Local account and group menus and the reading list have no refresh icon, since they list only what is in your configuration. Opening a local feed always fetches it fresh

## Open on Startup
By default RSS Reader opens on the account list. You can make it open directly on a feed or folder instead:
- **Long-press** any feed or folder (remote trees, local feeds and local groups) → **Open on startup**
- Or pick a preset under **RSS Reader** → **Settings** → **Open on startup**: the account list, or the **★ All Unread** view of any remote account (for NewsBlur, only while **Show NewsBlur 'All Feeds'** is on). A feed or folder picked by long-press shows up there as **Custom**
- On startup, every folder on the way to it is opened too, so Back climbs up through them to the account list as if you had navigated there yourself
- If the feed or folder no longer exists, the account's tree opens with a short notice
- Coming back from an opened article still returns you to the list you were reading from, not to the startup feed

## Virtual "All Feeds" Aggregated Views
NewsBlur, CommaFeed, Miniflux, and Fever API accounts include special virtual feeds that aggregate stories from all your subscriptions:
- **★ All Feeds** – View all stories from all subscribed feeds in a single chronological list
- **★ All Unread** – View only unread stories from all feeds combined
- Stories are prefixed with their feed name (max 5 characters) for easy identification
- Long-press any story to see the full feed name in the context menu
- Pagination support: Use the "More" button to load additional stories (50 per page)

### Availability by Service
- **NewsBlur**: Virtual feeds appear at the top of the root feed list (requires premium subscription for full access)
- **CommaFeed**: Virtual feeds appear at the top of both the root feed list and inside each category/folder
- **Miniflux**: Virtual feeds appear at the top of both the root feed list and inside each category/folder
- **Fever API**: Only virtual feeds are supported (★ All Feeds, ★ All Unread). Individual feeds and folders are not shown due to API limitations.

### Settings
- Toggle NewsBlur virtual feeds visibility: **RSS Reader** → **Settings** → **Show NewsBlur 'All Feeds'**
- Default: Visible (can be disabled if you prefer not to see them)
- Changes take effect immediately when you reopen the NewsBlur account

### Mark All as Read for Virtual Feeds
- **CommaFeed & Miniflux**: Virtual feeds support "Mark all as read" functionality. Long-press a virtual feed to mark all stories in that view as read.
- **Fever API**: Long-press a virtual feed → **Mark all as read**. After a confirmation, every subscribed feed is marked as read one by one, so this can take a while with many subscriptions.
- **NewsBlur**: Virtual feeds cannot be marked as read in bulk. Use individual feeds for "Mark all as read" functionality.

## Starring Articles (CommaFeed, FreshRSS)
CommaFeed and FreshRSS accounts support starring/unstarring individual articles, synced through their APIs (FreshRSS calls them favourites and keeps them as the `user/-/state/com.google/starred` tag):
- Long-press a story → **Star** / **Unstar** (next to **Add to List**), or use the star button in the story preview toolbar
- Starred stories show a ★ prefix in the title
- A starred virtual feed aggregates every starred article across your subscriptions: **★ Starred** at the top of the root feed list on CommaFeed, **Starred** among the special feeds on FreshRSS
- On FreshRSS that feed also lists articles you have already read, since a favourite stays a favourite after reading; the other FreshRSS special feeds stay filtered to unread
- Not yet available for NewsBlur, Miniflux, or Fever API accounts

## Tags (CommaFeed)
CommaFeed accounts support browsing and editing per-article tags:
- A **★ Tags** virtual folder appears at the top of the root feed list, listing every tag you've used across your subscriptions
- Tap a tag to view all stories carrying it, with the same pagination/read/star behavior as other virtual feeds
- Long-press **★ Tags** → **Refresh tags** to force a re-fetch; the tag list is also refreshed automatically whenever you re-enter the account from the account list
- Long-press a story → **Edit Tags** to set its tags as a comma-separated list (this replaces the story's existing tags)
- A story's current tags, if any, are shown in its long-press popup
- Not yet available for NewsBlur, FreshRSS, Miniflux, or Fever API accounts

## Reading List (Story Queue)
The plugin includes a temporary reading list that lets you queue stories for later reading or batch saving:

### Adding Stories to the List
- **From story preview**: Tap **Add to List** in the toolbar
- **From feed list**: Long-press any story → **Add to List**
- Stories are automatically marked as read when added to the list
- Maximum capacity: 500 stories
- Duplicate detection: Stories already in the list won't be added again

### Accessing the List
- Open **RSS Reader** from the main menu
- Tap **List** to view all queued stories
- The list shows the number of stories currently queued

### List Management
- **Story List**: View all queued stories with read/unread indicators
- **Save All**: Download all stories in the list to your designated save folder
  - Progress dialog shows current status
  - Tap outside the progress dialog to cancel
  - Successfully saved stories are automatically removed from the list
- **Clear List**: Remove all stories from the list at once
- **Remove Individual Stories**: Long-press any story in the list → **Remove from list**

### Navigation Behavior
- When you open a story from the list and return to RSS Reader, you're taken back to the pool story list at your last position
- This mirrors the behavior of normal feed story lists for a consistent experience

### Tap Actions in the List
The tap action setting also applies to stories in the reading list:
- **Show preview** – Opens the story preview screen
- **Open directly** – Opens the story immediately
- **Save only** – Downloads the story to your save folder and removes it from the list

## Tap Action on Feed Items
Configure what happens when you tap a story in the feed list:
- Open **RSS Reader** → **Settings** → **Tap action on feed items**
- Choose one of four modes:
  - **Show preview** (default) – Opens the story preview screen
  - **Open directly** – Downloads and opens the story immediately
  - **Save only** – Downloads the story without opening it
  - **Add to list** – Adds the story to the reading list
- The setting applies to all account types (local, NewsBlur, CommaFeed, FreshRSS) and the reading list

## Moving Between Articles in the Preview
The story preview's toolbar has **Previous**, **Next** and **Next unread** buttons. On devices with page turn keys, the keys also carry on past the article's edges:
- On the **last page**, the next-page key opens the next article; on the **first page**, the previous-page key opens the previous one. Inside the article the keys turn pages as usual
- Configure it under **RSS Reader** → **Settings** → **Page keys at article edges**: **Next / previous article** (default), **Next / previous unread article**, or **Do nothing**
- The next article opens over the current one, with a *Loading article…* message while it is prepared, so the list is not flashed in between
- Opening an article marks it read, as tapping it in the list does

## Returning to RSS from an Opened Article

When you open a story, it is downloaded to the RSS Reader cache and handed to KOReader, which opens it as a normal document. From there the RSS menus are gone, so the plugin adds several ways back to the feed list you came from. All of them are optional and configured under **RSS Reader** → **Settings** → **Return to RSS from an article**:

- **Show floating button** – A small `RSS` button drawn in a corner of every page. On by default on touchscreens, off by default on key-only devices (where there is nothing to tap)
- **Corner tap returns to the list** – Makes that corner tappable. Works with the button hidden too, if you prefer no permanent overlay on an e-ink screen
- **Corner** – Which corner the button and its tap area live in: bottom right (default), bottom left, top right, top left. Bottom right is the default because it is the least contested spot: the top strip doubles as KOReader's menu tap zone, the top right corner is where the bookmark dogear is drawn and where the Gestures plugin puts *toggle bookmark*, while the bottom right corner ships with no action of its own. In a bottom corner the button sits just above the status bar rather than on top of it
- **Ask at end of article** – Replaces KOReader's end-of-document dialog with one offering **Back to RSS list**, **Next**, **Next unread**, **Go to beginning** and **File browser**. **Next** and **Next unread** open the following story of the list the article came from, the same way the list would (marked read, opened as a document). They are greyed out for articles opened from the reading list
- **Back key returns to the list** – On devices with a Back key, pressing it in an article returns to the feed list instead of prompting to exit KOReader. It only steps in when there is nothing left to go back to inside the article itself, so following links and jumping around keeps working normally
- **Enabled** – Master switch for all of the above

Returning opens the feed list *on top of* the article. Tapping another story opens it as usual. Leaving RSS Reader from there (**Back** on the top level, or closing the list) closes the article too and opens the file browser at your home folder, rather than dropping you back into an article whose only way out is the list again. KOReader remembers your position, so opening the article again from the list resumes where you left off.

Two things this deliberately does not cover:

- **Articles saved to your library** (the *Save* action, rather than opening from a list) are ordinary books; they get no RSS button
- **Sanitized links** opened with the *Open Sanitized* link popup button are written to the same cache but are opened from inside some other book, so they get no RSS button either

You can also reach RSS Reader from an open document through the top menu (**Search** tab → **RSS Reader**), or by assigning the **RSS Reader** action to a gesture, or — on key devices — to a hotkey via the Hotkeys plugin.

## Devices Without a Touchscreen

On devices with physical keys only (Kindle 3/4, key-based Kobo/PocketBook models), the plugin is driven entirely with the hardware buttons:

- **Up / Down** – Move the selection through the list; the selection wraps around onto the **Back** button below the last item
- **Press** (5-way center) – Open the selected entry, or activate the focused **Back** button
- **Long-press equivalent** (context menu of the selected entry) – `ScreenKB` + `Press` on Kindle 4, `Shift` + `Press` on keyboard devices, or the `Right` key on few-key devices
- **Page turn buttons** – Previous / next page in lists, scroll up / down in the story preview; past the preview's first / last page they move to the previous / next article (see [Moving Between Articles in the Preview](#moving-between-articles-in-the-preview))
- **Menu** – Opens the Refresh / Mark all as read menu of the feed tree or story list on screen (see [Refreshing](#refreshing))
- **Back** – Go up one level (feed → category → account list); on the top level it closes RSS Reader. It also closes the story preview
- **Back inside an opened article** – Returns to the feed list you came from instead of prompting to exit KOReader (see [Returning to RSS from an Opened Article](#returning-to-rss-from-an-opened-article)). On Kindle 4 you can additionally bind the **RSS Reader** action to a `ScreenKB` + key combination with the Hotkeys plugin

## Image Download Settings
The `features` block in `rssreader_configuration.lua` controls how the plugin fetches and displays article images. Three switches let you balance visual richness with bandwidth and storage:

- **`download_images_when_sanitize_successful`** – When the active sanitizer returns cleaned HTML, enable this to download the referenced images alongside the sanitized content. Disable it if you prefer faster syncs or limited storage usage.
- **`download_images_when_sanitize_unsuccessful`** – Determines whether images should still be fetched when sanitizers fail and the original feed HTML is used instead. Turn it on if you want images even without sanitized content; leave it off to avoid extra downloads in fallback scenarios.
- **`show_images_in_preview`** – Controls whether images appear in the story preview screen. Disable to prioritize text-only previews or reduce clutter; enable to keep the original illustrations visible while browsing stories.
- **`image_download_workers`** – How many images are fetched at the same time (default `4`, maximum `8`). Image downloads spend nearly all their time waiting on the network, so fetching several at once makes an image-heavy article land in a fraction of the time. Each worker is a short-lived forked process that writes its image straight to the asset cache; the progress message and tap-to-cancel keep working as before. Set it to `1` to go back to downloading one image after the other (e.g. for a server that dislikes concurrent requests).

## EPUB Book Metadata
When a story is saved as EPUB, the plugin fills in the metadata KOReader shows in
**Book information** and in the file manager. Everything is derived from data
already downloaded — the feed entry, the article HTML, and the images in the
asset cache — so richer metadata never costs an extra request.

- **Author(s)** – the entry's own byline (`author`/`creator`, which CommaFeed,
  Fever, FreshRSS, Miniflux and NewsBlur all provide) on the first line, and the
  feed title on the second. Entries that omit a byline fall back to the article
  markup (`<meta name="author">`, `article:author`, `rel="author"`,
  `itemprop="author"`); guesses that look like a date, a URL or a sentence are
  discarded rather than shown.
- **Description** – the entry's own summary, or, when the feed provides none, a
  ~320-character excerpt built from the article's opening paragraphs with
  headings and figure captions removed.
- **Cover** – the thumbnail the feed nominates (`media:thumbnail`,
  `media:content`, an image enclosure, `itunes:image`, JSON-Feed `image`) when it
  is among the article's images. Otherwise the first cached image whose real
  pixel size looks like an illustration rather than an icon or a banner strip,
  measured by reading PNG/GIF/JPEG headers off disk. Requires image downloads to
  be enabled.
- **Designed cover** – on by default (**Settings → Designed EPUB cover**), the
  plugin paints its own cover instead of using the lead image bare: the title on
  top, the lead image cropped into a landscape band in the middle, and the
  byline plus feed name at the bottom. Articles with no usable image get a
  text-only cover, so every saved story has a readable spine in the library. The
  image used is the one already picked above, downloaded once and reused for the
  article body. Switch it off to keep the plain lead-image cover.
- **Chapters** – the article's `<h1>`–`<h6>` get anchors and the EPUB carries a
  nested table of contents. Heading levels are normalized, so an article built
  out of `<h2>`/`<h3>` still starts at TOC depth 1.

## Content Sanitizers
Sanitizers fetch and normalize full-page article HTML before it is shown in KOReader. When you open a story the plugin iterates over the active sanitizers in the order configured under `sanitizers` in `rssreader_configuration.lua`. Each sanitizer tries to produce cleaned HTML; if it fails (for example, by returning empty content or hitting an error) the plugin automatically falls back to the next sanitizer in the list, and eventually to the original feed content if none succeed.

- **Instaparser** – Uses the Instaparser Article API to extract clean article content. Requires an API token from [instaparser.com](https://instaparser.com/). The free tier provides **1,000 requests per month**. Set the token in the sanitizer configuration entry. In measurements over Turkish news and blog feeds it answered in **1.4–4.4 s** (median 2.9 s) and tolerated back-to-back calls without rate limiting, which makes it a good first entry.
- **Diffbot** – Uses the Diffbot Analyze API to extract article bodies. Diffbot requires a token tied to a work e-mail domain and the free tier currently grants **10,000 credits per month**. Set the token in the sanitizer configuration entry.
  Diffbot extracts server-side and sends nothing until it is finished, so it is considerably slower than Instaparser: measured over the same Turkish feeds it took **3.6–23.4 s** (median 9.1 s) per article. It is also rate-limited far below its credit budget — the free `kgfree` plan allows roughly one call every 10 s and answers `429` with a `Retry-After` — so six back-to-back articles produced one success and five rejections. The plugin honours `Retry-After` once (up to 12 s) before falling through to the next sanitizer.
  Two knobs matter here. `timeout` (milliseconds, default **30000**) is Diffbot's own budget for fetching the target page; without enough of it Diffbot gives up and returns `errorCode 500` on slow sites. The socket budget is derived from it automatically. Both are ceilings, not delays: a page Diffbot extracts in 3 s still opens in 3 s.
- **FiveFilters** – Calls a Full-Text RSS `makefulltextfeed.php` endpoint. The free public service at `ftr.fivefilters.net` has been **discontinued** (it answers `410 Gone` with an empty feed), so this type is only useful with `base_url` pointing at your own Full-Text RSS instance. It sends no credentials.
- **FiveFilters (RapidAPI)** – `type = "fivefilters_rapidapi"`. Same endpoint and same output, reached through the [FiveFilters API on RapidAPI](https://rapidapi.com/fivefilters/api/full-text-rss), which authenticates with a key sent as request headers. Put the key in `token`; `base_url` is optional and defaults to `https://full-text-rss.p.rapidapi.com`. The free plan costs nothing to subscribe to but includes only **250 requests per month**, and it is a *soft* limit: further calls are not blocked, they are billed (currently $0.05 each) up to a hard ceiling of 2,000 calls. The plugin therefore counts requests itself and stops when `monthly_request_limit` (default **250**) is reached, falling back to the next sanitizer until the month rolls over. Set it to `0` to lift the ceiling, or raise it on a paid plan. The count lives in `data/rssreader_sanitizer_quota.json` and resets on its own each month.

Mix and match the sanitizers to suit your feeds. Keep the most reliable option first so it is attempted before the fallbacks — and bear in mind that order costs time as well as accuracy, because every sanitizer that fails is waited out before the next one is tried. Putting a slow sanitizer such as Diffbot ahead of a fast one such as Instaparser delays every article by the first one's failure, so if you run both, ordering Instaparser first is usually the better default.

Note that Diffbot, Instaparser and the RapidAPI variant all send the URL of every article you open to a third-party service, and their keys are stored in plain text in `rssreader_configuration.lua`.

### Mark All as Read
- **Long-press any feed title** to open the contextual menu.
- Choose **Mark all as read** to update the read state for every story in that feed.
- Inside a feed tree, folder or story list, the title bar menu (top left) offers the same for what is on screen.

## OPML Import/Export
The plugin supports importing and exporting feeds in OPML format, making it easy to migrate feeds from other RSS readers or backup your current subscriptions.

### Importing Feeds from OPML
1. Place your `.opml` or `.xml` file in the plugin directory (`plugins/rssreader.koplugin/`)
2. Open **RSS Reader** from the main menu
3. Tap **Settings** → **Import from OPML**
4. If multiple OPML files are found, select the one you want to import
5. Enter a name for the new local account that will contain the imported feeds
6. Tap **Import**
7. **Restart KOReader** for the changes to take effect

The import process will:
- Parse the OPML file and extract all feeds and groups/folders
- Create a new local account entry in `rssreader_configuration.lua`
- Add all feeds and groups to `rssreader_local_defaults.lua` under the new account name
- Preserve the folder structure from the OPML file as groups

### Exporting Feeds to OPML
1. Open **RSS Reader** from the main menu
2. Tap **Settings** → **Export to OPML**
3. The plugin will export all local accounts to `export.opml` in the plugin directory

The exported OPML file includes:
- All local accounts as top-level folders
- All groups within each account as nested folders
- All feeds with their titles and URLs
- Standard OPML 2.0 format compatible with most RSS readers

**Note**: Only local accounts are included in the export. NewsBlur, CommaFeed, FreshRSS, and Miniflux accounts are managed by their respective services and are not exported.

## Ready-to-Use Defaults
- If you need a template, use `rssreader_configuration.sample.lua` and rename it to `rssreader_configuration.lua` after customizing.
- The "Sample" and "Tech Blogs" groups in `rssreader_local_defaults.sample.lua` give you starting points. Rename the file to `rssreader_local_defaults.lua` once you finish editing.

## How It Differs from the Built-in News Downloader
- **Account Support**: The built-in News downloader fetches individual feeds without account concepts. The plugin lets you maintain multiple accounts (even of the same service type) with stored preferences.
- **Navigation Experience**: News downloader delivers articles into KOReader’s book list as offline documents. The plugin keeps everything inside a dedicated UI with hierarchical menus, so you browse accounts, folders, and feeds in one place.
- **External Service Sync**: When you connect NewsBlur or CommaFeed, their servers keep past items available in the list and track what you have read, so the same history and read state follows you across devices.
- **Read/Unread Workflow**: The plugin exposes read-state toggles and other actions directly in the story list and viewer, while the default tool focuses on downloading static bundles.

Enjoy your reading!
