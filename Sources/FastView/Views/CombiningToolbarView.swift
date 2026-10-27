import AppKit

public protocol CombiningToolbarDelegate: AnyObject {
    func combiningToolbar(_ toolbar: CombiningToolbarView, didSelectMode mode: CanvasCombiningMode)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeLeft percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeRight percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateAlphaGradient percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset1 percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset2 percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didToggleBackground1 visible: Bool)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didToggleBackground2 visible: Bool)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateRight pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateLeft pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipHorizontal pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipVertical pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didSelectBackgroundColor color: NSColor)
    func combiningToolbarDidToggleCollapse(_ toolbar: CombiningToolbarView)
}

public class CombiningToolbarView: NSView {
    public weak var delegate: CombiningToolbarDelegate?

    public var isCollapsed: Bool = false {
        didSet {
            controlsStack.isHidden = isCollapsed
            setButtonTitle(collapseButton, title: isCollapsed ? "▲ Controls" : "▼ Hide Sliders")
            delegate?.combiningToolbarDidToggleCollapse(self)
        }
    }

    private let headerStack = NSStackView()
    private let modeSegmentedControl = NSSegmentedControl(labels: ["Split", "Merge", "FG Combine"], trackingMode: .selectOne, target: nil, action: nil)
    private let collapseButton = NSButton(title: "▼ Hide Sliders", target: nil, action: nil)

    private let controlsStack = NSStackView()

    // Merge sliders
    private let mergeGroup = NSStackView()
    private let mergeSlider1 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let mergeSlider2 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let alphaSlider = NSSlider(value: 20, minValue: 0, maxValue: 50, target: nil, action: nil)
    private let mergeLabel1 = NSTextField(labelWithString: "Left Image: 50%")
    private let mergeLabel2 = NSTextField(labelWithString: "Right Image: 50%")
    private let alphaLabel = NSTextField(labelWithString: "Alpha Blend: 20%")

    // FG sliders & checkboxes
    private let fgGroup = NSStackView()
    private let fgSlider1 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fgSlider2 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fgLabel1 = NSTextField(labelWithString: "FG 1 Pos: 50%")
    private let fgLabel2 = NSTextField(labelWithString: "FG 2 Pos: 50%")
    private let bg1Checkbox = NSButton(checkboxWithTitle: "Show BG 1", target: nil, action: nil)
    private let bg2Checkbox = NSButton(checkboxWithTitle: "Show BG 2", target: nil, action: nil)
    private let bgColorControl = NSSegmentedControl(labels: ["Black Canvas", "White Canvas"], trackingMode: .selectOne, target: nil, action: nil)

