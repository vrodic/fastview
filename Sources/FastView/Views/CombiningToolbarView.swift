import AppKit

public protocol CombiningToolbarDelegate: AnyObject {
    func combiningToolbar(_ toolbar: CombiningToolbarView, didSelectMode mode: CanvasCombiningMode)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeLeft percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateMergeRight percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateAlphaGradient percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset1 percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didUpdateFGOffset2 percent: CGFloat)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateRight pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerRotateLeft pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipHorizontal pane: Int)
    func combiningToolbar(_ toolbar: CombiningToolbarView, didTriggerFlipVertical pane: Int)
    func combiningToolbarDidToggleCollapse(_ toolbar: CombiningToolbarView)
}

public class CombiningToolbarView: NSView {
    public weak var delegate: CombiningToolbarDelegate?

    public var isCollapsed: Bool = false {
        didSet {
            controlsStack.isHidden = isCollapsed
            collapseButton.title = isCollapsed ? "▲ Controls" : "▼ Hide Sliders"
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
    private let mergeLabel1 = NSTextField(labelWithString: "Left: 50%")
    private let mergeLabel2 = NSTextField(labelWithString: "Right: 50%")
    private let alphaLabel = NSTextField(labelWithString: "Alpha Blend: 20%")

    // FG sliders
    private let fgGroup = NSStackView()
    private let fgSlider1 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fgSlider2 = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let fgLabel1 = NSTextField(labelWithString: "FG 1 Pos: 50%")
    private let fgLabel2 = NSTextField(labelWithString: "FG 2 Pos: 50%")

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
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor(white: 0.4, alpha: 0.8).cgColor

        // Header Stack
        headerStack.orientation = .horizontal
        headerStack.spacing = 12
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
        btn.contentTintColor = NSColor.white
        btn.font = NSFont.boldSystemFont(ofSize: 11)
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.8).cgColor
        btn.layer?.cornerRadius = 4
    }

    private func setupMergeControls() {
        mergeGroup.orientation = .horizontal
        mergeGroup.spacing = 16
        mergeGroup.alignment = .centerY

        mergeSlider1.target = self
        mergeSlider1.action = #selector(mergeSlider1Changed(_:))
        mergeSlider2.target = self
        mergeSlider2.action = #selector(mergeSlider2Changed(_:))
        alphaSlider.target = self
        alphaSlider.action = #selector(alphaSliderChanged(_:))

        for tf in [mergeLabel1, mergeLabel2, alphaLabel] {
            tf.font = NSFont.boldSystemFont(ofSize: 11)
            tf.textColor = NSColor.white
        }

        let s1Stack = NSStackView(views: [mergeLabel1, mergeSlider1])
        let s2Stack = NSStackView(views: [mergeLabel2, mergeSlider2])
        let aStack = NSStackView(views: [alphaLabel, alphaSlider])

        for st in [s1Stack, s2Stack, aStack] {
            st.orientation = .horizontal
            st.spacing = 6
            st.alignment = .centerY
        }

        mergeGroup.addArrangedSubview(s1Stack)
        mergeGroup.addArrangedSubview(s2Stack)
        mergeGroup.addArrangedSubview(aStack)
    }

    private func setupFGControls() {
        fgGroup.orientation = .horizontal
        fgGroup.spacing = 16
        fgGroup.alignment = .centerY

        fgSlider1.target = self
        fgSlider1.action = #selector(fgSlider1Changed(_:))
        fgSlider2.target = self
        fgSlider2.action = #selector(fgSlider2Changed(_:))

        for tf in [fgLabel1, fgLabel2] {
            tf.font = NSFont.boldSystemFont(ofSize: 11)
            tf.textColor = NSColor.white
        }

        let f1Stack = NSStackView(views: [fgLabel1, fgSlider1])
        let f2Stack = NSStackView(views: [fgLabel2, fgSlider2])

        for st in [f1Stack, f2Stack] {
            st.orientation = .horizontal
            st.spacing = 6
            st.alignment = .centerY
        }

        fgGroup.addArrangedSubview(f1Stack)
        fgGroup.addArrangedSubview(f2Stack)
    }

    private func setupOrientationControls() {
        orientationGroup.orientation = .horizontal
        orientationGroup.spacing = 16
        orientationGroup.alignment = .centerY

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

        let p1Stack = NSStackView(views: [p1Label, rotL1, rotR1, flipH1, flipV1])
        p1Stack.orientation = .horizontal
        p1Stack.spacing = 4

        let p2Label = NSTextField(labelWithString: "Image 2:")
        p2Label.font = NSFont.boldSystemFont(ofSize: 11)
        p2Label.textColor = NSColor.white

        let rotL2 = makeBtn("↺ 90°", tag: 2, action: #selector(rotLAction(_:)))
        let rotR2 = makeBtn("↻ 90°", tag: 2, action: #selector(rotRAction(_:)))
        let flipH2 = makeBtn("⇄ Flip H", tag: 2, action: #selector(flipHAction(_:)))
        let flipV2 = makeBtn("⇅ Flip V", tag: 2, action: #selector(flipVAction(_:)))

        let p2Stack = NSStackView(views: [p2Label, rotL2, rotR2, flipH2, flipV2])
        p2Stack.orientation = .horizontal
        p2Stack.spacing = 4

        orientationGroup.addArrangedSubview(p1Stack)
        orientationGroup.addArrangedSubview(p2Stack)
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
        mergeLabel1.stringValue = String(format: "Left: %.0f%%", val)
        delegate?.combiningToolbar(self, didUpdateMergeLeft: val)
    }

    @objc private func mergeSlider2Changed(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        mergeLabel2.stringValue = String(format: "Right: %.0f%%", val)
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
