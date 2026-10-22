# AGENTS.md

This document provides instructions, architecture overviews, and development guidelines for automated agents and developers working on the **FastView** codebase.

---

## Project Overview

**FastView** is a native macOS application built with Swift and AppKit, managed via Swift Package Manager (`Package.swift`). It provides high-speed browsing and viewing of images and compressed archives (ZIP, RAR4, RAR5) with zero disk-extraction overhead.

---

## Architecture & Codebase Structure

The source code is located under `Sources/FastView/` and organized as follows:

```
Sources/FastView/
├── Main.swift                    # App entry point (@main), AppDelegate, menu bar setup, CLI arguments
├── Archive/
│   ├── ArchiveReader.swift       # ZIP & RAR entry listing and in-memory image extraction
│   ├── NavigationManager.swift   # Navigation stack, location resolution, and hierarchy traversal
│   └── FileLogger.swift          # Diagnostic timing and operation logging
├── Cache/
│   ├── SQLiteCache.swift         # Persistent SQLite database (favorites, view history, directory listings)
│   ├── MemoryLRUCache.swift      # In-memory raw image Data LRU cache with Low Memory Mode support
│   ├── DirectoryCache.swift      # In-memory directory content structure cache
│   └── ThumbnailGenerator.swift  # Asynchronous background thumbnail & full image loading pipeline
└── Views/
    ├── MainWindowController.swift    # NSWindowController and window frame initialization
    ├── MainSplitViewController.swift # Core NSSplitViewController coordinating sidebar & main image view
    ├── SidebarViewController.swift   # NSTableView sidebar with dynamic row height & badge overlays
    ├── MainImageView.swift           # Scrollable/zoomable main image view & loading overlay
    └── StatusBarView.swift           # Bottom status bar displaying path, metrics, and image stats
```

---

## Key Concepts & Patterns

1. **In-Memory Operations**
   - Archive entries (ZIP/RAR) are read directly into memory buffers without writing extracted files to disk.
   - `MemoryLRUCache` caches compressed image `Data` rather than uncompressed `NSImage` objects to minimize memory footprint.

2. **View History & Persistence (`SQLiteCache`)**
   - SQLite database is located at `~/Library/Caches/FastView/fastview_cache.sqlite`.
   - Tables:
     - `directory_entries`: Cached directory listing metadata.
     - `favorites`: Persistent list of favorited `FileItem` entries.
     - `view_history`: Persistent record of full image views containing `path`, `last_viewed_at`, and `view_count`.
   - Recording views: Triggered when `ThumbnailGenerator.shared.loadFullImage` completes successfully in `MainSplitViewController.displayItem`.

3. **Badge Overlays in Sidebar**
   - `SidebarTableCellView` includes two badge overlays:
     - `favoriteBadge` (top-right, yellow star): displayed when `SQLiteCache.shared.isFavorite` returns true.
     - `checkmarkBadge` (top-left, green checkmark circle): displayed when `SQLiteCache.shared.isViewed` returns true.

4. **Low Memory Mode**
   - Controlled via `MemoryLRUCache.shared.isLowMemoryMode` (persisted in `UserDefaults` under `FastViewLowMemoryMode`).
   - Toggled from the menu bar (*Options -> Low Memory Mode*).
   - When active, restricts cache capacity to at most 10 LRU items.

5. **Command Line & Recent Directories**
   - If launched with a path argument (`CommandLine.arguments.count > 1`), `AppDelegate`:
     1. Adds/promotes path in `UserDefaults` list `FastViewRecentCmdLineDirs` (max 10 entries).
     2. Populates *File -> Open Recent Directory* submenu.
     3. Launches in **Show All Files** mode (`showFavoritesOnly = false`).

---

## Building & Verification

### Build Command
On macOS with Swift 5.9+ / Xcode installed, compile using:

```bash
swift build -c release
```

### Verification Guidelines
- Ensure any changes to SQLite tables include fallback handling or table creation checks (`CREATE TABLE IF NOT EXISTS`).
- Verify main thread safety: UI updates, `NSTableView` reloads, and `NSAlert` modal calls MUST execute on `DispatchQueue.main`.
- Background I/O and archive extraction MUST execute off the main thread.
