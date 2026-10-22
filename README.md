# FastView

**FastView** is a high-performance, native macOS image and archive viewer written in Swift and AppKit. It is designed for ultra-fast navigation, responsive image previewing, and memory-efficient browsing of directories and compressed archives.

---

## Features

- **Fast Archive & Directory Browsing**
  - Instant navigation across local image folders, ZIP archives, and RAR archives (including RAR4 and RAR5 formats).
  - High-throughput entry reading with direct in-memory extraction (no temporary files created on disk).
  - Optional directory flattening mode for archives (*View -> Flatten Archive Directories*).

- **View Tracking & History**
  - Automatically records full image views with timestamps and view counts in a persistent SQLite database (`fastview_cache.sqlite`).
  - Displays a green checkmark badge overlay on viewed items in the sidebar thumbnail list.

- **Favorites & Filtering**
  - Toggle favorite status on any item using **Cmd+F**.
  - Quick toggle to browse favorites using **Option-F** (`⌥F`).
  - Favorites display a yellow star badge overlay in the sidebar list.

- **Low Memory Mode & MemoryLRUCache**
  - High-performance in-memory LRU cache storing compressed image data to minimize RAM overhead.
  - Toggleable **Low Memory Mode** (*Options -> Low Memory Mode*) to restrict cache capacity to a maximum of 10 LRU images.

- **File Information Dialog**
  - Inspect detailed metadata for selected items (*File -> Show Info* / **Cmd+I**), including full file path, formatted file size, last viewed timestamp, and view count.

- **Command Line & Recent Directories**
  - Launch from command line passing a directory or archive path parameter: `fastview /path/to/dir`.
  - Launching with a path argument automatically forces **Show All Files** mode.
  - Tracks explicitly opened command line directories under *File -> Open Recent Directory* (up to 10 entries) with a clear option.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Down Arrow` | Next image in list |
| `Up Arrow` | Previous image in list |
| `Cmd + Down` | Jump to first image in next folder / archive group |
| `Cmd + Up` | Jump to first image in previous folder / archive group |
| `Right Arrow` | Jump to next sibling directory or archive |
| `Left Arrow` | Jump to previous sibling directory or archive |
| `Enter` (`\r`) | Enter folder/archive or activate selected item |
| `Escape` (`\u{1B}`) | Navigate up to parent directory / exit archive |
| `Cmd + F` | Toggle favorite status for selected item |
| `Option + F` (`⌥F`) | Toggle "Show Favorites Only" mode |
| `Cmd + L` | Switch back to "Show All" location mode |
| `Cmd + I` | Open "Show Info" dialog for selected item |
| `Cmd + O` | Open file/folder picker dialog |
| `+` / `-` | Zoom in / Zoom out main image |
| `1` / `0` | Actual size / Zoom to fit main image |

---

## Requirements & Building

### Requirements
- macOS 13.0+
- Swift 5.9+ / Xcode 15+

### Build Instructions

To build FastView in release mode using Swift Package Manager:

```bash
swift build -c release
```

To run FastView from terminal:

```bash
.build/release/FastView [/path/to/directory_or_archive]
```
