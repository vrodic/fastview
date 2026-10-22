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
  - `StatusBarView.swift`: Status bar at bottom displaying location, index, count, and size metrics.
- `Sources/FastView/Cache/`:
  - `MemoryLRUCache.swift`: In-memory image cache supporting Low Memory Mode (capped at 10 items when active).
  - `SQLiteCache.swift`: SQLite database (`fastview_cache.sqlite`) for favorite persistence and directory structure caching.
  - `ThumbnailGenerator.swift`: Background and priority thumbnail extraction and recursive preview peeking.
  - `DirectoryCache.swift`: Fast in-memory caching of directory file item lists.
- `Sources/FastView/Archive/`:
  - `ArchiveReader.swift`: In-memory ZIP and RAR archive listing and entry extraction.
  - `NavigationManager.swift`: Navigation history, current location tracking, and path location resolution.
  - `FileLogger.swift`: Performance logging.

## Code Conventions & Directives

1. **Safety & Nullability**: Swift optionals and guard statements should be preferred for clean error handling.
2. **I/O Operations**: Do not perform synchronous disk/network I/O on the main thread. Always offload I/O to appropriate operation queues (`priorityQueue` or `thumbnailQueue` in `ThumbnailGenerator`).
3. **UI Updates**: All UI changes (updating table views, views, menu items, or status bar) must be dispatched back to `DispatchQueue.main`.
4. **Badges & Overlay Formatting**: Overlay badges in `SidebarTableCellView` use SF Symbols with symbol configuration (e.g. `pointSize: 28, weight: .bold`) inside 44x44 pt frames.
