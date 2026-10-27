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

private class ZoomingScrollView: NSScrollView {
    weak var ownerImageView: MainImageView?

    override func scrollWheel(with event: NSEvent) {
        if let owner = ownerImageView, owner.currentImage != nil {
            owner.handleScrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

public class MainImageView: NSView {
    public private(set) var currentImage: NSImage?
    public private(set) var rawImage: NSImage?
    public var orientation = ImageOrientation() {
        didSet {
            updateTransformedImage(keepZoom: true)
        }
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
    /// The cropped image, the crop as fractions of the oriented image (top-left origin), and the orientation.
    public var onRegionSelectedForDetection: ((NSImage, CGRect, ImageOrientation) -> Void)?

    private var isDraggingImage: Bool = false
    private var lastDragLocation: NSPoint = .zero

    private let imageView = NSImageView()
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

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

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
        selectionOverlayView.isDrawing = (isFreehandSelectionMode || isDrawingSelection) && selectionPath.count > 1
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
        self.rawImage = image
        updateTransformedImage(keepZoom: keepZoom)
    }

    private func updateTransformedImage(keepZoom: Bool = true) {
        guard let raw = rawImage else {
            self.currentImage = nil
            imageView.image = nil
            updateLayout()
            return
        }

        let transformed = raw.transformed(with: orientation)
        self.currentImage = transformed
        imageView.image = transformed

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
        guard currentImage != nil, bounds.width > 0 && bounds.height > 0 else { return }

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
        guard let img = currentImage else { return super.menu(for: event) }
        let menu = NSMenu(title: "Main Image Menu")

        let drawSelectionItem = NSMenuItem(title: "Draw Selection for Foreground Detection", action: #selector(contextDrawSelectionAction(_:)), keyEquivalent: "")
        drawSelectionItem.target = self
        menu.addItem(drawSelectionItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy Image to Clipboard", action: #selector(contextCopyImageAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = img
        menu.addItem(copyItem)

        return menu
    }

    @objc private func contextDrawSelectionAction(_ sender: NSMenuItem) {
        isFreehandSelectionMode = true
        selectionPath = []
        updateOverlay()
    }

    @objc private func contextCopyImageAction(_ sender: NSMenuItem) {
        guard let img = sender.representedObject as? NSImage else { return }
        NSPasteboard.general.copyImage(img)
    }

    override public func mouseDown(with event: NSEvent) {
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
        if !isFreehandSelectionMode && scrollView.magnification > 1.001 {
            let cursor: NSCursor = isDraggingImage ? .closedHand : .openHand
            addCursorRect(bounds, cursor: cursor)
        }
    }

    private func processFreehandSelection() {
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
        guard let img = currentImage, bounds.width > 0, bounds.height > 0 else {
            zoomMode = .actualSize
            scrollView.magnification = 1.0
            updateLayout()
            return
        }

        let imgSize = img.size
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
        guard let img = currentImage else {
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
            let originX = max(0, (containerSize.width - img.size.width) / 2)
            let originY = max(0, (containerSize.height - img.size.height) / 2)
            let width = max(containerSize.width, img.size.width)
            let height = max(containerSize.height, img.size.height)
            imageView.frame = NSRect(x: originX, y: originY, width: width, height: height)
        case .custom:
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            imageView.frame = NSRect(origin: .zero, size: containerSize)
        }
    }
}
