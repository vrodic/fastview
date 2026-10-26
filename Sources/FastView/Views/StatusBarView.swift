import AppKit

public class StatusBarView: NSView {
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")

    // File sizes not known up front are looked up off the main thread: a
    // stat() on a network volume can stall behind in-flight archive reads.
    private static let sizeLookupQueue = DispatchQueue(label: "com.fastview.statusbar.sizelookup", qos: .utility)
    private var sizeLookupToken = 0

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

    /// Shows `before` + size + `after` in the right label.  When `sizeBytes`
    /// is 0 and `statPath` is given, the size is filled in once a background
    /// stat() returns, unless the label has been updated again meanwhile.
    private func setRightLabel(before: [String], sizeBytes: UInt64, statPath: String?, after: [String] = []) {
        sizeLookupToken += 1
        let token = sizeLookupToken

        let render: (UInt64) -> Void = { [weak self] size in
            var parts = before
            if size > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            parts.append(contentsOf: after)
            self?.rightLabel.stringValue = parts.joined(separator: "  |  ")
        }
        render(sizeBytes)

        guard sizeBytes == 0, let path = statPath else { return }
        StatusBarView.sizeLookupQueue.async { [weak self] in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
                  size > 0 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.sizeLookupToken == token else { return }
                render(size)
            }
        }
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

        // Entries inside an archive with no recorded size are folders; they
        // have no size of their own (and must never be extracted on the main
        // thread to find out).
        let statPath = item.archivePath == nil ? item.path : nil
        setRightLabel(before: parts, sizeBytes: item.fileSize, statPath: statPath)
    }

    public func updateImageInfo(item: FileItem, image: NSImage?, currentIndex: Int? = nil, totalImages: Int? = nil, parentName: String? = nil) {
        leftLabel.stringValue = StatusBarView.formatLeftPath(for: item)

        var infoParts: [String] = []

        if let index = currentIndex, let total = totalImages, total > 0 {
            infoParts.append("\(index) / \(total)")
        }

        var afterSize: [String] = []
        if let img = image {
            var width = Int(img.size.width)
            var height = Int(img.size.height)
            if let rep = img.representations.first {
                if rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                    width = rep.pixelsWide
                    height = rep.pixelsHigh
                }
            }
            afterSize.append("\(width) × \(height) px")
        }

        setRightLabel(before: infoParts, sizeBytes: item.fileSize, statPath: item.archivePath ?? item.path, after: afterSize)
    }

    public func updateForegroundObjectInfo(pane: Int, object: ForegroundObject) {
        let w = Int(object.image.size.width * object.scale)
        let h = Int(object.image.size.height * object.scale)
        let x = Int(object.position.x)
        let y = Int(object.position.y)
        let rot = Int(object.rotationDegrees)
        let scale = Int(object.scale * 100)

        sizeLookupToken += 1
        rightLabel.stringValue = "FG Object \(pane): \(w)×\(h) px  |  Pos: (\(x), \(y))  |  Scale: \(scale)%  |  Rot: \(rot)°"
    }

    public func clearImageInfo() {
        sizeLookupToken += 1
        rightLabel.stringValue = ""
    }
}
