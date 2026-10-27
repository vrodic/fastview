# FastView

FastView is a high-performance macOS image viewer written in Swift and AppKit, built specifically for ultra-fast browsing of local directories and archives (ZIP and RAR formats).

## Features

- **Fast Directory & Archive Navigation**: Browse through image collections, nested subfolders, and compressed archives seamlessly.
- **Archive Support**: Native in-memory archive reading for ZIP and RAR files (including nested archive directories).
- **Favorites Management**: Toggle favorite items (Cmd+F) and browse favorites mode (Option-F / ⌥F).
- **Low Memory Mode**: Optional minimal caching mode limiting memory cache to at most 10 LRU items.
- **Recursive Thumbnail Peeking**: Automatic thumbnail extraction for directories/archives by naturally sorting contents and recursively traversing until the first image is found.
- **Visual Sidebar Badges**: Large overlay badges for favorites (star) and folders/archives (type icons) on sidebar cells.
- **File Information Panel**: Metadata panel (Cmd+I) with thumbnail, kind, size, location, image properties (dimensions, colour profile, DPI), camera EXIF (camera, lens, exposure, date taken, GPS), folder/archive contents and dates. It follows the selection while open.
- **Command-Line Integration**: Launch with a directory parameter (`FastView /path/to/folder`) to automatically open in Show All mode.

## Shortcuts & Controls

- `Up / Down`: Previous / Next image
- `Cmd + Up / Cmd + Down`: Skip to previous / next folder or archive
- `Left / Right`: Previous / Next sibling directory or archive
- `Cmd + F`: Toggle Favorite on selected item
- `Option + F` (`⌥F`): Toggle Favorites browsing mode
- `Cmd + L`: Switch to All Mode at current item location
- `Cmd + I`: File Info dialog
- `Enter`: Open directory / archive or advance selection
- `Escape`: Navigate up / exit archive

## Building & Running

FastView uses Swift Package Manager:

```bash
swift build
swift run FastView [/optional/path/to/directory]
```
