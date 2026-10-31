import AppKit
import QuartzCore

public enum ImageZoomMode {
    case fitToScreen
    case actualSize
    case custom(CGFloat)
}

private class SelectionOverlayView: NSView {
    var selectionPath: [CGPoint] = []
    var isDrawing: Bool = false

    override var isFlipped: Bool { return false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isDrawing && selectionPath.count > 1 {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()

            let cgPath = CGMutablePath()
            cgPath.move(to: selectionPath[0])
            for pt in selectionPath.dropFirst() {
                cgPath.addLine(to: pt)
            }
            cgPath.closeSubpath()

            context.addPath(cgPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor)
            context.fillPath()

            context.addPath(cgPath)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(3.0)
            let dashes: [CGFloat] = [6.0, 3.0]
            context.setLineDash(phase: 0, lengths: dashes)
            context.strokePath()

            context.restoreGState()
        }
    }
}

/// Draws the raw image aspect-fit with the orientation applied as a context transform,
/// so rotating or flipping only redraws instead of re-rendering the bitmap.
private class OrientedImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var orientation = ImageOrientation() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { return false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rawSize = image.size
        guard rawSize.width > 0, rawSize.height > 0 else { return }
        let size = orientation.orientedSize(rawSize)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let drawW = rawSize.width * scale
        let drawH = rawSize.height * scale

        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if orientation.isFlippedHorizontal { context.scaleBy(x: -1.0, y: 1.0) }
        if orientation.isFlippedVertical { context.scaleBy(x: 1.0, y: -1.0) }
        context.rotate(by: orientation.rotationDegrees * .pi / 180.0)
        image.draw(in: NSRect(x: -drawW / 2.0, y: -drawH / 2.0, width: drawW, height: drawH), from: .zero, operation: .sourceOver, fraction: 1.0)
        context.restoreGState()
    }
}

/// Cancellation flag for a background object removal, safe to read from any thread.
private final class RemovalTicket {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

private class ZoomingScrollView: NSScrollView {
    weak var ownerImageView: MainImageView?

