import AppKit

public enum CanvasCombiningMode: String, CaseIterable {
    case split = "Normal Split"
    case merge = "Merge"
    case foregroundCombine = "Foreground Combine"
}

public class DualCanvasViewController: NSViewController, CombiningToolbarDelegate {
    public let imageView1 = MainImageView()
    public let imageView2 = MainImageView()
    public let combiningCanvasView = CombiningCanvasView()
    public let toolbarView = CombiningToolbarView()
    public let restoreProgressView = RestoreProgressView()
    /// The saved preview of a combination, filling panes and canvas while it restores.
    /// A plain layer-backed view: an image view's intrinsic size would push the split view around.
    private let restorePreviewView = NSView()

    /// Called by the close button over pane 2's corner.
    public var onCloseSecondPane: (() -> Void)?
    private let closeSecondPaneButton = NSButton()

    /// Called whenever a pane is given an image, with the item it shows (nil image when it has none).
    public var onPaneImageSet: ((_ pane: Int, _ hasImage: Bool, _ itemPath: String?) -> Void)?

    public private(set) var isDualView: Bool = false
    public var combiningMode: CanvasCombiningMode = .split {
        didSet {
            guard combiningMode != oldValue else { return }
            combiningCanvasView.combiningMode = combiningMode
            toolbarView.setMode(combiningMode)
            updateCanvasLayout()
        }
    }

    public var isToolbarVisible: Bool = false {
        didSet {
            toolbarView.isHidden = !isToolbarVisible
        }
    }

    public var isForegroundCombineAvailable: Bool {
        return !combiningCanvasView.objects.isEmpty
    }

    private let splitContainer = NSStackView()

    override public func loadView() {
        imageView1.onOrientationChanged = { [weak self] in
            guard let self else { return }
            self.combiningCanvasView.orientation1 = self.imageView1.orientation
        }
        imageView2.onOrientationChanged = { [weak self] in
            guard let self else { return }
            self.combiningCanvasView.orientation2 = self.imageView2.orientation
        }
        self.view = NSView()
        setupUI()
    }

    private func setupUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        toolbarView.delegate = self
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.isHidden = true

        splitContainer.orientation = .horizontal
        splitContainer.spacing = 2
        splitContainer.distribution = .fillEqually
        splitContainer.translatesAutoresizingMaskIntoConstraints = false

        combiningCanvasView.translatesAutoresizingMaskIntoConstraints = false
        combiningCanvasView.isHidden = true

        imageView1.translatesAutoresizingMaskIntoConstraints = false
        imageView2.translatesAutoresizingMaskIntoConstraints = false

        splitContainer.addArrangedSubview(imageView1)

        view.addSubview(splitContainer)
        view.addSubview(combiningCanvasView)
        view.addSubview(toolbarView)

        restorePreviewView.translatesAutoresizingMaskIntoConstraints = false
        restorePreviewView.wantsLayer = true
        restorePreviewView.layer?.contentsGravity = .resizeAspectFill
        restorePreviewView.layer?.masksToBounds = true
        restorePreviewView.isHidden = true
        // Below the toolbar, so its restored values show; above panes and canvas.
        view.addSubview(restorePreviewView, positioned: .below, relativeTo: toolbarView)

        restoreProgressView.translatesAutoresizingMaskIntoConstraints = false
        restoreProgressView.isHidden = true
        view.addSubview(restoreProgressView)

        closeSecondPaneButton.translatesAutoresizingMaskIntoConstraints = false
        closeSecondPaneButton.isBordered = false
        closeSecondPaneButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close 2nd View")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        closeSecondPaneButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        closeSecondPaneButton.toolTip = "Close 2nd View"
        closeSecondPaneButton.refusesFirstResponder = true
        closeSecondPaneButton.target = self
        closeSecondPaneButton.action = #selector(closeSecondPaneClicked(_:))
        closeSecondPaneButton.isHidden = !isDualView
        view.addSubview(closeSecondPaneButton)

