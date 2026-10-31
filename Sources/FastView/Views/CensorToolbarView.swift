import AppKit

/// Floating toolbar shown over the image while censoring: style, shape, strength,
/// censor faces, undo and done, with a line for short messages.
final class CensorToolbarView: NSVisualEffectView {
    var onSettingsChanged: ((CensorSettings) -> Void)?
    var onFaces: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?

    private(set) var settings: CensorSettings
    private let styleControl = NSSegmentedControl(labels: CensorStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let shapeControl: NSSegmentedControl
    private let strengthSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let undoButton = NSButton()
    private let messageLabel = NSTextField(labelWithString: "")
    private var messageTimer: Timer?

    var canUndo: Bool = false {
        didSet { undoButton.isEnabled = canUndo }
    }

    init(settings: CensorSettings) {
        self.settings = settings
        let shapeImages = CensorShape.allCases.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.rawValue)! }
        shapeControl = NSSegmentedControl(images: shapeImages, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        styleControl.target = self
        styleControl.action = #selector(controlsChanged)
        styleControl.selectedSegment = CensorStyle.allCases.firstIndex(of: settings.style) ?? 0
        for (i, shape) in CensorShape.allCases.enumerated() {
            shapeControl.setToolTip("Draw a \(shape == .freehand ? "freehand outline" : shape.rawValue)", forSegment: i)
        }
        shapeControl.target = self
        shapeControl.action = #selector(controlsChanged)
        shapeControl.selectedSegment = CensorShape.allCases.firstIndex(of: settings.shape) ?? 0
        strengthSlider.target = self
        strengthSlider.action = #selector(controlsChanged)
        strengthSlider.doubleValue = settings.strength
        strengthSlider.toolTip = "Strength: bigger blocks / stronger blur"
        strengthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let faces = NSButton(title: "Faces", image: NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)!, target: self, action: #selector(facesAction))
        faces.imagePosition = .imageLeading
        faces.toolTip = "Censor every face in the image"
        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        undoButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undoAction)
        undoButton.toolTip = "Undo the last censor (⌘Z)"
        undoButton.isEnabled = false
        let done = NSButton(title: "Done", target: self, action: #selector(doneAction))
        done.toolTip = "Stop censoring (Esc)"

        let row = NSStackView(views: [styleControl, shapeControl, strengthSlider, faces, undoButton, done])
        row.spacing = 8
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "Drag over the image to censor an area"
        let column = NSStackView(views: [row, messageLabel])
        column.orientation = .vertical
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        updateStrengthEnabled()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows a short message under the controls for a few seconds.
    func show(message: String) {
        messageLabel.stringValue = message
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.messageLabel.stringValue = "Drag over the image to censor an area"
        }
    }

    private func updateStrengthEnabled() {
        strengthSlider.isEnabled = settings.style == .pixelate || settings.style == .blur
    }

    @objc private func controlsChanged() {
        settings.style = CensorStyle.allCases[max(0, styleControl.selectedSegment)]
        settings.shape = CensorShape.allCases[max(0, shapeControl.selectedSegment)]
        settings.strength = strengthSlider.doubleValue
        updateStrengthEnabled()
        onSettingsChanged?(settings)
    }

    @objc private func facesAction() { onFaces?() }
    @objc private func undoAction() { onUndo?() }
    @objc private func doneAction() { onDone?() }
}
