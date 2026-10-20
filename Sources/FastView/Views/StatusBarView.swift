import AppKit

public class StatusBarView: NSView {
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

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
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        leftLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        leftLabel.textColor = NSColor.secondaryLabelColor
        leftLabel.lineBreakMode = .byTruncatingTail

        rightLabel.translatesAutoresizingMaskIntoConstraints = false
        rightLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        rightLabel.textColor = NSColor.secondaryLabelColor
        rightLabel.alignment = .right
        rightLabel.lineBreakMode = .byTruncatingTail

        addSubview(leftLabel)
        addSubview(rightLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftLabel.trailingAnchor, constant: 8)
        ])
    }

    public func updateDirectoryStats(imageCount: Int, totalSizeBytes: UInt64) {
        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(totalSizeBytes), countStyle: .file)
        leftLabel.stringValue = "\(imageCount) items • Total \(sizeString)"
    }

    public func updateImageInfo(item: FileItem, image: NSImage?) {
        var infoParts: [String] = []

        infoParts.append(item.name)

        if item.fileSize > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)
            infoParts.append(sizeStr)
        }

        if let img = image {
            let width = Int(img.size.width)
            let height = Int(img.size.height)
            infoParts.append("\(width) × \(height) px")
        }

        rightLabel.stringValue = infoParts.joined(separator: "  |  ")
    }

    public func clearImageInfo() {
        rightLabel.stringValue = ""
    }
}
