import AppKit
import QuartzCore

public enum ImageZoomMode {
    case fitToScreen
    case actualSize
    case custom(CGFloat)
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
            needsDisplay = true
        }
    }

    private var selectionPath: [CGPoint] = []
    private var isDrawingSelection: Bool = false
    public var onRegionSelectedForDetection: ((NSImage) -> Void)?

    private let imageView = NSImageView()
    private let scrollView = NSScrollView()

    private let loadingContainerView = NSView()
    private let loadingIndicator = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private let speedLabel = NSTextField(labelWithString: "")

    private var progressTimer: Timer?
    private var estimatedDuration: Double = 0
    private var elapsedProgressTime: Double = 0

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

        let clipView = scrollView.contentView
        clipView.documentView = imageView

        addSubview(scrollView)
        addSubview(loadingContainerView)

        loadingContainerView.addSubview(loadingIndicator)
        loadingContainerView.addSubview(progressBar)
        loadingContainerView.addSubview(speedLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    public func showLoading(fileSizeBytes: UInt64, pastSpeedMBs: Double, statusText: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.progressTimer?.invalidate()
            self.elapsedProgressTime = 0

            let sizeBytes = max(100 * 1024, fileSizeBytes)
            let speed = max(0.5, pastSpeedMBs)
            let sizeMB = Double(sizeBytes) / (1024.0 * 1024.0)
            self.estimatedDuration = max(0.5, sizeMB / speed)

            self.loadingContainerView.isHidden = false

            self.loadingIndicator.isHidden = false
            self.loadingIndicator.startAnimation(nil)

            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = 0
            self.progressBar.isHidden = false
            self.progressBar.startAnimation(nil)

            let text = statusText ?? String(format: "Loading... (%.1f MB/s)", speed)
            self.speedLabel.stringValue = text
            self.speedLabel.isHidden = false

            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.elapsedProgressTime += 0.05
                let progress = min(95.0, (self.elapsedProgressTime / self.estimatedDuration) * 100.0)
                self.progressBar.doubleValue = progress
            }
        }
    }

    public func hideLoading() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.progressTimer?.invalidate()
            self.progressTimer = nil

            self.loadingContainerView.isHidden = true

            self.loadingIndicator.stopAnimation(nil)
            self.loadingIndicator.isHidden = true

            self.progressBar.stopAnimation(nil)
            self.progressBar.doubleValue = 100
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
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        if isFreehandSelectionMode && isDrawingSelection {
            let pt = convert(event.locationInWindow, from: nil)
            selectionPath.append(pt)
            needsDisplay = true
            return
        }
        super.mouseDragged(with: event)
    }

    override public func mouseUp(with event: NSEvent) {
        if isFreehandSelectionMode && isDrawingSelection {
            isDrawingSelection = false
            isFreehandSelectionMode = false
            processFreehandSelection()
            needsDisplay = true
            return
        }
        super.mouseUp(with: event)
    }

    private func processFreehandSelection() {
        guard let img = currentImage, selectionPath.count > 2 else { return }

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
        guard boundingBox.width > 5 && boundingBox.height > 5 else { return }

        let imgSize = img.size
        guard imgSize.width > 0 && imgSize.height > 0 else { return }

        let viewSize = bounds.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

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
        guard !intersect.isNull && intersect.width > 5 && intersect.height > 5 else { return }

        let normX = (intersect.origin.x - drawRect.origin.x) / drawRect.width
        let normY = (intersect.origin.y - drawRect.origin.y) / drawRect.height
        let normW = intersect.width / drawRect.width
        let normH = intersect.height / drawRect.height

        guard let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pixelW = CGFloat(cgImg.width)
        let pixelH = CGFloat(cgImg.height)

        let cropRect = CGRect(
            x: max(0, normX * pixelW),
            y: max(0, (1.0 - normY - normH) * pixelH),
            width: min(pixelW, normW * pixelW),
            height: min(pixelH, normH * pixelH)
        )

        guard cropRect.width > 2 && cropRect.height > 2,
              let croppedCG = cgImg.cropping(to: cropRect) else { return }

        let croppedImage = NSImage(cgImage: croppedCG, size: NSSize(width: cropRect.width, height: cropRect.height))
        onRegionSelectedForDetection?(croppedImage)
        selectionPath = []
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if (isFreehandSelectionMode || isDrawingSelection) && selectionPath.count > 1 {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()

            let cgPath = CGMutablePath()
            cgPath.move(to: selectionPath[0])
            for pt in selectionPath.dropFirst() {
                cgPath.addLine(to: pt)
            }
            cgPath.closeSubpath()

            context.addPath(cgPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor)
            context.fillPath()

            context.addPath(cgPath)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2.5)
            let dashes: [CGFloat] = [6.0, 3.0]
            context.setLineDash(phase: 0, lengths: dashes)
            context.strokePath()

            context.restoreGState()
        }
    }

    public func setActualSize() {
        zoomMode = .actualSize
        scrollView.magnification = 1.0
        updateLayout()
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
