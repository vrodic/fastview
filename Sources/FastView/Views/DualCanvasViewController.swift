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
        return combiningCanvasView.foregroundObject1 != nil || combiningCanvasView.foregroundObject2 != nil
    }

    private let splitContainer = NSStackView()

    override public func loadView() {
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

        NSLayoutConstraint.activate([
            splitContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitContainer.topAnchor.constraint(equalTo: view.topAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            combiningCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            combiningCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            combiningCanvasView.topAnchor.constraint(equalTo: view.topAnchor),
            combiningCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    public func toggleToolbar() {
        isToolbarVisible = !isToolbarVisible
    }

    public func setDualViewEnabled(_ enabled: Bool) {
        self.isDualView = enabled
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

    public func setImage(_ image: NSImage?, pane: Int) {
        if pane == 1 {
            imageView1.setImage(image, keepZoom: true)
            combiningCanvasView.image1 = image

            if let img = image {
                ForegroundDetector.detectForegroundObject(in: img) { [weak self] fgObj in
                    self?.combiningCanvasView.foregroundObject1 = fgObj
                    self?.combiningCanvasView.updateFGPositionsFromSliders()
                }
            } else {
                combiningCanvasView.foregroundObject1 = nil
            }
        } else {
            imageView2.setImage(image, keepZoom: true)
            combiningCanvasView.image2 = image

            if let img = image {
                ForegroundDetector.detectForegroundObject(in: img) { [weak self] fgObj in
                    self?.combiningCanvasView.foregroundObject2 = fgObj
                    self?.combiningCanvasView.updateFGPositionsFromSliders()
                }
            } else {
                combiningCanvasView.foregroundObject2 = nil
            }
        }
    }

    public func rotateRight(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.rotateRight()
            combiningCanvasView.orientation2 = imageView2.orientation
        } else {
            imageView1.rotateRight()
            combiningCanvasView.orientation1 = imageView1.orientation
        }
    }

    public func rotateLeft(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.rotateLeft()
            combiningCanvasView.orientation2 = imageView2.orientation
        } else {
            imageView1.rotateLeft()
            combiningCanvasView.orientation1 = imageView1.orientation
        }
    }

    public func flipHorizontal(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.flipHorizontal()
            combiningCanvasView.orientation2 = imageView2.orientation
        } else {
            imageView1.flipHorizontal()
            combiningCanvasView.orientation1 = imageView1.orientation
        }
    }

    public func flipVertical(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.flipVertical()
            combiningCanvasView.orientation2 = imageView2.orientation
        } else {
            imageView1.flipVertical()
            combiningCanvasView.orientation1 = imageView1.orientation
        }
    }

    public func resetOrientation(pane: Int) {
        if pane == 2 && isDualView {
            imageView2.resetOrientation()
            combiningCanvasView.orientation2 = imageView2.orientation
        } else {
            imageView1.resetOrientation()
            combiningCanvasView.orientation1 = imageView1.orientation
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

    public func combiningToolbar(_ toolbar: CombiningToolbarView, didToggleFG1OnTop fg1OnTop: Bool) {
        combiningCanvasView.fg1OnTop = fg1OnTop
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
