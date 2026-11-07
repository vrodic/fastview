import AppKit

/// A brief message over a view (zoom level, "Added to Favorites"), which fades by itself.
/// Never takes clicks, and works in full screen where the status bar is hidden.
final class HUDMessageView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    /// Shows `text` over `view`, replacing the message it already shows.
    static func show(_ text: String, in view: NSView, duration: TimeInterval = 1.2) {
        let hud = view.subviews.compactMap { $0 as? HUDMessageView }.first ?? {
            let hud = HUDMessageView()
            view.addSubview(hud)
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                // Below the floating censor toolbar.
                hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
                hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            ])
            return hud
        }()
        view.addSubview(hud, positioned: .above, relativeTo: nil)
        hud.present(text, duration: duration)
    }

    private init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func present(_ text: String, duration: TimeInterval) {
        label.stringValue = text
        hideTimer?.invalidate()
        animator().alphaValue = 1
        alphaValue = 1
        isHidden = false
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                // A message shown during the fade stays.
                if self?.alphaValue == 0 { self?.isHidden = true }
            })
        }
    }
}

/// Says why an image area is empty: nothing to show here, or the file could not be read.
final class ImagePlaceholderView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.4)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.alignment = .center
        titleLabel.isSelectable = false
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        detailLabel.alignment = .center
        detailLabel.isSelectable = false

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: iconView)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(symbol: String, title: String, detail: String?) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .light))
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        isHidden = false
    }
}

/// The window's root view: files dragged from other apps open where they are dropped.
/// Only the drop reads anything from disk, off the main thread.
final class FileDropView: NSView {
    /// The title to show while hovering at a point in this view.
    var dropTitle: ((NSPoint) -> String)?
    var onDrop: ((URL, NSPoint) -> Void)?

    private let highlight = NSView()
    private let highlightLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])

        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.borderWidth = 4
        highlight.isHidden = true
        highlightLabel.translatesAutoresizingMaskIntoConstraints = false
        highlightLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        highlightLabel.textColor = .white
        highlight.addSubview(highlightLabel)
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlightLabel.centerXAnchor.constraint(equalTo: highlight.centerXAnchor),
            highlightLabel.centerYAnchor.constraint(equalTo: highlight.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        // Rows dragged out of FastView's own lists are for other apps.
        guard sender.draggingSource == nil else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    private func updateHighlight(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedURL(sender) != nil else {
            highlight.isHidden = true
            return []
        }
        highlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        highlightLabel.stringValue = dropTitle?(convert(sender.draggingLocation, from: nil)) ?? ""
        // Above tabs added after this view was set up.
        addSubview(highlight, positioned: .above, relativeTo: nil)
        highlight.isHidden = false
        return .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateHighlight(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        onDrop?(url, convert(sender.draggingLocation, from: nil))
        return true
    }
}