    // Orientation Group
    private let orientationGroup = NSStackView()

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.95).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor

        self.appearance = NSAppearance(named: .darkAqua)

        // Header Stack
        headerStack.orientation = .horizontal
        headerStack.spacing = 14
        headerStack.alignment = .centerY

        modeSegmentedControl.segmentStyle = .texturedSquare
        modeSegmentedControl.selectedSegment = 0
        modeSegmentedControl.target = self
        modeSegmentedControl.action = #selector(modeChanged(_:))

        styleButton(collapseButton)
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapseAction)

        let titleLabel = NSTextField(labelWithString: "Combining Controls:")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 12)
        titleLabel.textColor = NSColor.white

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(modeSegmentedControl)
        headerStack.addArrangedSubview(collapseButton)

        // Controls Stack
        controlsStack.orientation = .vertical
        controlsStack.spacing = 10
        controlsStack.alignment = .leading

        setupMergeControls()
        setupFGControls()
        setupOrientationControls()

        controlsStack.addArrangedSubview(mergeGroup)
        controlsStack.addArrangedSubview(fgGroup)
        controlsStack.addArrangedSubview(orientationGroup)

        mergeGroup.isHidden = true
        fgGroup.isHidden = true

        let mainStack = NSStackView(views: [headerStack, controlsStack])
        mainStack.orientation = .vertical
        mainStack.spacing = 12
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func styleButton(_ btn: NSButton) {
        btn.bezelStyle = .inline
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor
        btn.layer?.cornerRadius = 5
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        setButtonTitle(btn, title: btn.title)
    }

    private func setButtonTitle(_ btn: NSButton, title: String) {
        let attrString = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 11)
            ]
        )
        btn.attributedTitle = attrString
    }

    private func setupMergeControls() {
        mergeGroup.orientation = .vertical
        mergeGroup.spacing = 8
        mergeGroup.alignment = .leading

        mergeSlider1.target = self
        mergeSlider1.action = #selector(mergeSlider1Changed(_:))
        mergeSlider2.target = self
        mergeSlider2.action = #selector(mergeSlider2Changed(_:))
        alphaSlider.target = self
        alphaSlider.action = #selector(alphaSliderChanged(_:))

        for s in [mergeSlider1, mergeSlider2, alphaSlider] {
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }

        for tf in [mergeLabel1, mergeLabel2, alphaLabel] {
            tf.font = NSFont.boldSystemFont(ofSize: 11)
            tf.textColor = NSColor.white
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }

        let row1 = NSStackView(views: [mergeLabel1, mergeSlider1, mergeLabel2, mergeSlider2])
        row1.orientation = .horizontal
        row1.spacing = 12
        row1.alignment = .centerY

        let row2 = NSStackView(views: [alphaLabel, alphaSlider])
        row2.orientation = .horizontal
        row2.spacing = 12
        row2.alignment = .centerY

        mergeGroup.addArrangedSubview(row1)
        mergeGroup.addArrangedSubview(row2)
    }

    private func setupFGControls() {
        fgGroup.orientation = .vertical
        fgGroup.spacing = 8
        fgGroup.alignment = .leading

        fgSlider1.target = self
        fgSlider1.action = #selector(fgSlider1Changed(_:))
        fgSlider2.target = self
        fgSlider2.action = #selector(fgSlider2Changed(_:))

        for s in [fgSlider1, fgSlider2] {
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }

        for tf in [fgLabel1, fgLabel2] {
            tf.font = NSFont.boldSystemFont(ofSize: 11)
            tf.textColor = NSColor.white
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }

        for cb in [bg1Checkbox, bg2Checkbox] {
            cb.state = .on
            cb.contentTintColor = NSColor.white
            let attrStr = NSAttributedString(
                string: cb.title,
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 11)]
            )
            cb.attributedTitle = attrStr
        }

        bg1Checkbox.target = self
        bg1Checkbox.action = #selector(bg1Toggled(_:))
        bg2Checkbox.target = self
        bg2Checkbox.action = #selector(bg2Toggled(_:))

        bgColorControl.segmentStyle = .texturedSquare
        bgColorControl.selectedSegment = 0
        bgColorControl.target = self
        bgColorControl.action = #selector(bgColorChanged(_:))

        let slidersRow = NSStackView(views: [fgLabel1, fgSlider1, fgLabel2, fgSlider2])
        slidersRow.orientation = .horizontal
        slidersRow.spacing = 12
        slidersRow.alignment = .centerY

        let bgRow = NSStackView(views: [bg1Checkbox, bg2Checkbox, bgColorControl])
        bgRow.orientation = .horizontal
        bgRow.spacing = 14
        bgRow.alignment = .centerY

        fgGroup.addArrangedSubview(slidersRow)
        fgGroup.addArrangedSubview(bgRow)
    }

    private func setupOrientationControls() {
        orientationGroup.orientation = .vertical
        orientationGroup.spacing = 6
        orientationGroup.alignment = .leading

        func makeBtn(_ title: String, tag: Int, action: Selector) -> NSButton {
            let btn = NSButton(title: title, target: self, action: action)
            styleButton(btn)
            btn.tag = tag
            return btn
        }

        let p1Label = NSTextField(labelWithString: "Image 1:")
        p1Label.font = NSFont.boldSystemFont(ofSize: 11)
        p1Label.textColor = NSColor.white

        let rotL1 = makeBtn("↺ 90°", tag: 1, action: #selector(rotLAction(_:)))
        let rotR1 = makeBtn("↻ 90°", tag: 1, action: #selector(rotRAction(_:)))
        let flipH1 = makeBtn("⇄ Flip H", tag: 1, action: #selector(flipHAction(_:)))
        let flipV1 = makeBtn("⇅ Flip V", tag: 1, action: #selector(flipVAction(_:)))

        let p1Row = NSStackView(views: [p1Label, rotL1, rotR1, flipH1, flipV1])
        p1Row.orientation = .horizontal
        p1Row.spacing = 6
        p1Row.alignment = .centerY

        let p2Label = NSTextField(labelWithString: "Image 2:")
        p2Label.font = NSFont.boldSystemFont(ofSize: 11)
        p2Label.textColor = NSColor.white

        let rotL2 = makeBtn("↺ 90°", tag: 2, action: #selector(rotLAction(_:)))
        let rotR2 = makeBtn("↻ 90°", tag: 2, action: #selector(rotRAction(_:)))
        let flipH2 = makeBtn("⇄ Flip H", tag: 2, action: #selector(flipHAction(_:)))
        let flipV2 = makeBtn("⇅ Flip V", tag: 2, action: #selector(flipVAction(_:)))

        let p2Row = NSStackView(views: [p2Label, rotL2, rotR2, flipH2, flipV2])
        p2Row.orientation = .horizontal
        p2Row.spacing = 6
        p2Row.alignment = .centerY

        orientationGroup.addArrangedSubview(p1Row)
        orientationGroup.addArrangedSubview(p2Row)
    }

    public func setMode(_ mode: CanvasCombiningMode) {
        switch mode {
        case .split:
            modeSegmentedControl.selectedSegment = 0
            mergeGroup.isHidden = true
            fgGroup.isHidden = true
        case .merge:
            modeSegmentedControl.selectedSegment = 1
            mergeGroup.isHidden = false
            fgGroup.isHidden = true
        case .foregroundCombine:
            modeSegmentedControl.selectedSegment = 2
            mergeGroup.isHidden = true
            fgGroup.isHidden = false
        }
    }

    /// Shows the canvas's current values without notifying the delegate.
    public func syncValues(from canvas: CombiningCanvasView) {
        mergeSlider1.doubleValue = Double(canvas.mergeLeftPercent)
        mergeSlider2.doubleValue = Double(canvas.mergeRightPercent)
        alphaSlider.doubleValue = Double(canvas.alphaGradientPercent)
        fgSlider1.doubleValue = Double(canvas.fgOffset1Percent)
        fgSlider2.doubleValue = Double(canvas.fgOffset2Percent)
        mergeLabel1.stringValue = String(format: "Left Image: %.0f%%", canvas.mergeLeftPercent)
        mergeLabel2.stringValue = String(format: "Right Image: %.0f%%", canvas.mergeRightPercent)
        alphaLabel.stringValue = String(format: "Alpha Blend: %.0f%%", canvas.alphaGradientPercent)
        fgLabel1.stringValue = String(format: "FG 1 Pos: %.0f%%", canvas.fgOffset1Percent)
        fgLabel2.stringValue = String(format: "FG 2 Pos: %.0f%%", canvas.fgOffset2Percent)
        bg1Checkbox.state = canvas.showBackground1 ? .on : .off
        bg2Checkbox.state = canvas.showBackground2 ? .on : .off
        bgColorControl.selectedSegment = canvas.canvasBackgroundColor.isLight ? 1 : 0
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let mode: CanvasCombiningMode
        switch sender.selectedSegment {
        case 1: mode = .merge
        case 2: mode = .foregroundCombine
        default: mode = .split
        }
        setMode(mode)
        delegate?.combiningToolbar(self, didSelectMode: mode)
    }

    @objc private func toggleCollapseAction() {
        isCollapsed = !isCollapsed
    }

    @objc private func mergeSlider1Changed(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        mergeLabel1.stringValue = String(format: "Left Image: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateMergeLeft: val)
    }

    @objc private func mergeSlider2Changed(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        mergeLabel2.stringValue = String(format: "Right Image: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateMergeRight: val)
    }

    @objc private func alphaSliderChanged(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        alphaLabel.stringValue = String(format: "Alpha Blend: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateAlphaGradient: val)
    }

    @objc private func fgSlider1Changed(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        fgLabel1.stringValue = String(format: "FG 1 Pos: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateFGOffset1: val)
    }

    @objc private func fgSlider2Changed(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        fgLabel2.stringValue = String(format: "FG 2 Pos: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateFGOffset2: val)
    }

    @objc private func bg1Toggled(_ sender: NSButton) {
        let visible = (sender.state == .on)
        delegate?.combiningToolbar(self, didToggleBackground1: visible)
    }

    @objc private func bg2Toggled(_ sender: NSButton) {
        let visible = (sender.state == .on)
        delegate?.combiningToolbar(self, didToggleBackground2: visible)
    }

    @objc private func bgColorChanged(_ sender: NSSegmentedControl) {
        let color: NSColor = (sender.selectedSegment == 0) ? .black : .white
        delegate?.combiningToolbar(self, didSelectBackgroundColor: color)
    }

    @objc private func rotLAction(_ sender: NSButton) {
        delegate?.combiningToolbar(self, didTriggerRotateLeft: sender.tag)
    }

    @objc private func rotRAction(_ sender: NSButton) {
        delegate?.combiningToolbar(self, didTriggerRotateRight: sender.tag)
    }

    @objc private func flipHAction(_ sender: NSButton) {
        delegate?.combiningToolbar(self, didTriggerFlipHorizontal: sender.tag)
    }

    @objc private func flipVAction(_ sender: NSButton) {
        delegate?.combiningToolbar(self, didTriggerFlipVertical: sender.tag)
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3.0 > 0.5
    }
}
