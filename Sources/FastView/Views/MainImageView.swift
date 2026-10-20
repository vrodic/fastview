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

        let clipView = scrollView.contentView
        clipView.documentView = imageView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    public func setImage(_ image: NSImage?) {
        self.currentImage = image
        imageView.image = image
        scrollView.magnification = 1.0
        updateLayout()
    }

    public func zoomIn() {
        zoomMode = .custom(scrollView.magnification * 1.25)
        scrollView.magnification *= 1.25
        updateLayout()
    }

    public func zoomOut() {
        zoomMode = .custom(scrollView.magnification / 1.25)
        scrollView.magnification /= 1.25
        updateLayout()
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
        case .custom(let scale):
            let scaledWidth = img.size.width * scale
            let scaledHeight = img.size.height * scale
            let width = max(containerSize.width, scaledWidth)
            let height = max(containerSize.height, scaledHeight)
            imageView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }
}
