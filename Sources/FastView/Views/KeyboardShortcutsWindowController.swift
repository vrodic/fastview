import AppKit

/// Help → Keyboard Shortcuts: everything the keyboard and mouse do, in one panel.
final class KeyboardShortcutsWindowController: NSWindowController {
    static let shared = KeyboardShortcutsWindowController()

    static let sections: [(title: String, shortcuts: [(keys: String, action: String)])] = [
        ("Browsing", [
            ("↓  ↑", "Next / previous item"),
            ("⌘↓  ⌘↑", "Next / previous folder or archive group"),
            ("→  ←", "Next / previous sibling folder or archive"),
            ("Page Down  Page Up", "Move a page through the list"),
            ("Home  End", "First / last item"),
            ("Return", "Open folder or archive, or go to the next image"),
            ("Esc  ⌫", "Go up, or leave the archive"),
            ("Type a name", "Jump to the item with that name"),
            ("⌘J", "Random image here"),
            ("⌥⌘J", "Random image in the selected folder or archive"),
        ]),
        ("Viewing", [
            ("⌘+  ⌘−", "Zoom in / out"),
            ("⌘0", "Zoom to fit"),
            ("⌘1", "Actual size"),
            ("Double click", "Switch between fit and actual size"),
            ("Scroll, pinch", "Zoom"),
            ("Drag", "Move around a zoomed image"),
            ("⌘R  ⌥⌘R", "Rotate right / left"),
            ("⌘B", "Show or hide the sidebar"),
            ("⌘Return", "Enter or exit full screen"),
            ("Esc", "Exit full screen"),
        ]),
        ("Files", [
            ("⌘O", "Open a folder, archive or image (or drop it on the window)"),
            ("⌘C", "Copy the image"),
            ("⇧⌘C", "Copy the file path"),
            ("⇧⌘S", "Save the image as…"),
            ("⇧⌘R", "Show in Finder"),
            ("⌘⌫", "Move to Trash"),
            ("⌘Z", "Undo Move to Trash"),
            ("⌘I", "Show Info"),
        ]),
        ("Favorites", [
            ("⌘F", "Add or remove favorite"),
            ("⌥F", "Show favorites in the list, or stop"),
            ("⇧⌘F", "Open the Favorites Viewer"),
            ("⌃Tab", "Switch tabs"),
            ("⌘W", "Close the Favorites Viewer"),
            ("⌘L", "Show the selected favorite in its folder"),
        ]),
        ("2nd View and Combining", [
            ("Tab", "Switch between the 1st and 2nd view"),
            ("⌃↓  ⌃↑", "Next / previous image in the 2nd view"),
            ("⌥⌘C", "Show or hide the combining controls"),
            ("⌘S", "Save the combination"),
            ("⌥⌘K", "Saved combinations"),
        ]),
    ]

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 300)
        super.init(window: panel)
        panel.contentView = makeContent()
        panel.center()
        panel.setFrameAutosaveName("FastViewKeyboardShortcuts")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeContent() -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing

        for (index, section) in Self.sections.enumerated() {
            let title = NSTextField(labelWithString: section.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let titleRow = grid.addRow(with: [NSGridCell.emptyContentView, title])
            titleRow.topPadding = index == 0 ? 0 : 14
            titleRow.bottomPadding = 2
            for shortcut in section.shortcuts {
                let keys = NSTextField(labelWithString: shortcut.keys)
                keys.font = .systemFont(ofSize: 12, weight: .medium)
                keys.textColor = .secondaryLabelColor
                let action = NSTextField(wrappingLabelWithString: shortcut.action)
                action.font = .systemFont(ofSize: 12)
                action.isSelectable = false
                grid.addRow(with: [keys, action])
            }
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
        ])
        return scrollView
    }

    func showWindowInFront() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Keeps scrolled content starting from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
