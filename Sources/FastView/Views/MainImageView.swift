import AppKit
import QuartzCore

public enum ImageZoomMode {
    case fitToScreen
    case actualSize
    case custom(CGFloat)
}

public class MainImageView: NSView {
    public private(set) var currentImage: NSImage?
    public var zoomMode: ImageZoomMode = .fitToScreen {
        didSet {
            updateLayout()
        }
    }

    private let imageView = NSImageView()
    private let scrollView = NSScrollView()
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

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .large
        loadingIndicator.isHidden = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        speedLabel.textColor = NSColor.lightGray
        speedLabel.alignment = .center
        speedLabel.isHidden = true

        let clipView = scrollView.contentView
        clipView.documentView = imageView

        addSubview(scrollView)
        addSubview(loadingIndicator)
        addSubview(progressBar)
        addSubview(speedLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),

            progressBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressBar.topAnchor.constraint(equalTo: loadingIndicator.bottomAnchor, constant: 12),
            progressBar.widthAnchor.constraint(equalToConstant: 240),

            speedLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6)
        ])
    }

    public func showLoading(fileSizeBytes: UInt64, pastSpeedMBs: Double) {
        progressTimer?.invalidate()
        elapsedProgressTime = 0

        let speed = max(0.5, pastSpeedMBs)
        let sizeMB = Double(fileSizeBytes) / (1024.0 * 1024.0)
        estimatedDuration = max(0.3, sizeMB / speed)

        // Only show progress UI for operations expected to take > 250ms
        if estimatedDuration < 0.25 {
            return
        }

        loadingIndicator.isHidden = false
        loadingIndicator.startAnimation(nil)

        progressBar.doubleValue = 0
        progressBar.isHidden = false

        speedLabel.stringValue = String(format: "Loading... (%.1f MB/s)", speed)
        speedLabel.isHidden = false

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsedProgressTime += 0.05
            let progress = min(95.0, (self.elapsedProgressTime / self.estimatedDuration) * 100.0)
            self.progressBar.doubleValue = progress
        }
    }

    public func hideLoading() {
        progressTimer?.invalidate()
        progressTimer = nil

        loadingIndicator.stopAnimation(nil)
        loadingIndicator.isHidden = true

        progressBar.doubleValue = 100
        progressBar.isHidden = true

        speedLabel.isHidden = true
    }

    public func setImage(_ image: NSImage?, keepZoom: Bool = true) {
        hideLoading()
        self.currentImage = image
        imageView.image = image

        if !keepZoom {
            scrollView.magnification = 1.0
            zoomMode = .fitToScreen
        }

        updateLayout()
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
            imageView.frame = NSRect(origin: .zero, size: containerSize)
        case .actualSize:
            let originX = max(0, (containerSize.width - img.size.width) / 2)
            let originY = max(0, (containerSize.height - img.size.height) / 2)
            let width = max(containerSize.width, img.size.width)
            let height = max(containerSize.height, img.size.height)
            imageView.frame = NSRect(x: originX, y: originY, width: width, height: height)
        case .custom:
            imageView.frame = NSRect(origin: .zero, size: containerSize)
        }
    }
}
