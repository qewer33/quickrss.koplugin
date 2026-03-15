![banner](assets/quickrss_banner.png)

A fast, standalone and easy to use RSS reader plugin for [KOReader](https://github.com/koreader/koreader). Browse and read articles from your favourite feeds without leaving your e-reader.

## Features

![screenshots](assets/quickrss_screenshots.png)

**Feed list view**
- Thumbnail cards with a 16:9 cover-cropped image, bold title, source · date line, and a snippet preview
- Paginated list with swipe or hardware page-turn key navigation
- Read/unread tracking — unread articles show bold titles, read articles show regular weight
- Filter by feed, unread-only, saved-only, or any combination
- Pull-to-refresh fetches all feeds and updates the cache in one tap

**Article reader**
- Full HTML rendering via KOReader's built-in engine (paragraphs, bold, lists, images)
- Banner image at the top, followed by title, source · date · estimated reading time
- Swipe left/right or use the footer buttons to move between articles
- Articles are automatically marked as read when opened or navigated to
- Tap any link to copy it to clipboard or show a QR code for scanning on another device
- Tap any image for a full-screen preview
- Full e-ink refresh on open to eliminate ghosting

**Reader customisation**
- Font picker (any font installed on the device)
- Font size up to 64 pt
- Adjustable line spacing

**Image caching**
- Thumbnails & article content images are pre-fetched at fetch time so cards load instantly
- Orphaned images are cleaned up automatically after each fetch
- Independent settings to disable thumbnail images and/or article images

**Full-text extraction**
- Truncated RSS summaries are automatically enriched with full article text via [FiveFilters](https://fivefilters.org/)
- Can be toggled off for privacy or speed
- Supports custom extraction service URLs (e.g. a self-hosted FiveFilters instance)

**Offline-first**
- Articles are cached to disk and available without a network connection
- Configurable cache expiry (default: 10 days)
- Configurable per-feed article limit (default: 20 articles)

**OPML support**
- Feeds are stored as a .opml file
- Can be edited from a computer (`koreader/quickrss/feeds.opml`) or directly from the UI (**≡** → **Feeds**)

## Installation

1. Copy the `quickrss.koplugin/` directory into your KOReader plugins folder:

   | Platform | Path |
   |---|---|
   | Linux desktop | `~/.config/koreader/plugins/` |
   | Kindle | `/mnt/us/extensions/koreader/plugins/` |
   | Kobo | `.adds/koreader/plugins/` |
   | PocketBook | `applications/koreader/plugins/` |

2. Restart KOReader.
3. Open the search menu → **QuickRSS**.

### Development (Linux desktop)

```bash
./deploy.sh
```

This syncs the plugin to `~/.config/koreader/plugins/quickrss.koplugin/`, kills any running KOReader instance, and restarts it.

## Usage

### Adding feeds

1. Open QuickRSS from the KOReader main menu.
2. Tap the **≡** (hamburger) icon → **Feeds**.
3. Tap **Add feed**, enter a name and the RSS/Atom URL, then save.

### Fetching articles

Tap **≡** → **Fetch Articles**. QuickRSS fetches all configured feeds, downloads thumbnails, and updates the cache. A progress indicator shows the current feed being loaded.

### Reading an article

Tap any card in the list to open the article reader. Swipe left/right or tap the **◀** / **▶** footer buttons to navigate between articles. Tap **✕** to return to the feed list.

Articles are automatically marked as read when you open or swipe to them. You can also long-press an article in the feed list to toggle its read/unread state manually.

Tapping a link inside an article opens a menu with **Copy Link** (to clipboard) and **Show QR Code** (for easy transfer to a phone or computer). Tapping an image opens a full-screen preview.

Long-pressing an article card in the feed list (or tapping the title in the reader) shows a context menu with **Save/Unsave Article**, **Copy Link**, **Show QR Code**, **Mark as Read/Unread**, and **Delete From Cache**.

### Saving articles

Tap **Save Article** in the article context menu to bookmark an article. Saved articles are protected from all cache operations — they survive **Delete Read**, **Delete All Cache**, and cache expiry. You can view only saved articles using the **Show Saved Only** filter.

To remove saved articles, use **≡** → **Delete Saved**, or unsave them individually from the context menu.

### Settings

Tap **≡** → **Settings** to configure:

| Setting | Default | Description |
|---|---|---|
| Items per feed | 20 | Maximum articles fetched per feed |
| Cache max age | 10 days | How long before the cache is treated as empty (0 = never expire) |
| Thumbnail images | On | Enable/disable thumbnail images in the feed list |
| Article images | On | Enable/disable images inside articles |
| Card font size | 14 | Font size for article cards in the feed list |
| Full-text extraction | On | Fetch full article text for truncated feeds via extraction service |
| Extraction URL | Default | URL of the full-text extraction service (for self-hosted instances) |
| Custom DNS routing | Off | Use alternative DNS servers to fix missing images on some devices (see below) |

Reader font, font size, and line spacing can be changed from within any open article via the **⚙** icon in the title bar.

### Custom DNS routing

If some thumbnails or article images fail to load even though your device is connected to WiFi, try enabling **Custom DNS routing** in Settings. This is a known issue on some e-readers (notably Kobo) where the device's built-in name resolution stops working reliably after running for a while. The setting routes lookups through Google and Cloudflare DNS instead, which usually fixes the problem.

If your images are loading fine, you can leave this off.

### Filtering articles

Tap the filter button in the footer (shows **All Feeds** by default) to open the filter dialog. From here you can:

- **Show Unread Only** — toggle to hide already-read articles
- **Show Saved Only** — toggle to show only saved/bookmarked articles
- **Select a feed** — show articles from a single feed only

All filters can be combined. The filter button text updates to reflect the active filters (e.g. "Ars Technica (Unread, Saved)").

### Deleting articles

- **≡** → **Delete Read** — removes all read articles from the cache (saved articles are kept). Their links are remembered so they won't reappear on future fetches.
- **≡** → **Delete Saved** — removes all saved/bookmarked articles from the cache.
- **≡** → **Delete All Cache** — wipes all cached articles, images, and the dismissed article list (saved articles are preserved). The next **Fetch Articles** will start fresh.

## Project structure

```
quickrss.koplugin/
├── main.lua                    Plugin entry point — registers to KOReader main menu
├── _meta.lua                   Plugin metadata (name, version, author)
└── modules/
    ├── ui/                     UI widgets and screens
    │   ├── feed_view.lua       Main feed list UI and pagination
    │   ├── article_item.lua    Individual article card widget
    │   ├── article_reader.lua  Full-screen HTML article reader
    │   ├── feed_list.lua       Feed management popup (add / remove feeds)
    │   ├── settings.lua        Article settings popup
    │   ├── reader_settings.lua Reader font / size / spacing popup
    │   ├── settings_row.lua    Shared settings row builder
    │   └── icons.lua           Unicode icon constants
    ├── data/                   Data, persistence, and networking
    │   ├── config.lua          Persistent settings (feeds, article limits, reader prefs)
    │   ├── cache.lua           Article and image cache management
    │   ├── parser.lua          RSS / Atom feed fetching and parsing
    │   ├── opml.lua            OPML feed-list reader / writer
    │   └── images.lua          Image downloading and HTML image rewriting
    └── lib/                    Third-party libraries
        ├── xml.lua             Lightweight XML parser
        └── handler.lua         SAX-style XML event handler
```

## Data storage

All plugin data is stored in a dedicated `quickrss/` directory inside the KOReader data root:

| Platform | Data directory |
|---|---|
| Linux desktop | `~/.config/koreader/quickrss/` |
| Kindle | `/mnt/us/extensions/koreader/quickrss/` |
| Kobo | `.adds/koreader/quickrss/` |
| PocketBook | `applications/koreader/quickrss/` |

| File / Directory | Contents |
|---|---|
| `feeds.opml` | Feed list (OPML — edit this on your computer) |
| `settings.lua` | Article and reader settings |
| `cache.lua` | Cached article list and last-fetched timestamp |
| `images/` | Downloaded article images and thumbnails |

### Editing feeds on a computer

The feed list is stored as a standard OPML file. You can edit it directly in any text editor, or import a file exported from another RSS reader (Feedly, NewsBlur, etc.):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head><title>QuickRSS Feeds</title></head>
  <body>
    <outline text="Ars Technica" type="rss" xmlUrl="https://feeds.arstechnica.com/arstechnica/index"/>
    <outline text="Hackaday" type="rss" xmlUrl="https://hackaday.com/blog/feed/"/>
    <outline text="Science Daily - Science" type="rss" xmlUrl="https://www.sciencedaily.com/rss/top/science.xml"/>
  </body>
</opml>
```

Copy the file to the `quickrss/` directory listed above and the plugin will pick it up on the next open. Changes made through the in-device UI are written back to the same file automatically.
