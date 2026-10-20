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
            updateImageFrame()
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
        imageView.translatesAutoresizingMaskIntoConstraints = false

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
        updateImageFrame()
    }

    public func zoomIn() {
        scrollView.magnification *= 1.25
    }

    public func zoomOut() {
        scrollView.magnification /= 1.25
    }

    public func resetZoomToFit() {
        zoomMode = .fitToScreen
        scrollView.magnification = 1.0
        updateImageFrame()
    }

    public func setActualSize() {
        zoomMode = .actualSize
        scrollView.magnification = 1.0
        updateImageFrame()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateImageFrame()
    }

    private func updateImageFrame() {
        guard let img = currentImage else {
            imageView.frame = .zero
            return
        }

        let containerSize = bounds.size
        guard containerSize.width > 0 && containerSize.height > 0 else { return }

        switch zoomMode {
        case .fitToScreen:
            let imageAspect = img.size.width / img.size.height
            let containerAspect = containerSize.width / containerSize.height

            var targetWidth: CGFloat
            var targetHeight: CGFloat

            if imageAspect > containerAspect {
                targetWidth = containerSize.width
                targetHeight = targetWidth / imageAspect
            } else {
                targetHeight = containerSize.height
                targetWidth = targetHeight * imageAspect
            }

            let originX = max(0, (containerSize.width - targetWidth) / 2)
            let originY = max(0, (containerSize.height - targetHeight) / 2)
            imageView.frame = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)

        case .actualSize:
            let originX = max(0, (containerSize.width - img.size.width) / 2)
            let originY = max(0, (containerSize.height - img.size.height) / 2)
            imageView.frame = NSRect(x: originX, y: originY, width: img.size.width, height: img.size.height)

        case .custom(let scale):
            let scaledWidth = img.size.width * scale
            let scaledHeight = img.size.height * scale
            let originX = max(0, (containerSize.width - scaledWidth) / 2)
            let originY = max(0, (containerSize.height - scaledHeight) / 2)
            imageView.frame = NSRect(x: originX, y: originY, width: scaledWidth, height: scaledHeight)
        }
    }
}
