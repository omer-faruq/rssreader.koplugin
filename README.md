# RSS Reader Plugin

The KOReader **RSS Reader** plugin lets you follow RSS feeds from a single screen. For everyday use you only need to define your account and pick the local feeds you care about.

## Who Is It For?
- **Readers who want to add their own RSS accounts**
- **Users who prefer to use the local feed bundles**

These scenarios require you to know only two files. Both are provided as `.sample.lua` templates; rename them after editing so the plugin can load them.

## Files You Need to Edit
- **`rssreader_configuration.sample.lua` → rename to `rssreader_configuration.lua`**: Describe your accounts and per-account preferences.
  - Provide the name, service type (`local`, `newsblur`, `commafeed`), login details, and options.
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
- In the feed list, a long press lets you open the original website, save the article, or toggle read/unread.
- For local accounts, the groups and feeds defined in your renamed `rssreader_local_defaults.lua` appear. Editing the URLs here is how you add new sources.

## Image Download Settings
The `features` block in `rssreader_configuration.lua` controls how the plugin fetches and displays article images. Three switches let you balance visual richness with bandwidth and storage:

- **`download_images_when_sanitize_successful`** – When the active sanitizer returns cleaned HTML, enable this to download the referenced images alongside the sanitized content. Disable it if you prefer faster syncs or limited storage usage.
- **`download_images_when_sanitize_unsuccessful`** – Determines whether images should still be fetched when sanitizers fail and the original feed HTML is used instead. Turn it on if you want images even without sanitized content; leave it off to avoid extra downloads in fallback scenarios.
- **`show_images_in_preview`** – Controls whether images appear in the story preview screen. Disable to prioritize text-only previews or reduce clutter; enable to keep the original illustrations visible while browsing stories.

## Content Sanitizers
Sanitizers fetch and normalize full-page article HTML before it is shown in KOReader. When you open a story the plugin iterates over the active sanitizers in the order configured under `sanitizers` in `rssreader_configuration.lua`. Each sanitizer tries to produce cleaned HTML; if it fails (for example, by returning empty content or hitting an error) the plugin automatically falls back to the next sanitizer in the list, and eventually to the original feed content if none succeed.

- **Diffbot** – Uses the Diffbot Analyze API to extract article bodies. Diffbot requires a token tied to a work e-mail domain and the free tier currently grants **10,000 credits per month**. Set the token (and optional parameters such as `mode`) in the sanitizer configuration entry.
- **FiveFilters** – Calls the FiveFilters Full-Text RSS endpoint. No account or token is required; you simply enable the sanitizer in the configuration.

Mix and match the sanitizers to suit your feeds. Keep the most reliable option first so it is attempted before the fallbacks.

### Mark All as Read
- **Long-press any feed title** to open the contextual menu.
- Choose **Mark all as read** to update the read state for every story in that feed. 

## Ready-to-Use Defaults
- If you need a template, use `rssreader_configuration.sample.lua` and rename it to `rssreader_configuration.lua` after customizing.
- The "Sample" and "Tech Blogs" groups in `rssreader_local_defaults.sample.lua` give you starting points. Rename the file to `rssreader_local_defaults.lua` once you finish editing.

## How It Differs from the Built-in News Downloader
- **Account Support**: The built-in News downloader fetches individual feeds without account concepts. The plugin lets you maintain multiple accounts (even of the same service type) with stored preferences.
- **Navigation Experience**: News downloader delivers articles into KOReader’s book list as offline documents. The plugin keeps everything inside a dedicated UI with hierarchical menus, so you browse accounts, folders, and feeds in one place.
- **External Service Sync**: When you connect NewsBlur or CommaFeed, their servers keep past items available in the list and track what you have read, so the same history and read state follows you across devices.
- **Read/Unread Workflow**: The plugin exposes read-state toggles and other actions directly in the story list and viewer, while the default tool focuses on downloading static bundles.

Enjoy your reading!
