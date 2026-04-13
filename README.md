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

Other services like NewsBlur, FreshRSS, and Miniflux are fully supported with similar features. Miniflux provides native API support with folder/category organization and mark as read functionality.

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
- **NewsBlur & Fever API**: Virtual feeds cannot be marked as read in bulk. Use individual feeds for "Mark all as read" functionality.

## Tap Action on Feed Items
Configure what happens when you tap a story in the feed list:
- Open **RSS Reader** → **Settings** → **Tap action on feed items**
- Choose one of three modes:
  - **Show preview** (default) – Opens the story preview screen
  - **Open directly** – Downloads and opens the story immediately
  - **Save only** – Downloads the story without opening it
- The setting applies to all account types (local, NewsBlur, CommaFeed, FreshRSS)

## Image Download Settings
The `features` block in `rssreader_configuration.lua` controls how the plugin fetches and displays article images. Three switches let you balance visual richness with bandwidth and storage:

- **`download_images_when_sanitize_successful`** – When the active sanitizer returns cleaned HTML, enable this to download the referenced images alongside the sanitized content. Disable it if you prefer faster syncs or limited storage usage.
- **`download_images_when_sanitize_unsuccessful`** – Determines whether images should still be fetched when sanitizers fail and the original feed HTML is used instead. Turn it on if you want images even without sanitized content; leave it off to avoid extra downloads in fallback scenarios.
- **`show_images_in_preview`** – Controls whether images appear in the story preview screen. Disable to prioritize text-only previews or reduce clutter; enable to keep the original illustrations visible while browsing stories.

## Content Sanitizers
Sanitizers fetch and normalize full-page article HTML before it is shown in KOReader. When you open a story the plugin iterates over the active sanitizers in the order configured under `sanitizers` in `rssreader_configuration.lua`. Each sanitizer tries to produce cleaned HTML; if it fails (for example, by returning empty content or hitting an error) the plugin automatically falls back to the next sanitizer in the list, and eventually to the original feed content if none succeed.

- **Instaparser** – Uses the Instaparser Article API to extract clean article content. Requires an API token from [instaparser.com](https://instaparser.com/). The free tier provides **1,000 requests per month**. Set the token in the sanitizer configuration entry.
- **Diffbot** – Uses the Diffbot Analyze API to extract article bodies. Diffbot requires a token tied to a work e-mail domain and the free tier currently grants **10,000 credits per month**. Set the token in the sanitizer configuration entry.
- **FiveFilters** – Calls the FiveFilters Full-Text RSS endpoint. No account or token is required; you simply enable the sanitizer in the configuration.

Mix and match the sanitizers to suit your feeds. Keep the most reliable option first so it is attempted before the fallbacks.

### Mark All as Read
- **Long-press any feed title** to open the contextual menu.
- Choose **Mark all as read** to update the read state for every story in that feed.

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
