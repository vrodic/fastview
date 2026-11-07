import AppKit

/// What can be done with a listed item's file in the Finder and other apps.
enum FileActions {
    /// A real file or folder, not an archive entry or the (..) row.
    static func isOnDisk(_ item: FileItem) -> Bool {
        item.type != .parentDirectory && (item.archivePath ?? "").isEmpty
    }

    /// Reveals the file; an archive entry reveals its archive.
    static func showInFinder(_ item: FileItem) {
        guard item.type != .parentDirectory else { return }
        let archive = item.archivePath.flatMap { $0.isEmpty ? nil : $0 }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archive ?? item.path)])
    }

    static func openInDefaultApp(_ item: FileItem) {
        guard isOnDisk(item) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }
}
