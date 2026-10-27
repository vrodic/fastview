import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The Show Info panel (Cmd+I): a header with the item's thumbnail, name and
/// kind, then sections for the file, its image and camera metadata, folder or
/// archive contents, dates and library state.
///
/// What is known without I/O is shown at once; the rest (file attributes,
/// image properties, archive entry data, folder counts) is read off the main
/// thread and fills the panel in when it arrives.  Showing another item, or
/// closing the panel, stops a read still running.
final class FileInfoWindowController: NSWindowController, NSWindowDelegate {
    private struct Section {
        let title: String
        var rows: [(String, String)]
    }

    private static let loadQueue = DispatchQueue(label: "com.fastview.fileinfo", qos: .userInitiated)
    private static let contentWidth: CGFloat = 420

    private var item: FileItem?
    private var loadToken = 0
    private var cancelFlag = CancelFlag()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let sectionsStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)

    private final class CancelFlag {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false
        )
        window.title = "Info"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window = window else { return }

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8
        iconView.layer?.masksToBounds = true

        nameLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.isSelectable = true
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byCharWrapping
        nameLabel.preferredMaxLayoutWidth = Self.contentWidth - 40 - 80

        kindLabel.font = NSFont.systemFont(ofSize: 12)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let kindRow = NSStackView(views: [kindLabel, spinner])
        kindRow.orientation = .horizontal
        kindRow.spacing = 6

        let titleStack = NSStackView(views: [nameLabel, kindRow])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let header = NSStackView(views: [iconView, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 14

        let copyButton = NSButton(title: "Copy Path", target: self, action: #selector(copyPath(_:)))
        revealButton.target = self
        revealButton.action = #selector(revealInFinder(_:))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        closeButton.keyEquivalent = "\r"
        for button in [copyButton, revealButton, closeButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [copyButton, revealButton, spacer, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [header, makeSeparator(), sectionsStack, makeSeparator(), buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 34, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        for view in [header, sectionsStack, buttons] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        for view in root.arrangedSubviews where view is NSBox {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeSectionView(_ section: Section) -> NSView {
        let title = NSTextField(labelWithString: section.title.uppercased())
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 5
        grid.columnSpacing = 10
        for (label, value) in section.rows {
            let key = NSTextField(labelWithString: label)
            key.font = NSFont.systemFont(ofSize: 12)
            key.textColor = .secondaryLabelColor
            key.alignment = .right

            let field = NSTextField(wrappingLabelWithString: value)
            field.font = NSFont.systemFont(ofSize: 12)
            field.textColor = .labelColor
            field.isSelectable = true
            field.lineBreakMode = value.contains("/") && !value.contains(" ") ? .byCharWrapping : .byWordWrapping
            field.maximumNumberOfLines = 4
            field.preferredMaxLayoutWidth = Self.contentWidth - 40 - 100 - 10
            field.toolTip = value
            grid.addRow(with: [key, field])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.rowAlignment = .firstBaseline

        let stack = NSStackView(views: [title, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func render(_ sections: [Section]) {
        sectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in sections where !section.rows.isEmpty {
            sectionsStack.addArrangedSubview(makeSectionView(section))
        }
        resizeToFit()
    }

    /// Fits the window to its content, keeping its top edge in place.
    private func resizeToFit() {
        guard let window = window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let oldFrame = window.frame
        frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Showing an item

    /// Follows the selection while the panel is open, without taking focus
    /// from the sidebar.
    func refreshIfVisible(item: FileItem) {
        guard let window = window, window.isVisible, item.id != self.item?.id else { return }
        load(item)
    }

    func show(item: FileItem, relativeTo parent: NSWindow?) {
        load(item)
        if let window = window, !window.isVisible {
            if let parent = parent {
                let p = parent.frame
                window.setFrameTopLeftPoint(NSPoint(x: p.maxX - window.frame.width - 24, y: p.maxY - 60))
            } else {
                window.center()
            }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func load(_ item: FileItem) {
        cancelFlag.cancel()
        cancelFlag = CancelFlag()
        loadToken += 1
        let token = loadToken
        let flag = cancelFlag

        self.item = item
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.name
        kindLabel.stringValue = Self.kindDescription(for: item)
        iconView.image = Self.cachedPicture(for: item) ?? Self.icon(for: item)
        revealButton.isEnabled = item.type != .parentDirectory

        render(initialSections(for: item))

        spinner.startAnimation(nil)
        Self.loadQueue.async { [weak self] in
            let loaded = Self.loadDetails(for: item, isCancelled: { flag.isCancelled })
            DispatchQueue.main.async {
                guard let self = self, self.loadToken == token, !flag.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                if let picture = loaded.picture, Self.cachedPicture(for: item) == nil {
                    self.iconView.image = picture
                }
                if let kind = loaded.kind {
                    self.kindLabel.stringValue = kind
                }
                self.render(loaded.sections)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelFlag.cancel()
        spinner.stopAnimation(nil)
    }

    // MARK: - Actions

    private var fullPath: String? {
        guard let item = item else { return nil }
        if let archivePath = item.archivePath {
            return "\(archivePath)/\(item.path)"
        }
        return item.path
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let path = fullPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let item = item else { return }
        let path = item.archivePath ?? item.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func closePanel(_ sender: Any?) {
        window?.performClose(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: - Content known without I/O

    private func initialSections(for item: FileItem) -> [Section] {
        var general = Section(title: "General", rows: [])
        general.rows.append(("Kind", Self.kindDescription(for: item)))
        if item.fileSize > 0 {
            general.rows.append(("Size", Self.sizeDescription(item.fileSize)))
        }
        general.rows.append(contentsOf: Self.locationRows(for: item))
        var sections = [general]
        sections.append(Section(title: "Library", rows: Self.libraryRows(for: item)))
        return sections
    }

    private static func locationRows(for item: FileItem) -> [(String, String)] {
        if let archivePath = item.archivePath {
            var rows = [("Archive", (archivePath as NSString).lastPathComponent),
                        ("Where", (archivePath as NSString).deletingLastPathComponent)]
            let inner = (item.path as NSString).deletingLastPathComponent
            if !inner.isEmpty && inner != "." && inner != "/" {
                rows.append(("In folder", inner))
            }
            return rows
        }
        return [("Where", (item.path as NSString).deletingLastPathComponent)]
    }

    private static func libraryRows(for item: FileItem) -> [(String, String)] {
        guard item.type != .parentDirectory else { return [] }
        var rows: [(String, String)] = []
        let isFavorite = SQLiteCache.shared.isFavorite(path: item.id) || SQLiteCache.shared.isFavorite(path: item.path)
        rows.append(("Favorite", isFavorite ? "★ Yes" : "No"))
        if item.type == .image, SQLiteCache.shared.isTrackingViewedImagesEnabled {
            let viewed = SQLiteCache.shared.isImageViewed(key: SidebarTableCellView.viewedKey(for: item))
            rows.append(("Viewed", viewed ? "Yes" : "No"))
        }
        return rows
    }

    private static func kindDescription(for item: FileItem) -> String {
        switch item.type {
        case .parentDirectory: return "Parent folder"
        case .directory: return item.archivePath != nil ? "Folder in archive" : "Folder"
        case .archiveZip: return "ZIP archive"
        case .archiveRar: return "RAR archive"
        case .unsupported: return "File"
        case .image:
            let ext = (item.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext)
            let name = type?.localizedDescription ?? "\(ext.uppercased()) image"
            return item.archivePath != nil ? "\(name) in archive" : name
        }
    }

    private static func sizeDescription(_ bytes: UInt64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let exact = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
        return "\(short) (\(exact) bytes)"
    }

    private static func cachedPicture(for item: FileItem) -> NSImage? {
        MemoryLRUCache.shared.object(forKey: "thumb_\(item.id)_256.0x256.0")
            ?? MemoryLRUCache.shared.object(forKey: "full_\(item.id)")
    }

    private static func icon(for item: FileItem) -> NSImage {
        let type: UTType
        switch item.type {
        case .directory, .parentDirectory: type = .folder
        case .archiveZip: type = .zip
        case .archiveRar: type = UTType(filenameExtension: "rar") ?? .archive
        case .image: type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .image
        case .unsupported: type = .data
        }
        return NSWorkspace.shared.icon(for: type)
    }

    // MARK: - Content read off the main thread

    private struct Loaded {
        var sections: [Section]
        var kind: String?
        var picture: NSImage?
    }

    private static func loadDetails(for item: FileItem, isCancelled: @escaping () -> Bool) -> Loaded {
        let fsPath = item.archivePath ?? item.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fsPath)) ?? [:]

        var size = item.fileSize
        if item.archivePath == nil, !item.isDirectory, let fsSize = (attrs[.size] as? NSNumber)?.uint64Value {
            size = fsSize
        }

        // Image properties: read from the file's header, or from the
        // entry's data for an image inside an archive.
        var source: CGImageSource?
        if item.type == .image && !isCancelled() {
            if let archivePath = item.archivePath {
                let data: Data? = DiskIOGate.shared.perform(.interactive, label: archivePath) {
                    let ext = (archivePath as NSString).pathExtension.lowercased()
                    return ext == "rar"
                        ? ArchiveReader.loadRarData(archivePath: archivePath, entryPath: item.path, isCancelled: isCancelled)
                        : ArchiveReader.loadZipData(archivePath: archivePath, entryPath: item.path, isCancelled: isCancelled)
                }
                if let data = data {
                    if size == 0 { size = UInt64(data.count) }
                    source = CGImageSourceCreateWithData(data as CFData, nil)
                }
            } else {
                source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil)
            }
        }

        var loaded = Loaded(sections: [])

        var general = Section(title: "General", rows: [])
        var kind = kindDescription(for: item)
        if let source = source, let uti = CGImageSourceGetType(source) as String?,
           let type = UTType(uti), let name = type.localizedDescription {
            kind = item.archivePath != nil ? "\(name) in archive" : name
        }
        general.rows.append(("Kind", kind))
        if size > 0 {
            general.rows.append(("Size", sizeDescription(size)))
            if item.archivePath != nil, !item.isDirectory, let archiveSize = (attrs[.size] as? NSNumber)?.uint64Value {
                general.rows.append(("Archive size", ByteCountFormatter.string(fromByteCount: Int64(archiveSize), countStyle: .file)))
            }
        } else if item.type == .archiveZip || item.type == .archiveRar,
                  let archiveSize = (attrs[.size] as? NSNumber)?.uint64Value {
            general.rows.append(("Size", sizeDescription(archiveSize)))
        }
        general.rows.append(contentsOf: locationRows(for: item))
        loaded.sections.append(general)

        if let source = source {
            let (image, camera) = imageSections(source)
            loaded.sections.append(image)
            loaded.sections.append(camera)
            if item.archivePath != nil || cachedPicture(for: item) == nil,
               let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 160
               ] as CFDictionary) {
                loaded.picture = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            }
        }
        if !isCancelled(), let contents = contentsSection(for: item, isCancelled: isCancelled) {
            loaded.sections.append(contents)
        }

        var dates = Section(title: item.archivePath != nil ? "Dates (archive file)" : "Dates", rows: [])
        if let created = attrs[.creationDate] as? Date {
            dates.rows.append(("Created", dateDescription(created)))
        }
        if let modified = attrs[.modificationDate] as? Date {
            dates.rows.append(("Modified", dateDescription(modified)))
        }
        loaded.sections.append(dates)
        loaded.sections.append(Section(title: "Library", rows: libraryRows(for: item)))
        loaded.kind = kind
        return loaded
    }

    private static func imageSections(_ source: CGImageSource) -> (Section, Section) {
        var image = Section(title: "Image", rows: [])
        var camera = Section(title: "Camera", rows: [])
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (image, camera)
        }

        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let mp = Double(w * h) / 1_000_000
            image.rows.append(("Dimensions", "\(w) × \(h) px"))
            image.rows.append(("Megapixels", String(format: "%.1f MP · %@", mp, aspectRatio(w, h))))
        }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 {
            image.rows.append(("Frames", "\(frames)"))
        }
        var colour: [String] = []
        if let model = props[kCGImagePropertyColorModel] as? String { colour.append(model) }
        if let depth = props[kCGImagePropertyDepth] as? Int { colour.append("\(depth)-bit") }
        if (props[kCGImagePropertyHasAlpha] as? Bool) == true { colour.append("alpha") }
        if !colour.isEmpty { image.rows.append(("Colour", colour.joined(separator: " · "))) }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            image.rows.append(("Profile", profile))
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            image.rows.append(("Resolution", "\(Int(dpi.rounded())) dpi"))
        }
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, orientation > 1 {
            image.rows.append(("Orientation", orientationDescription(orientation)))
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model = model {
            // Models often repeat the make ("Canon" + "Canon EOS R5").
            if let make = make, !model.lowercased().hasPrefix(make.lowercased().components(separatedBy: " ")[0]) {
                camera.rows.append(("Camera", "\(make) \(model)"))
            } else {
                camera.rows.append(("Camera", model))
            }
        } else if let make = make {
            camera.rows.append(("Camera", make))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            camera.rows.append(("Lens", lens))
        }
        var exposure: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            exposure.append(String(format: "%g mm", focal))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            exposure.append(String(format: "ƒ/%g", f))
        }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            exposure.append(t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            exposure.append("ISO \(iso)")
        }
        if !exposure.isEmpty {
            camera.rows.append(("Exposure", exposure.joined(separator: " · ")))
        }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            camera.rows.append(("Taken", parser.date(from: taken).map(dateDescription) ?? taken))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            camera.rows.append(("Software", software))
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            camera.rows.append(("Location", String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef)))
        }
        return (image, camera)
    }

    /// Counts what a folder or archive holds.  Image totals come from the
    /// folder stats cache; a RAR archive not read yet is not read just for
    /// this (on a network volume it is read whole).
    private static func contentsSection(for item: FileItem, isCancelled: @escaping () -> Bool) -> Section? {
        guard item.isDirectory || item.type == .archiveZip || item.type == .archiveRar,
              item.type != .parentDirectory else { return nil }
        var section = Section(title: "Contents", rows: [])

        if item.archivePath == nil && item.isDirectory {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? []
            var folders = 0, archives = 0, images = 0, other = 0
            for name in names where !name.hasPrefix(".") {
                let ext = (name as NSString).pathExtension
                if ArchiveReader.isImageExtension(ext) {
                    images += 1
                } else if ArchiveReader.isArchiveExtension(ext) {
                    archives += 1
                } else {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: (item.path as NSString).appendingPathComponent(name), isDirectory: &isDir), isDir.boolValue {
                        folders += 1
                    } else {
                        other += 1
                    }
                }
            }
            section.rows.append(("Images", "\(images)"))
            if folders > 0 { section.rows.append(("Folders", "\(folders)")) }
            if archives > 0 { section.rows.append(("Archives", "\(archives)")) }
            if other > 0 { section.rows.append(("Other files", "\(other)")) }
        }

        var stats = FolderStatsCalculator.cachedStats(for: item)
        let mayList = item.type == .archiveZip || (item.archivePath == nil && item.isDirectory)
        if stats == nil, mayList, !isCancelled() {
            stats = DiskIOGate.shared.perform(.interactive, label: item.path) {
                FolderStatsCalculator.stats(for: item, isCancelled: isCancelled)
            }
        }
        if let stats = stats {
            let label = item.archivePath == nil && item.isDirectory ? "Images (all)" : "Images"
            section.rows.append((label, stats.isComplete ? "\(stats.totalImages)" : "\(stats.totalImages)+ (subfolders not all counted)"))
            if SQLiteCache.shared.isTrackingViewedImagesEnabled, stats.totalImages > 0 {
                section.rows.append(("Viewed", "\(stats.viewedPercentage)%"))
            }
            if stats.favoriteCount > 0 {
                section.rows.append(("Favorites", "★ \(stats.favoriteCount)"))
            }
        } else if item.type == .archiveRar || item.archivePath != nil {
            section.rows.append(("Images", "Not counted yet — open the archive"))
        }
        return section
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func dateDescription(_ date: Date) -> String {
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(dateFormatter.string(from: date))  (\(relative))"
    }

    private static func aspectRatio(_ w: Int, _ h: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(1, gcd(w, h))
        let (rw, rh) = (w / g, h / g)
        if rw <= 32 && rh <= 32 { return "\(rw):\(rh)" }
        return String(format: "%.2f:1", Double(w) / Double(max(h, 1)))
    }

    private static func orientationDescription(_ value: UInt32) -> String {
        switch value {
        case 2: return "Mirrored"
        case 3: return "Rotated 180°"
        case 4: return "Mirrored, rotated 180°"
        case 5: return "Mirrored, rotated 90° CCW"
        case 6: return "Rotated 90° CW"
        case 7: return "Mirrored, rotated 90° CW"
        case 8: return "Rotated 90° CCW"
        default: return "Normal"
        }
    }
}
