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

    public func updateDirectoryStats(imageCount: Int, totalSizeBytes: UInt64, locationName: String? = nil) {
        if let name = locationName, !name.isEmpty {
            leftLabel.stringValue = name
        } else if totalSizeBytes > 0 {
            let sizeString = ByteCountFormatter.string(fromByteCount: Int64(totalSizeBytes), countStyle: .file)
            leftLabel.stringValue = "\(imageCount) items • Total \(sizeString)"
        } else {
            leftLabel.stringValue = "\(imageCount) items"
        }
    }

    public static func formatLeftPath(for item: FileItem) -> String {
        if item.type == .parentDirectory {
            return item.name
        }

        var components: [String] = []

        if let archivePath = item.archivePath, !archivePath.isEmpty {
            let archiveURL = URL(fileURLWithPath: archivePath)
            let folderName = archiveURL.deletingLastPathComponent().lastPathComponent
            let archiveName = archiveURL.lastPathComponent

            if !folderName.isEmpty {
                components.append(folderName)
            }
            components.append(archiveName)

            if let sub = item.entryParentDir, !sub.isEmpty, sub != "." && sub != "/" {
                let cleanSub = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !cleanSub.isEmpty {
                    components.append(cleanSub)
                }
            }
            components.append(item.name)
        } else {
            let fileURL = URL(fileURLWithPath: item.path)
            let folderName = fileURL.deletingLastPathComponent().lastPathComponent
            if !folderName.isEmpty {
                components.append(folderName)
            }
            components.append(item.name)
        }

        return components.joined(separator: " / ")
    }

    public func updateSelectedItemStats(item: FileItem, containedImagesCount: Int? = nil, parentName: String? = nil) {
        leftLabel.stringValue = StatusBarView.formatLeftPath(for: item)

        var parts: [String] = []

        if let count = containedImagesCount {
            parts.append("\(count) images")
        }

        var sizeBytes = item.fileSize
        if sizeBytes == 0 {
            let path = item.archivePath ?? item.path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                sizeBytes = size
            }
        }

        if sizeBytes > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
            parts.append(sizeStr)
        }

        rightLabel.stringValue = parts.joined(separator: "  |  ")
    }

    public func updateImageInfo(item: FileItem, image: NSImage?, currentIndex: Int? = nil, totalImages: Int? = nil, parentName: String? = nil) {
        leftLabel.stringValue = StatusBarView.formatLeftPath(for: item)

        var infoParts: [String] = []

        if let index = currentIndex, let total = totalImages, total > 0 {
            infoParts.append("\(index) / \(total)")
        }

        var sizeBytes = item.fileSize
        if sizeBytes == 0 {
            let path = item.archivePath ?? item.path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                sizeBytes = size
            }
        }

        if sizeBytes > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
            infoParts.append(sizeStr)
        }

        if let img = image {
            let width = Int(img.size.width)
            let height = Int(img.size.height)
            infoParts.append("\(width) × \(height) px")
        }

        rightLabel.stringValue = infoParts.joined(separator: "  |  ")
    }

    public func updateForegroundObjectInfo(pane: Int, object: ForegroundObject) {
        let w = Int(object.image.size.width * object.scale)
        let h = Int(object.image.size.height * object.scale)
        let x = Int(object.position.x)
        let y = Int(object.position.y)
        let rot = Int(object.rotationDegrees)
        let scale = Int(object.scale * 100)

        rightLabel.stringValue = "FG Object \(pane): \(w)×\(h) px  |  Pos: (\(x), \(y))  |  Scale: \(scale)%  |  Rot: \(rot)°"
    }

    public func clearImageInfo() {
        rightLabel.stringValue = ""
    }
}