    override func scrollWheel(with event: NSEvent) {
        if let owner = ownerImageView, owner.rawImage != nil {
            owner.handleScrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

public class MainImageView: NSView {
    /// The oriented image, rendered only when needed (copy, selection); display uses `rawImage` with a transform.
    public var currentImage: NSImage? {
        guard let raw = rawImage else { return nil }
        if let cached = transformedCache { return cached }
        let transformed = raw.transformed(with: orientation)
        transformedCache = transformed
        return transformed
    }
    private var transformedCache: NSImage?
    /// Size of the image as displayed (rotation applied).
    private var displaySize: NSSize? {
        rawImage.map { orientation.orientedSize($0.size) }
    }
    public private(set) var rawImage: NSImage?
    public var orientation = ImageOrientation() {
        didSet {
            updateTransformedImage(keepZoom: true)
            updateOrientationBadge()
            onOrientationChanged?()
        }
    }
    /// Called whenever `orientation` changes (menu, toolbar or context menu).
    public var onOrientationChanged: (() -> Void)?
    private lazy var orientationBadge: NSImageView = {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        let v = NSImageView(image: NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Orientation changed")!.withSymbolConfiguration(config)!)
        v.contentTintColor = .systemYellow
        v.toolTip = "Orientation changed"
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            v.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            v.widthAnchor.constraint(equalToConstant: 32),
            v.heightAnchor.constraint(equalToConstant: 32),
        ])
        return v
    }()

    private func updateOrientationBadge() {
        orientationBadge.isHidden = orientation.isIdentity
    }

    public var zoomMode: ImageZoomMode = .fitToScreen {
        didSet {
            updateLayout()
        }
    }

    public var isFreehandSelectionMode: Bool = false {
        didSet {
            if isFreehandSelectionMode {
                window?.makeFirstResponder(self)
            }
            updateOverlay()
        }
    }

    private var selectionPath: [CGPoint] = []
    private var isDrawingSelection: Bool = false
    /// Whether the next freehand outline outlines an area to remove instead of a region to detect in.
    private var outlineRemovesArea = false
    /// The image as loaded, while `rawImage` shows it with objects removed.
    public private(set) var uneditedImage: NSImage?
    /// The running removal; a new image or removal cancels it.
    private var removalTicket: RemovalTicket?
    /// Called with the new image after an object is removed or the original restored.
    public var onImageEdited: ((NSImage) -> Void)?

    /// Censor mode: drags mark areas to hide, with the floating toolbar showing.
    public private(set) var isCensoring = false
    private var censorSettings = CensorSettings.saved
    private var censorToolbar: CensorToolbarView?
    /// Images before each censor of the current image, for Undo (most recent last).
    private var censorUndo: [NSImage] = []
    private var censorBusy = false
    private var censorDragStart: CGPoint = .zero
    private static let censorUndoLimit = 10
    /// The cropped image, the crop as fractions of the oriented image (top-left origin), and the orientation.
    public var onRegionSelectedForDetection: ((NSImage, CGRect, ImageOrientation) -> Void)?

    private var isDraggingImage: Bool = false
    private var lastDragLocation: NSPoint = .zero

    private let imageView = OrientedImageView()
    private let scrollView = ZoomingScrollView()
    private let selectionOverlayView = SelectionOverlayView()

    private let loadingContainerView = NSView()
    private let loadingIndicator = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private let speedLabel = NSTextField(labelWithString: "")

    // The overlay is armed by `beginLoading` but only revealed once real
    // progress shows the operation is slow, so cached or quick operations
    // never flash it.
    private let overlayRevealDelay: CFAbsoluteTime = 0.3
    private var pendingLoad: (statusText: String, startTime: CFAbsoluteTime)?
    private var progressSampleStart: (time: CFAbsoluteTime, completed: Int64, total: Int64)?
    private var lastProgressFraction: Double?
    private var revealTimer: Timer?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        scrollView.ownerImageView = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0


        selectionOverlayView.translatesAutoresizingMaskIntoConstraints = false

        loadingContainerView.translatesAutoresizingMaskIntoConstraints = false
        loadingContainerView.wantsLayer = true
        loadingContainerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        loadingContainerView.layer?.cornerRadius = 14
        loadingContainerView.layer?.borderWidth = 1
        loadingContainerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        loadingContainerView.isHidden = true

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .large

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0

        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        speedLabel.textColor = NSColor.white
        speedLabel.alignment = .center
        speedLabel.lineBreakMode = .byTruncatingMiddle

        let clipView = scrollView.contentView
        clipView.documentView = imageView

        addSubview(scrollView)
        addSubview(selectionOverlayView)
        addSubview(loadingContainerView)

        loadingContainerView.addSubview(loadingIndicator)
        loadingContainerView.addSubview(progressBar)
        loadingContainerView.addSubview(speedLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectionOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionOverlayView.topAnchor.constraint(equalTo: topAnchor),
            selectionOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingContainerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingContainerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingContainerView.widthAnchor.constraint(equalToConstant: 540),

            loadingIndicator.centerXAnchor.constraint(equalTo: loadingContainerView.centerXAnchor),
            loadingIndicator.topAnchor.constraint(equalTo: loadingContainerView.topAnchor, constant: 20),

            progressBar.leadingAnchor.constraint(equalTo: loadingContainerView.leadingAnchor, constant: 28),
            progressBar.trailingAnchor.constraint(equalTo: loadingContainerView.trailingAnchor, constant: -28),
            progressBar.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 16),

            speedLabel.leadingAnchor.constraint(equalTo: loadingContainerView.leadingAnchor, constant: 20),
            speedLabel.trailingAnchor.constraint(equalTo: loadingContainerView.trailingAnchor, constant: -20),
            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            speedLabel.bottomAnchor.constraint(equalTo: loadingContainerView.bottomAnchor, constant: -20)
        ])
    }

    private func updateOverlay() {
        selectionOverlayView.selectionPath = selectionPath
        selectionOverlayView.isDrawing = (isFreehandSelectionMode || isCensoring || isDrawingSelection) && selectionPath.count > 1
        selectionOverlayView.needsDisplay = true
    }

