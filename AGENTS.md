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
  - `StatusBarView.swift`: Status bar at bottom displaying location, index, count, and size metrics.
- `Sources/FastView/Cache/`:
  - `MemoryLRUCache.swift`: In-memory image cache supporting Low Memory Mode (capped at 10 items when active).
  - `SQLiteCache.swift`: SQLite database (`fastview_cache.sqlite`) for favorite persistence and directory structure caching.
  - `ThumbnailGenerator.swift`: Background and priority thumbnail extraction and recursive preview peeking.
  - `DirectoryCache.swift`: Fast in-memory caching of directory file item lists.
  - `ArchiveThumbCache.swift`: Local on-disk cache of archive thumbnails and image lists (`~/Library/Caches/FastView/ArchiveThumbs`, one JSON + JPEG per archive keyed by a hash of its path), validated by archive size and modification date.
- `Sources/FastView/Archive/`:
  - `ArchiveReader.swift`: Archive entry-list cache, listing, and entry extraction, all requested from `ArchiveHelper`.
  - `ArchiveHelper.swift`: Client for the long-lived `FastViewReader` helper that does all archive I/O; receives only entry lists and extracted images (via POSIX shared memory) and kills the helper when a priority operation cancels a request.
  - `DiskIOGate.swift`: Serialises disk I/O; interactive work is admitted before background work.
  - `NavigationManager.swift`: Navigation history, current location tracking, and path location resolution.
  - `FileLogger.swift`: Performance logging.
- `Sources/FastViewArchiveCore/`: Archive code shared by the app and the helper: `ArchiveService` (open-archive cache; list/extract/preview/prefetch requests; RAR whole-file reads into shared memory that survive a killed helper), `ZipDirectory` (ZIP central-directory parser and ranged entry reads — ZIP archives are never read whole), `RarArchive`, `ArchivePreview` (preview-image choice, thumbnails), `SharedMemoryRegion`, request/response types.
- `Sources/FastViewReader/`: The helper executable, a request loop around `ArchiveService`; built next to `FastView`.
- `Sources/CFastViewShm/`: C shim for `shm_open` (variadic, not callable from Swift) and atomic header words.

## Code Conventions & Directives

1. **Safety & Nullability**: Swift optionals and guard statements should be preferred for clean error handling.
2. **I/O Operations**: Do not perform synchronous disk/network I/O on the main thread. Always offload I/O to appropriate operation queues (`priorityQueue` or `thumbnailQueue` in `ThumbnailGenerator`). Archive I/O goes through `ArchiveHelper` and takes an `isCancelled` check so a priority operation can kill it.
3. **UI Updates**: All UI changes (updating table views, views, menu items, or status bar) must be dispatched back to `DispatchQueue.main`.
4. **Badges & Overlay Formatting**: Overlay badges in `SidebarTableCellView` use SF Symbols with symbol configuration (e.g. `pointSize: 28, weight: .bold`) inside 44x44 pt frames.
