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
        let copyItem = NSMenuItem(title: "Copy Image to Clipboard", action: #selector(contextCopyImageAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = img
        menu.addItem(copyItem)
        return menu
    }

    @objc private func contextCopyImageAction(_ sender: NSMenuItem) {
        guard let img = sender.representedObject as? NSImage else { return }
        NSPasteboard.general.copyImage(img)
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