    /// Arms the loading overlay for a potentially slow operation.  If it is
    /// still running after `overlayRevealDelay`, the overlay appears: with a
    /// percentage once `updateLoadingProgress` reports progress, as an
    /// indeterminate bar until then.  A `beginLoading` while another load is
    /// pending only updates the text, so a chain of steps (finding a sibling
    /// archive, opening it, loading its first image) is timed from the first
    /// step, until `hideLoading`.
    public func beginLoading(statusText: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let pending = self.pendingLoad {
                self.pendingLoad = (statusText, pending.startTime)
                if !self.loadingContainerView.isHidden && self.progressBar.isIndeterminate {
                    self.speedLabel.stringValue = statusText
                }
                return
            }

            self.pendingLoad = (statusText, CFAbsoluteTimeGetCurrent())
            self.progressSampleStart = nil
            self.lastProgressFraction = nil
            self.revealTimer?.invalidate()
            self.revealTimer = Timer.scheduledTimer(withTimeInterval: self.overlayRevealDelay, repeats: false) { [weak self] _ in
                guard let self = self, let pending = self.pendingLoad, self.loadingContainerView.isHidden,
                      (self.lastProgressFraction ?? 0) < 0.9 else { return }
                self.revealOverlay()
                if self.lastProgressFraction == nil {
                    self.progressBar.isIndeterminate = true
                    self.progressBar.startAnimation(nil)
                    self.speedLabel.stringValue = pending.statusText
                }
            }
        }
    }

    private func revealOverlay() {
        loadingContainerView.isHidden = false
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)
        progressBar.isHidden = false
        speedLabel.isHidden = false
    }

    /// Applies real progress reported by the I/O layer.  Must be called on the
    /// main queue after `beginLoading`.  The overlay appears only when the
    /// operation is still running after `overlayRevealDelay` and is not
    /// nearly done; updates arriving after `hideLoading` are ignored.
    public func updateLoadingProgress(_ progress: LoadProgress) {
        guard let pending = pendingLoad else { return }

        let now = CFAbsoluteTimeGetCurrent()
        // A new phase (another total) restarts the throughput measurement.
        if progressSampleStart == nil || progressSampleStart?.total != progress.total {
            progressSampleStart = (now, progress.completed, progress.total)
        }
        lastProgressFraction = progress.fraction

        if loadingContainerView.isHidden {
            guard now - pending.startTime >= overlayRevealDelay, progress.fraction < 0.9 else { return }
            revealOverlay()
        }
        if progressBar.isIndeterminate {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
        }

        progressBar.doubleValue = progress.fraction * 100.0

        var parts = [String(format: "%@  %.0f%%", pending.statusText, progress.fraction * 100.0)]
        switch progress.unit {
        case .bytes:
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append("\(formatter.string(fromByteCount: progress.completed)) of \(formatter.string(fromByteCount: progress.total))")
        case .entries:
            parts.append("\(progress.completed.formatted()) of \(progress.total.formatted()) entries")
        }

        // Throughput and ETA come from what this operation has actually done
        // so far, measured from its first progress sample.
        if let start = progressSampleStart {
            let elapsed = now - start.time
            let done = Double(progress.completed - start.completed)
            if elapsed >= 0.25 && done > 0 {
                let rate = done / elapsed
                if progress.unit == .bytes {
                    parts.append(String(format: "%.1f MB/s", rate / (1024.0 * 1024.0)))
                }
                let remaining = Double(progress.total - progress.completed) / rate
                if elapsed >= 1.0 && remaining >= 1.0 {
                    parts.append(String(format: "~%.0fs left", remaining.rounded(.up)))
                }
            }
        }

        speedLabel.stringValue = parts.joined(separator: " · ")
    }

    public func hideLoading() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.revealTimer?.invalidate()
            self.revealTimer = nil
            self.pendingLoad = nil
            self.progressSampleStart = nil
            self.lastProgressFraction = nil

            self.loadingContainerView.isHidden = true

            self.loadingIndicator.stopAnimation(nil)
            self.loadingIndicator.isHidden = true

            self.progressBar.stopAnimation(nil)
            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = 0
            self.progressBar.isHidden = true

            self.speedLabel.isHidden = true
        }
    }

    public func setImage(_ image: NSImage?, keepZoom: Bool = true) {
        hideLoading()
        removalTicket?.cancel()
        uneditedImage = nil
        censorUndo = []
        censorToolbar?.canUndo = false
        self.rawImage = image
        updateTransformedImage(keepZoom: keepZoom)
    }

    private func updateTransformedImage(keepZoom: Bool = true) {
        transformedCache = nil
        imageView.orientation = orientation
        guard let raw = rawImage else {
            imageView.image = nil
            updateLayout()
            return
        }

        if imageView.image !== raw { imageView.image = raw }

        if !keepZoom {
            scrollView.magnification = 1.0
            zoomMode = .fitToScreen
        }

        updateLayout()
    }

    public func rotateRight() {
        orientation.rotateRight()
    }

    public func rotateLeft() {
        orientation.rotateLeft()
    }

    public func flipHorizontal() {
        orientation.toggleFlipHorizontal()
    }

    public func flipVertical() {
        orientation.toggleFlipVertical()
    }

    public func resetOrientation() {
        orientation.reset()
    }

    public func zoomIn() {
        let newMag = min(scrollView.maxMagnification, scrollView.magnification * 1.25)
        scrollView.magnification = newMag
        zoomMode = .custom(newMag)
    }

    public func zoomOut() {
        let newMag = max(scrollView.minMagnification, scrollView.magnification / 1.25)
        scrollView.magnification = newMag
        zoomMode = .custom(newMag)
    }

    public func resetZoomToFit() {
        zoomMode = .fitToScreen
        scrollView.magnification = 1.0
        updateLayout()
    }

    public func handleScrollWheel(with event: NSEvent) {
        guard rawImage != nil, bounds.width > 0 && bounds.height > 0 else { return }

        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(deltaY) > 0.01 else { return }

        let currentMag = scrollView.magnification
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.04
        let targetMag = currentMag * (1.0 + deltaY * factor)

        if targetMag <= 1.001 {
            resetZoomToFit()
        } else {
            let clampedMag = min(scrollView.maxMagnification, max(1.0, targetMag))
            if clampedMag <= 1.001 {
                resetZoomToFit()
            } else {
                zoomMode = .custom(clampedMag)
                scrollView.hasHorizontalScroller = true
                scrollView.hasVerticalScroller = true
                imageView.frame = NSRect(origin: .zero, size: bounds.size)

                let mouseInScrollView = scrollView.convert(event.locationInWindow, from: nil)
                scrollView.setMagnification(clampedMag, centeredAt: mouseInScrollView)
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    override public func menu(for event: NSEvent) -> NSMenu? {
        guard rawImage != nil else { return super.menu(for: event) }
        let menu = NSMenu(title: "Main Image Menu")
        menu.autoenablesItems = false

        let drawSelectionItem = NSMenuItem(title: "Draw Selection for Foreground Detection", action: #selector(contextDrawSelectionAction(_:)), keyEquivalent: "")
        drawSelectionItem.target = self
        menu.addItem(drawSelectionItem)

        menu.addItem(NSMenuItem.separator())
        let censorItem = NSMenuItem(title: isCensoring ? "Stop Censoring" : "Censor Parts of Image…", action: #selector(contextCensorAction(_:)), keyEquivalent: "")
        censorItem.target = self
        menu.addItem(censorItem)

        let removeItem = NSMenuItem(title: "Remove Foreground Object from Background", action: #selector(contextRemoveForegroundAction(_:)), keyEquivalent: "")
        removeItem.target = self
        if #unavailable(macOS 14.0) { removeItem.isEnabled = false }
        menu.addItem(removeItem)
        let removeAreaItem = NSMenuItem(title: "Remove Outlined Area from Background…", action: #selector(contextRemoveOutlinedAction(_:)), keyEquivalent: "")
        removeAreaItem.target = self
        menu.addItem(removeAreaItem)
        if uneditedImage != nil {
            let restoreItem = NSMenuItem(title: "Restore Original Image", action: #selector(contextRestoreOriginalAction(_:)), keyEquivalent: "")
            restoreItem.target = self
            menu.addItem(restoreItem)
        }

        menu.addItem(NSMenuItem.separator())
        let copyItem = NSMenuItem(title: "Copy Image to Clipboard", action: #selector(contextCopyImageAction(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let saveItem = NSMenuItem(title: "Save Image As…", action: #selector(contextSaveImageAction(_:)), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())
        let changed = !orientation.isIdentity
        let entries: [(String, Selector)] = [
            ("Rotate Right 90°", #selector(contextRotateRightAction(_:))),
            ("Rotate Left 90°", #selector(contextRotateLeftAction(_:))),
            ("Flip Horizontal", #selector(contextFlipHAction(_:))),
            ("Flip Vertical", #selector(contextFlipVAction(_:))),
            (changed ? "Reset Orientation (changed)" : "Reset Orientation", #selector(contextResetOrientationAction(_:))),
        ]
        for (title, sel) in entries {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.items.last?.isEnabled = changed
        if orientation.isFlippedHorizontal { menu.items[menu.items.count - 3].state = .on }
        if orientation.isFlippedVertical { menu.items[menu.items.count - 2].state = .on }

        return menu
    }

    @objc private func contextRotateRightAction(_ sender: NSMenuItem) { rotateRight() }
    @objc private func contextRotateLeftAction(_ sender: NSMenuItem) { rotateLeft() }
    @objc private func contextFlipHAction(_ sender: NSMenuItem) { flipHorizontal() }
    @objc private func contextFlipVAction(_ sender: NSMenuItem) { flipVertical() }
    @objc private func contextResetOrientationAction(_ sender: NSMenuItem) { resetOrientation() }

    @objc private func contextRemoveForegroundAction(_ sender: NSMenuItem) {
        removeObject(outline: nil)
    }

    @objc private func contextRemoveOutlinedAction(_ sender: NSMenuItem) {
        outlineRemovesArea = true
        isFreehandSelectionMode = true
        selectionPath = []
        updateOverlay()
    }

    @objc private func contextRestoreOriginalAction(_ sender: NSMenuItem) {
        guard let original = uneditedImage else { return }
        removalTicket?.cancel()
        hideLoading()
        uneditedImage = nil
        censorUndo = []
        censorToolbar?.canUndo = false
        rawImage = original
        updateTransformedImage(keepZoom: true)
        onImageEdited?(original)
    }

    /// Removes the detected foreground (`outline` nil) or the outlined area (fractions of the raw image,
    /// bottom-left origin) and shows the filled image.
    private func removeObject(outline: [CGPoint]?) {
        guard let raw = rawImage else { return }
        removalTicket?.cancel()
        let ticket = RemovalTicket()
        removalTicket = ticket
        let engineName = ObjectRemovalEngine.effective == .aiModel ? "AI model" : "patch fill"
        beginLoading(statusText: "Removing object (\(engineName))…")
        ObjectRemover.remove(from: raw, outline: outline, isCancelled: { ticket.isCancelled }) { [weak self] image, message in
            guard let self = self, self.removalTicket === ticket else { return }
            self.removalTicket = nil
            self.hideLoading()
            guard let image = image else {
                if let message = message { NSSound.beep(); self.showRemovalMessage(message) }
                return
            }
            if self.uneditedImage == nil { self.uneditedImage = raw }
            self.rawImage = image
            self.updateTransformedImage(keepZoom: true)
            self.onImageEdited?(image)
        }
    }

    private func showRemovalMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Remove Object"
        alert.informativeText = message
        if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Maps the outline from view coordinates to fractions of the raw image (bottom-left origin),
    /// undoing the display orientation.
    private func outlineInRawImage(_ path: [CGPoint]) -> [CGPoint]? {
        guard let raw = rawImage, let size = displaySize, size.width > 0, size.height > 0 else { return nil }
        let box = imageView.bounds
        let scale = min(box.width / size.width, box.height / size.height)
        let drawW = size.width * scale, drawH = size.height * scale
        let rect = CGRect(x: box.midX - drawW / 2, y: box.midY - drawH / 2, width: drawW, height: drawH)
        let radians = -orientation.rotationDegrees * .pi / 180.0
        let c = cos(radians), sn = sin(radians)
        return path.map { viewPoint in
            let p = imageView.convert(viewPoint, from: self)
            // Centred, in oriented image units.
            var x = ((p.x - rect.minX) / rect.width - 0.5) * size.width
            var y = ((p.y - rect.minY) / rect.height - 0.5) * size.height
            if orientation.isFlippedHorizontal { x = -x }
            if orientation.isFlippedVertical { y = -y }
            let rx = x * c - y * sn, ry = x * sn + y * c
            return CGPoint(x: rx / raw.size.width + 0.5, y: ry / raw.size.height + 0.5)
        }
    }

    @objc private func contextDrawSelectionAction(_ sender: NSMenuItem) {
        outlineRemovesArea = false
        isFreehandSelectionMode = true
        selectionPath = []
        updateOverlay()
    }

    @objc private func contextCensorAction(_ sender: NSMenuItem) {
        if isCensoring { endCensoring() } else { beginCensoring() }
    }

    // MARK: - Censoring

    public func beginCensoring() {
        guard !isCensoring else { return }
        isFreehandSelectionMode = false
        isCensoring = true
        let toolbar = CensorToolbarView(settings: censorSettings)
        toolbar.canUndo = !censorUndo.isEmpty
        toolbar.onSettingsChanged = { [weak self] settings in
            self?.censorSettings = settings
            CensorSettings.saved = settings
        }
        toolbar.onFaces = { [weak self] in self?.censorFaces() }
        toolbar.onUndo = { [weak self] in self?.undoCensor() }
        toolbar.onDone = { [weak self] in self?.endCensoring() }
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
        censorToolbar = toolbar
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    public func endCensoring() {
        guard isCensoring else { return }
        isCensoring = false
        isDrawingSelection = false
        selectionPath = []
        updateOverlay()
        censorToolbar?.removeFromSuperview()
        censorToolbar = nil
        window?.invalidateCursorRects(for: self)
    }

    /// The censor shape from the drag start to `point`, in view coordinates.
    private func censorShapePath(to point: CGPoint) -> [CGPoint] {
        let rect = CGRect(x: min(censorDragStart.x, point.x), y: min(censorDragStart.y, point.y),
                          width: abs(point.x - censorDragStart.x), height: abs(point.y - censorDragStart.y))
        switch censorSettings.shape {
        case .rectangle: return ImageCensor.rectangle(rect)
        case .ellipse: return ImageCensor.ellipse(in: rect)
        case .freehand: return selectionPath + [point]
        }
    }

    /// Hides the areas (fractions of the raw image, bottom-left origin) in the current style.
    private func applyCensor(_ areas: [[CGPoint]]) {
        guard let raw = rawImage, !areas.isEmpty, !censorBusy else { return }
        censorBusy = true
        let settings = censorSettings
        let o = orientation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ImageCensor.censor(raw, areas: areas, style: settings.style, strength: settings.strength,
                                            textRotation: -o.rotationDegrees, textFlipped: (o.isFlippedHorizontal, o.isFlippedVertical))
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.censorBusy = false
                // Dropped if another image was shown meanwhile.
                guard let result = result, self.rawImage === raw else { return }
                if self.uneditedImage == nil { self.uneditedImage = raw }
                self.censorUndo.append(raw)
                if self.censorUndo.count > Self.censorUndoLimit { self.censorUndo.removeFirst() }
                self.censorToolbar?.canUndo = true
                self.rawImage = result
                self.updateTransformedImage(keepZoom: true)
                self.onImageEdited?(result)
            }
        }
    }

    private func censorFaces() {
        guard let raw = rawImage else { return }
        censorToolbar?.show(message: "Looking for faces…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let faces = ImageCensor.faceAreas(in: raw)
            DispatchQueue.main.async {
                guard let self = self, self.rawImage === raw else { return }
                if faces.isEmpty {
                    self.censorToolbar?.show(message: "No faces found")
                } else {
                    self.censorToolbar?.show(message: faces.count == 1 ? "Censored 1 face" : "Censored \(faces.count) faces")
                    self.applyCensor(faces)
                }
            }
        }
    }

    /// Steps back one censor. Returns false when there is nothing to undo.
    @discardableResult
    public func undoCensor() -> Bool {
        guard !censorBusy, let previous = censorUndo.popLast() else { return false }
        if previous === uneditedImage { uneditedImage = nil }
        censorToolbar?.canUndo = !censorUndo.isEmpty
        rawImage = previous
        updateTransformedImage(keepZoom: true)
        onImageEdited?(previous)
        return true
    }

    @objc private func contextSaveImageAction(_ sender: NSMenuItem) {
        guard let image = currentImage, let window = window,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = uneditedImage != nil ? "Edited Image.png" : "Image.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            DispatchQueue.global(qos: .userInitiated).async {
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let data = rep.representation(using: isJPEG ? .jpeg : .png, properties: isJPEG ? [.compressionFactor: 0.92] : [:]) else { return }
                do {
                    try data.write(to: url)
                } catch {
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
            }
        }
    }

    @objc private func contextCopyImageAction(_ sender: NSMenuItem) {
        guard let img = currentImage else { return }
        NSPasteboard.general.copyImage(img)
    }

    override public func mouseDown(with event: NSEvent) {
        if isCensoring {
            guard !censorBusy, rawImage != nil else { return }
            censorDragStart = convert(event.locationInWindow, from: nil)
            selectionPath = [censorDragStart]
            isDrawingSelection = true
            updateOverlay()
            return
        }
        if isFreehandSelectionMode {
            let pt = convert(event.locationInWindow, from: nil)
            selectionPath = [pt]
            isDrawingSelection = true
            updateOverlay()
            return
        }

        if scrollView.magnification > 1.001 {
            isDraggingImage = true
            lastDragLocation = event.locationInWindow
            NSCursor.closedHand.set()
            return
        }

        super.mouseDown(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        if isCensoring {
            guard isDrawingSelection else { return }
            selectionPath = censorShapePath(to: convert(event.locationInWindow, from: nil))
            updateOverlay()
            return
        }
        if isFreehandSelectionMode && isDrawingSelection {
            let pt = convert(event.locationInWindow, from: nil)
            selectionPath.append(pt)
            updateOverlay()
            return
        }

        if isDraggingImage {
            let currentLocation = event.locationInWindow
            let deltaX = currentLocation.x - lastDragLocation.x
            let deltaY = currentLocation.y - lastDragLocation.y
            lastDragLocation = currentLocation

            let clipView = scrollView.contentView
            var newOrigin = clipView.bounds.origin
            newOrigin.x -= deltaX
            newOrigin.y -= deltaY

            clipView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(clipView)
            NSCursor.closedHand.set()
            return
        }

        super.mouseDragged(with: event)
    }

    override public func mouseUp(with event: NSEvent) {
        if isCensoring {
            guard isDrawingSelection else { return }
            isDrawingSelection = false
            let path = censorShapePath(to: convert(event.locationInWindow, from: nil))
            selectionPath = []
            updateOverlay()
            let box = path.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            guard box.width > 4, box.height > 4, let area = outlineInRawImage(path) else { return }
            applyCensor([area])
            return
        }
        if isFreehandSelectionMode && isDrawingSelection {
            isDrawingSelection = false
            isFreehandSelectionMode = false
            updateOverlay()
            processFreehandSelection()
            return
        }

        if isDraggingImage {
            isDraggingImage = false
            if scrollView.magnification > 1.001 {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }

        super.mouseUp(with: event)
    }

    override public func resetCursorRects() {
        super.resetCursorRects()
        if isCensoring {
            addCursorRect(bounds, cursor: .crosshair)
            if let toolbar = censorToolbar { addCursorRect(toolbar.frame, cursor: .arrow) }
            return
        }
        if !isFreehandSelectionMode && scrollView.magnification > 1.001 {
            let cursor: NSCursor = isDraggingImage ? .closedHand : .openHand
            addCursorRect(bounds, cursor: cursor)
        }
    }

    private func processFreehandSelection() {
        if outlineRemovesArea {
            outlineRemovesArea = false
            let outline = selectionPath.count > 2 ? outlineInRawImage(selectionPath) : nil
            selectionPath = []
            updateOverlay()
            if let outline = outline { removeObject(outline: outline) }
            return
        }
        guard let img = currentImage, selectionPath.count > 2 else {
            selectionPath = []
            updateOverlay()
            return
        }

        var minX = selectionPath[0].x
        var maxX = selectionPath[0].x
        var minY = selectionPath[0].y
        var maxY = selectionPath[0].y

        for pt in selectionPath {
            minX = min(minX, pt.x)
            maxX = max(maxX, pt.x)
            minY = min(minY, pt.y)
            maxY = max(maxY, pt.y)
        }

        let boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard boundingBox.width > 5 && boundingBox.height > 5 else {
            selectionPath = []
            updateOverlay()
            return
        }

        let imgSize = img.size
        guard imgSize.width > 0 && imgSize.height > 0 else {
            selectionPath = []
            updateOverlay()
            return
        }

        let viewSize = bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else {
            selectionPath = []
            updateOverlay()
            return
        }

        let aspect = imgSize.width / imgSize.height
        var drawW = viewSize.width
        var drawH = drawW / aspect
        if drawH > viewSize.height {
            drawH = viewSize.height
            drawW = drawH * aspect
        }
        let drawX = (viewSize.width - drawW) / 2.0
        let drawY = (viewSize.height - drawH) / 2.0
        let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

        let intersect = boundingBox.intersection(drawRect)
        guard !intersect.isNull && intersect.width > 5 && intersect.height > 5 else {
            selectionPath = []
            updateOverlay()
            return
        }

        let normX = (intersect.origin.x - drawRect.origin.x) / drawRect.width
        let normY = (intersect.origin.y - drawRect.origin.y) / drawRect.height
        let normW = intersect.width / drawRect.width
        let normH = intersect.height / drawRect.height

        let normCrop = CGRect(x: normX, y: 1.0 - normY - normH, width: normW, height: normH)
        guard let croppedImage = img.cropped(toNormalized: normCrop) else {
            selectionPath = []
            updateOverlay()
            return
        }
        onRegionSelectedForDetection?(croppedImage, normCrop, orientation)
        selectionPath = []
        updateOverlay()
    }

    public func setActualSize() {
        guard let imgSize = displaySize, bounds.width > 0, bounds.height > 0 else {
            zoomMode = .actualSize
            scrollView.magnification = 1.0
            updateLayout()
            return
        }

        let aspect = imgSize.width / max(1.0, imgSize.height)
        var fitW = bounds.width
        var fitH = fitW / aspect
        if fitH > bounds.height {
            fitH = bounds.height
            fitW = fitH * aspect
        }

        let actualMag = max(1.0, imgSize.width / max(1.0, fitW))
        if actualMag <= 1.001 {
            resetZoomToFit()
        } else {
            zoomMode = .actualSize
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            imageView.frame = NSRect(origin: .zero, size: bounds.size)
            scrollView.setMagnification(actualMag, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
            window?.invalidateCursorRects(for: self)
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayout()
    }

    private func updateLayout() {
        guard let imgSize = displaySize else {
            imageView.frame = .zero
            return
        }

        let containerSize = bounds.size
        guard containerSize.width > 0 && containerSize.height > 0 else { return }

        switch zoomMode {
        case .fitToScreen:
            scrollView.autohidesScrollers = true
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            imageView.frame = NSRect(origin: .zero, size: containerSize)
        case .actualSize:
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            let originX = max(0, (containerSize.width - imgSize.width) / 2)
            let originY = max(0, (containerSize.height - imgSize.height) / 2)
            let width = max(containerSize.width, imgSize.width)
            let height = max(containerSize.height, imgSize.height)
            imageView.frame = NSRect(x: originX, y: originY, width: width, height: height)
        case .custom:
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            imageView.frame = NSRect(origin: .zero, size: containerSize)
        }
    }
}