        NSLayoutConstraint.activate([
            splitContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitContainer.topAnchor.constraint(equalTo: view.topAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            combiningCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            combiningCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            combiningCanvasView.topAnchor.constraint(equalTo: view.topAnchor),
            combiningCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            restorePreviewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            restorePreviewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            restorePreviewView.topAnchor.constraint(equalTo: view.topAnchor),
            restorePreviewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            restoreProgressView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            restoreProgressView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            toolbarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            // Top right: pane 2's corner when split, the canvas's otherwise.
            closeSecondPaneButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            closeSecondPaneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            closeSecondPaneButton.widthAnchor.constraint(equalToConstant: 22),
            closeSecondPaneButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        combiningCanvasView.onRetuneDetector = { [weak self] index, mode in
            guard let self = self, index < self.combiningCanvasView.objects.count else { return }
            let target = self.combiningCanvasView.objects[index]

            // Swaps in the re-detected object, keeping the target's identity, placement and colours.
            let replace: (ForegroundObject?) -> Void = { [weak self] fgObj in
                guard let self = self, var fg = fgObj else { return }
                let canvas = self.combiningCanvasView
                guard let existing = canvas.objects.first(where: { $0.id == target.id }) else { return }
                fg.id = existing.id
                fg.itemPath = existing.itemPath
                fg.archivePath = existing.archivePath
                fg.sourcePane = existing.sourcePane
                fg.sourceCrop = existing.sourceCrop
                fg.sourceOrientation = existing.sourceOrientation
                fg.position = existing.position
                fg.scale = existing.scale
                fg.rotationDegrees = existing.rotationDegrees
                fg.isFlippedHorizontal = existing.isFlippedHorizontal
                fg.isFlippedVertical = existing.isFlippedVertical
                fg.detectionMode = mode
                ForegroundSource.applyColorAdjustment(existing.colorAdjustment, to: fg) { adjusted in
                    guard let idx = canvas.objects.firstIndex(where: { $0.id == target.id }) else { return }
                    canvas.objects[idx] = adjusted
                }
            }

            if target.sourceCrop == nil, target.sourcePane == 1, let img = self.combiningCanvasView.image1 {
                ForegroundDetector.detectForegroundObject(in: img, mode: mode, completion: replace)
            } else if target.sourceCrop == nil, target.sourcePane == 2, let img = self.combiningCanvasView.image2 {
                ForegroundDetector.detectForegroundObject(in: img, mode: mode, completion: replace)
            } else if let itemPath = target.itemPath {
                ForegroundSource.detect(itemPath: itemPath, archiveCandidates: target.archivePath.map { [$0] } ?? [], crop: target.sourceCrop, orientation: target.sourceOrientation, mode: mode, completion: replace)
            }
        }
    }

    public func showRestorePreview(_ image: NSImage, background: NSColor) {
        restorePreviewView.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        restorePreviewView.layer?.backgroundColor = background.cgColor
        restorePreviewView.alphaValue = 1
        restorePreviewView.isHidden = false
    }

    public func hideRestorePreview() {
        guard !restorePreviewView.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            restorePreviewView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A restore started during the fade shows its own preview again.
            guard let self = self, self.restorePreviewView.alphaValue == 0 else { return }
            self.restorePreviewView.isHidden = true
            self.restorePreviewView.layer?.contents = nil
        })
    }

    @objc private func closeSecondPaneClicked(_ sender: NSButton) {
        onCloseSecondPane?()
    }

    public func toggleToolbar() {
        isToolbarVisible = !isToolbarVisible
    }

    public func setDualViewEnabled(_ enabled: Bool) {
        self.isDualView = enabled
        closeSecondPaneButton.isHidden = !enabled
        if !enabled {
            combiningMode = .split
            isToolbarVisible = false
        } else {
            isToolbarVisible = true
        }
        updateCanvasLayout()
    }

    public func updateCanvasLayout() {
        if isDualView {
            if imageView2.superview == nil {
                splitContainer.addArrangedSubview(imageView2)
            }
            imageView2.isHidden = false

            if combiningMode == .split {
                splitContainer.isHidden = false
                combiningCanvasView.isHidden = true
            } else {
                splitContainer.isHidden = true
                combiningCanvasView.isHidden = false
            }
        } else {
            if combiningMode != .split {
                combiningMode = .split
            }
            splitContainer.isHidden = false
            combiningCanvasView.isHidden = true
            imageView2.isHidden = true
            if imageView2.superview != nil {
                splitContainer.removeArrangedSubview(imageView2)
                imageView2.removeFromSuperview()
            }
        }
    }

    /// Item paths whose next auto-detection is skipped because a restored
    /// combination already supplied that pane's object.
    private var restoredItemPaths: [Int: String] = [:]
    private var detectionGeneration: [Int: Int] = [:]

