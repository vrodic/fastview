# AGENTS.md

Instructions and guidelines for AI agents developing and maintaining FastView.

## Project Architecture Overview

FastView is built using Swift, AppKit, and Swift Package Manager.

### Structure
- `Sources/FastView/Main.swift`: Application entry point (`AppDelegate`), menu bar creation, and command-line launch handling.
- `Sources/FastView/Views/`:
  - `MainSplitViewController.swift`: Core application coordinator, split view layout, and navigation state.
  - `SidebarViewController.swift`: Sidebar table view (`NSTableView`), cell configuration (`SidebarTableCellView`), custom keyboard input handling, and cell badge rendering.
  - `MainImageView.swift`: Image canvas, zooming, panning, and loading indicator overlay.
  - `ListSorter.swift`: Per-pane list sort options (name, modified date, favorites, viewed; persisted in UserDefaults) and the sort itself, run off the main thread. The parent entry stays first and folders/archives stay ahead of images.
  - `CombinationStateManager.swift`: Saved combinations, one pretty-printed JSON `.fastview` file each in `~/Documents/FastView` (file I/O on a serial queue). Objects are stored in z order with normalized positions, region crop and colour adjustment; restoring re-runs detection on their source items through `ForegroundSource` (its own load queue, so pane image loads cannot cancel it). Preview thumbnails for the manager window are cached in `~/Library/Caches/FastView/CombinationPreviews`.
  - `CombinationStatesWindowController.swift`: Saved-combinations manager window (previews, search, rename, Show in Finder, Move to Trash).
  - `RestoreProgressView.swift`: Overlay with a progress bar shown over the canvas while a saved combination restores (pane images + objects; tracked in `MainSplitViewController`).
  - `ColorMatcher.swift`: Matches objects' colours to a reference object, led by skin tones (YCbCr skin test, grey-world retry for colour casts; per-channel gains match average skin colour), falling back to whole-object mean/spread matching.
  - `StatusBarView.swift`: Status bar at bottom displaying location, index, count, and size metrics.
- `Sources/FastView/Cache/`:
  - `MemoryLRUCache.swift`: In-memory image cache supporting Low Memory Mode (capped at 10 items when active).
  - `SQLiteCache.swift`: SQLite database (`fastview_cache.sqlite`) for favorite persistence and directory structure caching.
  - `ThumbnailGenerator.swift`: Background and priority thumbnail extraction and recursive preview peeking.
  - `DirectoryCache.swift`: Fast in-memory caching of directory file item lists.
  - `ArchiveThumbCache.swift`: Local on-disk cache of RAR archive thumbnails and image lists (`~/Library/Caches/FastView/ArchiveThumbs`, one JSON + JPEG per archive keyed by a hash of its path), validated by archive size and modification date. ZIP archives are not cached: their directory and preview are read by range, which is as quick.
- `Sources/FastView/Archive/`:
  - `ArchiveReader.swift`: Archive entry-list cache, listing, and entry extraction, all requested from `ArchiveService`.
  - `ArchiveService.swift`: In-process archive I/O, one request at a time: open-archive cache; list/extract/preview/prefetch requests, each stopping at its next read once its `isCancelled` check turns true. Network RAR archives are read whole first, and a stopped read resumes where it stopped.
  - `ZipDirectory.swift`: ZIP central-directory parser and ranged entry reads (ZIP archives are never read whole).
  - `RarArchive.swift`: unrar header scan and entry extraction, with progress and cancellation.
  - `ArchivePreview.swift`: Preview-image choice and thumbnail downscaling, shared by the archive service and the sidebar.
  - `DiskIOGate.swift`: Serialises disk I/O; interactive work is admitted before background work.
  - `NavigationManager.swift`: Navigation history, current location tracking, and path location resolution.
  - `FileLogger.swift`: Performance logging.

## Code Conventions & Directives

1. **Safety & Nullability**: Swift optionals and guard statements should be preferred for clean error handling.
2. **I/O Operations**: Do not perform synchronous disk/network I/O on the main thread. Always offload I/O to appropriate operation queues (`priorityQueue` or `thumbnailQueue` in `ThumbnailGenerator`). Archive I/O goes through `ArchiveService` and takes an `isCancelled` check so a priority operation can stop it.
3. **UI Updates**: All UI changes (updating table views, views, menu items, or status bar) must be dispatched back to `DispatchQueue.main`.
4. **Badges & Overlay Formatting**: Overlay badges in `SidebarTableCellView` use SF Symbols with symbol configuration (e.g. `pointSize: 28, weight: .bold`) inside 44x44 pt frames.