    /// A restored combination owns the canvas objects: keep the next image
    /// loaded for each pane from replacing its object.
    public func beginRestoringObjects(itemPath1: String?, itemPath2: String?) {
        restoredItemPaths = [:]
        if let p = itemPath1 { restoredItemPaths[1] = p }
        if let p = itemPath2 { restoredItemPaths[2] = p }
        // Drop detections still running for the images shown before the restore.
        detectionGeneration[1, default: 0] += 1
        detectionGeneration[2, default: 0] += 1
    }

    public func setImage(_ image: NSImage?, pane: Int, itemPath: String? = nil, archivePath: String? = nil) {
        if pane == 1 {
            imageView1.setImage(image, keepZoom: true)
            combiningCanvasView.image1 = image
        } else {
            imageView2.setImage(image, keepZoom: true)
            combiningCanvasView.image2 = image
        }
        onPaneImageSet?(pane, image != nil, itemPath)

        let canvas = combiningCanvasView
        if let restoredPath = restoredItemPaths[pane] {
            // Loading clears the pane first; that must not drop the restored object.
            guard image != nil else { return }
            restoredItemPaths[pane] = nil
            if restoredPath == itemPath { return }
        }
        // The same item shown again keeps its object, along with any detector tuning.
        if image != nil, let path = itemPath, canvas.foregroundObject(forPane: pane)?.itemPath == path {
            return
        }

        detectionGeneration[pane, default: 0] += 1
        let generation = detectionGeneration[pane]

        guard let img = image else {
            canvas.setForegroundObject(nil, forPane: pane)
            return
        }

        ForegroundDetector.detectForegroundObject(in: img) { [weak self] fgObj in
            guard let self = self, var fg = fgObj,
                  self.detectionGeneration[pane] == generation else { return }
            fg.itemPath = itemPath
            fg.archivePath = archivePath
            if let existing = canvas.foregroundObject(forPane: pane) {
                fg.position = existing.position
                fg.scale = existing.scale
                fg.rotationDegrees = existing.rotationDegrees
                fg.isFlippedHorizontal = existing.isFlippedHorizontal
                fg.isFlippedVertical = existing.isFlippedVertical
            }
            canvas.setForegroundObject(fg, forPane: pane)
        }
    }

    public func rotateRight(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.rotateRight()
        } else {
            imageView1.rotateRight()
        }
    }

    public func rotateLeft(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.rotateLeft()
        } else {
            imageView1.rotateLeft()
        }
    }

    public func flipHorizontal(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.flipHorizontal()
        } else {
            imageView1.flipHorizontal()
        }
    }

    public func flipVertical(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.flipVertical()
        } else {
            imageView1.flipVertical()
        }
    }

    public func resetOrientation(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.resetOrientation()
        } else {
            imageView1.resetOrientation()
        }
    }

    // MARK: - CombiningToolbarDelegate
    public func combiningToolbar(_ toolbar: CombiningToolbarView, didSelectMode mode: CanvasCombiningMode) {
        if mode == .foregroundCombine && !isForegroundCombineAvailable {
            let alert = NSAlert()
            alert.messageText = "No Foreground Objects Detected"
            alert.informativeText = "Neither image contains a detected foreground object for combining."
            alert.alertStyle = .informational
            alert.runModal()
            toolbar.setMode(.split)
            self.combiningMode = .split
            return
        }
        self.combiningMode = mode
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeLeft percent: CGFloat) {
        combiningCanvasView.mergeLeftPercent = percent
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeRight percent: CGFloat) {
        combiningCanvasView.mergeRightPercent = percent
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateAlphaGradient percent: CGFloat) {
        combiningCanvasView.alphaGradientPercent = percent
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset1 percent: CGFloat) {
        combiningCanvasView.fgOffset1Percent = percent
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset2 percent: CGFloat) {
        combiningCanvasView.fgOffset2Percent = percent
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didToggleBackground1 visible: Bool) {
        combiningCanvasView.showBackground1 = visible
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didToggleBackground2 visible: Bool) {
        combiningCanvasView.showBackground2 = visible
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didSelectBackgroundColor color: NSColor) {
        combiningCanvasView.canvasBackgroundColor = color
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateRight pane: Int) {
        rotateRight(pane: pane)
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateLeft pane: Int) {
        rotateLeft(pane: pane)
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipHorizontal pane: Int) {
        flipHorizontal(pane: pane)
    }

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipVertical pane: Int) {
        flipVertical(pane: pane)
    }

    public func combiningToolbarDidToggleCollapse(_ toolbar: CombiningToolbarView) {
        view.needsLayout = true
    }
}
