import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    private let sidebarVC = SidebarViewController()
    private let mainContentVC = NSViewController()
    private let mainImageView = MainImageView()
    private let statusBarView = StatusBarView()

    private var navigationManager: NavigationManager?
    private let loadQueue = DispatchQueue(label: "com.fastview.directoryload", qos: .userInitiated)
    private var currentDirectoryLoadItem: DispatchWorkItem?
    private let lock = NSLock()
    private static let sidebarWidthKey = "FastViewSidebarWidth"

    public private(set) var lastMeasuredSpeedMBs: Double = 25.0

    public var currentLocationPath: String? {
        return navigationManager?.currentLocation.physicalPath
    }

    public var selectedItemPath: String? {
        return sidebarVC.selectedItem?.path
    }

    public var selectedItemId: String? {
        return sidebarVC.selectedItem?.id
    }

    public var showFavoritesOnly: Bool = false {
        didSet {
            UserDefaults.standard.set(showFavoritesOnly, forKey: "FastViewIsFavoritesMode")
            if showFavoritesOnly != oldValue {
                reloadDirectoryContentsAsync()
            }
        }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        splitView.delegate = self
        let savedWidth = UserDefaults.standard.double(forKey: MainSplitViewController.sidebarWidthKey)
        if savedWidth > 120 && splitView.subviews.count > 0 {
            splitView.setPosition(CGFloat(savedWidth), ofDividerAt: 0)
        }
    }

    override public func splitViewDidResizeSubviews(_ notification: Notification) {
        if splitView.subviews.count > 0 {
            let currentWidth = splitView.subviews[0].frame.width
            if currentWidth > 120 {
                UserDefaults.standard.set(currentWidth, forKey: MainSplitViewController.sidebarWidthKey)
            }
        }
    }

    private func setupUI() {
        sidebarVC.delegate = self

        let mainStackView = NSStackView()
        mainStackView.orientation = .vertical
        mainStackView.spacing = 0
        mainStackView.distribution = .fill

        mainImageView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        mainStackView.addArrangedSubview(mainImageView)
        mainStackView.addArrangedSubview(statusBarView)

        mainContentVC.view = mainStackView

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 120
        sidebarItem.maximumThickness = 1200
        sidebarItem.preferredThicknessFraction = 0.25

        let mainItem = NSSplitViewItem(viewController: mainContentVC)
        mainItem.minimumThickness = 300

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
    }

    public func loadLocation(_ location: NavigationLocation, targetSelectedItemPath: String? = nil) {
        cancelAllIOOperations()
        navigationManager = NavigationManager(initialLocation: location)
        reloadDirectoryContentsAsync(targetSelectedItemPath: targetSelectedItemPath)
    }

    public func cancelAllIOOperations() {
        lock.lock()
        currentDirectoryLoadItem?.cancel()
        currentDirectoryLoadItem = nil
        lock.unlock()
        ThumbnailGenerator.shared.cancelAllPendingTasks()
    }

    public func reloadDirectoryContentsPublic() {
        reloadDirectoryContentsAsync()
    }

    private func reloadDirectoryContentsAsync(targetSelectedItemPath: String? = nil, isNavigatingUp: Bool = false) {
        cancelAllIOOperations()

        let startTime = CFAbsoluteTimeGetCurrent()

        if showFavoritesOnly {
            let favorites = SQLiteCache.shared.getAllFavorites()
            sidebarVC.setItems(favorites, selectFirst: targetSelectedItemPath == nil)
            statusBarView.updateDirectoryStats(imageCount: favorites.count, totalSizeBytes: 0, locationName: "Favorites")

            if let targetPath = targetSelectedItemPath,
               let idx = favorites.firstIndex(where: {
                   $0.id == targetPath ||
                   $0.path == targetPath ||
                   $0.name == targetPath ||
                   (targetPath as NSString).lastPathComponent == $0.name ||
                   $0.path.hasSuffix(targetPath) ||
                   targetPath.hasSuffix($0.path)
               }) {
                sidebarVC.selectRow(idx)
                displayItem(favorites[idx])
            } else if targetSelectedItemPath == nil, let first = favorites.first {
                displayItem(first)
            }
            return
        }

        guard let navMgr = navigationManager else { return }

        let path = navMgr.currentLocation.physicalPath
        let isArchive = navMgr.currentLocation.isArchive

        let archiveURL = URL(fileURLWithPath: path)
        let archiveName = archiveURL.lastPathComponent
        let folderName = archiveURL.deletingLastPathComponent().lastPathComponent

        var archiveSize: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            archiveSize = size
        }

        let locationTitle: String
        if isArchive {
            if let targetPath = targetSelectedItemPath {
                let targetName = (targetPath as NSString).lastPathComponent
                if !folderName.isEmpty {
                    locationTitle = "\(folderName) / \(archiveName) / \(targetName)"
                } else {
                    locationTitle = "\(archiveName) / \(targetName)"
                }
            } else {
                if !folderName.isEmpty {
                    locationTitle = "\(folderName) / \(archiveName) / Loading..."
                } else {
                    locationTitle = "\(archiveName) / Loading..."
                }
            }
        } else {
            locationTitle = (path as NSString).lastPathComponent
        }

        // Draw status bar information immediately before starting LIST_(ZIP/RAR)_START operations
        statusBarView.updateDirectoryStats(imageCount: 0, totalSizeBytes: archiveSize, locationName: locationTitle)

        // Show progress bar immediately for archive opening operations
        if isArchive {
            let loadingMessage = String(format: "Opening archive %@...", archiveName)
            mainImageView.showLoading(fileSizeBytes: archiveSize, pastSpeedMBs: lastMeasuredSpeedMBs, statusText: loadingMessage)
        }

        FileLogger.shared.log("DIR_OPEN_START", path: path)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !workItem.isCancelled, let mgr = self.navigationManager else { return }

            let items = mgr.contents()
            if workItem.isCancelled { return }

            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
                if workItem.isCancelled { return }
                self.sidebarVC.setItems(items, selectFirst: targetSelectedItemPath == nil)

                if let targetPath = targetSelectedItemPath,
                   let idx = items.firstIndex(where: {
                       $0.id == targetPath ||
                       $0.path == targetPath ||
                       $0.name == targetPath ||
                       (targetPath as NSString).lastPathComponent == $0.name ||
                       $0.path.hasSuffix(targetPath) ||
                       targetPath.hasSuffix($0.path) ||
                       (targetPath.contains("#") && targetPath.hasSuffix("#" + $0.id))
                   }) {
                    print("[MainSplitVC] Selected target item '\(items[idx].name)' at index \(idx)")
                    self.sidebarVC.selectRow(idx)
                    self.displayItem(items[idx])
                } else if targetSelectedItemPath == nil,
                          let firstItem = items.first(where: { $0.type == .image || $0.type == .archiveZip || $0.type == .archiveRar }) {
                    self.displayItem(firstItem)
                } else {
                    self.statusBarView.updateDirectoryStats(imageCount: imageItems.count, totalSizeBytes: archiveSize, locationName: locationTitle)
                    if imageItems.isEmpty {
                        self.mainImageView.hideLoading()
                        self.mainImageView.setImage(nil, keepZoom: false)
                    }
                }

                self.sidebarVC.loadVisibleThumbnailsIfIdle()
            }
        }

        lock.lock()
        currentDirectoryLoadItem = workItem
        lock.unlock()

        loadQueue.async(execute: workItem)
    }

    public func switchToCurrentItemLocationMode() {
        guard let item = sidebarVC.selectedItem else {
            showFavoritesOnly = false
            return
        }
        showFavoritesOnly = false

        let targetPath = item.id.isEmpty ? item.path : item.id

        let loc: NavigationLocation
        if let archivePath = item.archivePath, !archivePath.isEmpty {
            let archiveType = ArchiveReader.fileType(for: URL(fileURLWithPath: archivePath))
            let subfolder = ArchiveReader.flattenArchiveDirectories ? "" : (item.entryParentDir ?? "")
            loc = NavigationLocation(
                physicalPath: archivePath,
                archiveSubfolder: subfolder,
                isArchive: true,
                archiveType: archiveType
            )
        } else {
            loc = NavigationManager.locationForPath(item.path)
        }

        print("[MainSplitVC] switchToCurrentItemLocationMode for item '\(item.name)', targetPath: '\(targetPath)', locPath: '\(loc.physicalPath)' (archiveSubfolder: '\(loc.archiveSubfolder ?? "")')")
        loadLocation(loc, targetSelectedItemPath: targetPath)
    }

    public func displayItem(_ item: FileItem) {
        // Ensure progress bar and main image loading only run for the currently selected item
        if let currentSelected = sidebarVC.selectedItem, currentSelected.id != item.id {
            return
        }

        // Automatically persist current selection state whenever item is displayed
        if let locPath = currentLocationPath {
            UserDefaults.standard.set(locPath, forKey: "FastViewLastOpenedPath")
        }
        UserDefaults.standard.set(item.path, forKey: "FastViewLastSelectedItemPath")
        UserDefaults.standard.set(item.id, forKey: "FastViewLastSelectedItemId")

        let parentName: String
        if showFavoritesOnly {
            parentName = "Favorites"
        } else if let nav = navigationManager {
            parentName = (nav.currentLocation.physicalPath as NSString).lastPathComponent
        } else {
            parentName = ""
        }

        let imageItems = sidebarVC.items.filter { $0.type == .image }
        let currentIndex = imageItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        let totalImages = imageItems.count

        if item.type == .image {
            statusBarView.updateImageInfo(item: item, image: nil, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)
            if MemoryLRUCache.shared.object(forKey: "full_\(item.id)") == nil {
                mainImageView.showLoading(fileSizeBytes: item.fileSize, pastSpeedMBs: lastMeasuredSpeedMBs)
            }
        } else if item.type == .archiveZip || item.type == .archiveRar {
            statusBarView.updateSelectedItemStats(item: item, containedImagesCount: nil, parentName: parentName)

            let thumbKey = "thumb_\(item.id)_256.0x256.0"
            let fullKey = "full_\(item.id)"

            if let cachedFull = MemoryLRUCache.shared.object(forKey: fullKey) {
                mainImageView.setImage(cachedFull, keepZoom: true)
            } else if let cachedThumb = MemoryLRUCache.shared.object(forKey: thumbKey) {
                mainImageView.setImage(cachedThumb, keepZoom: true)
            } else {
                mainImageView.showLoading(fileSizeBytes: item.fileSize, pastSpeedMBs: lastMeasuredSpeedMBs)
            }

            // Count images in the archive for the status bar.  This runs on a
            // plain background queue (not the priority IO queue) because it only
            // reads the central directory, which is already cached after the
            // first open.  It must not race with currentDirectoryLoadItem, so
            // store it in the same slot for cancellation purposes.
            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self] in
                guard let self = self, !workItem.isCancelled else { return }

                let archiveItems: [FileItem]
                if item.type == .archiveZip {
                    archiveItems = ArchiveReader.listAllZipImages(archivePath: item.path, isCancelled: { workItem.isCancelled })
                } else {
                    archiveItems = ArchiveReader.listAllRarImages(archivePath: item.path, isCancelled: { workItem.isCancelled })
                }

                if workItem.isCancelled { return }

                DispatchQueue.main.async {
                    if !workItem.isCancelled {
                        self.statusBarView.updateSelectedItemStats(item: item, containedImagesCount: archiveItems.count, parentName: parentName)
                    }
                }
            }

            lock.lock()
            currentDirectoryLoadItem = workItem
            lock.unlock()

            loadQueue.async(execute: workItem)
        } else if item.isDirectory || item.type == .parentDirectory {
            statusBarView.updateSelectedItemStats(item: item, containedImagesCount: nil, parentName: parentName)
            mainImageView.setImage(nil, keepZoom: false)
            return
        }

        let readStartTime = CFAbsoluteTimeGetCurrent()

        // loadFullImage internally cancels all queued thumbnail work before
        // dispatching onto the priority queue, ensuring the selected image is
        // never blocked behind background thumbnails.
        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            guard let self = self else { return }
            guard self.sidebarVC.selectedItem?.id == item.id else { return }

            if let image = image {
                SQLiteCache.shared.recordView(item: item)
                self.checkAndMarkDirectoryViewedIfComplete()

                let duration = CFAbsoluteTimeGetCurrent() - readStartTime
                if duration > 0 && item.fileSize > 0 {
                    let speedMBs = (Double(item.fileSize) / (1024.0 * 1024.0)) / duration
                    self.lastMeasuredSpeedMBs = (self.lastMeasuredSpeedMBs * 0.7) + (speedMBs * 0.3)
                }

                self.mainImageView.setImage(image, keepZoom: true)
                self.statusBarView.updateImageInfo(item: item, image: image, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)

                let cacheKey = "thumb_\(item.id)_256.0x256.0"
                let cost = Int(image.size.width * image.size.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                self.sidebarVC.updateThumbnailForSelectedItem(image: image)
                self.sidebarVC.reloadSelectedRow()
            } else {
                self.mainImageView.hideLoading()
                self.mainImageView.setImage(nil, keepZoom: false)
            }

            self.sidebarVC.loadVisibleThumbnailsIfIdle()
        }
    }

    public func toggleFavoriteOnSelectedItem() {
        if let item = sidebarVC.selectedItem {
            let newState = SQLiteCache.shared.toggleFavorite(item: item)
            print("[MainSplitVC] Toggled favorite for item: \(item.name) (id: \(item.id), path: \(item.path)), newState isFavorite: \(newState)")
            sidebarVC.reloadSelectedRow()
            if showFavoritesOnly {
                reloadDirectoryContentsAsync()
            }
        } else {
            print("[MainSplitVC] toggleFavoriteOnSelectedItem called but no item selected in sidebar")
        }
    }

    private func checkAndMarkDirectoryViewedIfComplete() {
        guard let navMgr = navigationManager else { return }
        let location = navMgr.currentLocation

        let allFilesToVerify: [FileItem]

        if location.isArchive {
            let archivePath = location.physicalPath
            let archiveType = location.archiveType
            if archiveType == .archiveZip {
                allFilesToVerify = ArchiveReader.listAllZipImages(archivePath: archivePath)
            } else if archiveType == .archiveRar {
                allFilesToVerify = ArchiveReader.listAllRarImages(archivePath: archivePath)
            } else {
                allFilesToVerify = []
            }
        } else {
            allFilesToVerify = navMgr.contents().filter { $0.type == .image }
        }

        guard !allFilesToVerify.isEmpty else { return }

        let allViewed = allFilesToVerify.allSatisfy { item in
            SQLiteCache.shared.isViewed(path: item.id) ||
            SQLiteCache.shared.isViewed(path: item.path) ||
            (item.archivePath != nil ? SQLiteCache.shared.isViewed(path: "\(item.archivePath!) / \(item.path)") : false)
        }

        if allViewed {
            let locPath = location.physicalPath
            if !locPath.isEmpty {
                let dirItem = FileItem(
                    id: locPath,
                    name: (locPath as NSString).lastPathComponent,
                    path: locPath,
                    type: location.isArchive ? (location.archiveType ?? .directory) : .directory,
                    archivePath: nil,
                    isDirectory: true,
                    fileSize: 0,
                    entryParentDir: nil
                )
                SQLiteCache.shared.recordView(item: dirItem)
                print("[MainSplitVC] All \(allFilesToVerify.count) files in location '\(locPath)' viewed! Marked location as viewed.")
            }
        }
    }

    public func showInfoForSelectedItem() {
        guard let item = sidebarVC.selectedItem else {
            let alert = NSAlert()
            alert.messageText = "File Information"
            alert.informativeText = "No file selected."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let viewInfo1 = SQLiteCache.shared.getViewInfo(path: item.id)
        let viewInfo2 = SQLiteCache.shared.getViewInfo(path: item.path)
        let lastViewedDate = viewInfo1.lastViewedAt ?? viewInfo2.lastViewedAt
        let effectiveViewCount = max(viewInfo1.viewCount, viewInfo2.viewCount)

        let lastViewedStr: String
        if let date = lastViewedDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            lastViewedStr = formatter.string(from: date)
        } else {
            lastViewedStr = "Never"
        }

        let sizeFormatted = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

        let fullPathStr: String
        if let archivePath = item.archivePath, !archivePath.isEmpty {
            fullPathStr = "\(archivePath) / \(item.path)"
        } else {
            fullPathStr = item.path
        }

        let alert = NSAlert()
        alert.messageText = "File Information"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        let containerWidth: CGFloat = 550
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Title / Name
        let nameLabel = NSTextField(labelWithString: item.name)
        nameLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.isSelectable = true
        stackView.addArrangedSubview(nameLabel)

        // Path Section Header
        let pathHeaderLabel = NSTextField(labelWithString: "Full Filesystem Path:")
        pathHeaderLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        pathHeaderLabel.textColor = NSColor.secondaryLabelColor
        stackView.addArrangedSubview(pathHeaderLabel)

        // Path View (selectable text field with wrapping)
        let pathTextField = NSTextField(wrappingLabelWithString: fullPathStr)
        pathTextField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathTextField.isSelectable = true
        pathTextField.textColor = NSColor.labelColor
        pathTextField.drawsBackground = true
        pathTextField.backgroundColor = NSColor.controlBackgroundColor
        pathTextField.isBezeled = true
        pathTextField.bezelStyle = .squareBezel
        stackView.addArrangedSubview(pathTextField)

        // Grid for Size, Last Viewed, View Count
        let gridView = NSGridView(views: [
            [NSTextField(labelWithString: "File Size:"), NSTextField(labelWithString: "\(sizeFormatted) (\(item.fileSize) bytes)")],
            [NSTextField(labelWithString: "Last Viewed:"), NSTextField(labelWithString: lastViewedStr)],
            [NSTextField(labelWithString: "View Count:"), NSTextField(labelWithString: "\(effectiveViewCount) \(effectiveViewCount == 1 ? "view" : "views")")]
        ])
        gridView.rowSpacing = 6
        gridView.columnSpacing = 12

        for rowIdx in 0..<gridView.numberOfRows {
            let cell = gridView.cell(atColumnIndex: 0, rowIndex: rowIdx)
            if let label = cell.contentView as? NSTextField {
                label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                label.textColor = NSColor.secondaryLabelColor
            }
            let valCell = gridView.cell(atColumnIndex: 1, rowIndex: rowIdx)
            if let valLabel = valCell.contentView as? NSTextField {
                valLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
                valLabel.isSelectable = true
            }
        }

        stackView.addArrangedSubview(gridView)

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 200))
        accessoryView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: accessoryView.bottomAnchor),
            pathTextField.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        alert.accessoryView = accessoryView
        alert.runModal()
    }

    // SidebarDelegate
    public func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem) {
        displayItem(item)
    }

    public func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem) {
        handleActivation(of: item)
    }

    public func handleActivation(of item: FileItem) {
        if showFavoritesOnly {
            switchToCurrentItemLocationMode()
            return
        }
        guard let navMgr = navigationManager else { return }
        if item.type == .image {
            selectNextImage()
        } else if item.type == .parentDirectory {
            navigateUp()
        } else if item.isDirectory || item.type == .archiveZip || item.type == .archiveRar {
            cancelAllIOOperations()
            if let _ = navMgr.navigateTo(item) {
                reloadDirectoryContentsAsync()
            }
        }
    }

    public func selectNextImage() {
        sidebarVC.selectNext()
    }

    public func selectPreviousImage() {
        sidebarVC.selectPrevious()
    }

    public func selectNextArchiveOrFolderFirstImage() {
        let items = sidebarVC.items
        guard let current = sidebarVC.selectedItem,
              let currentIdx = items.firstIndex(where: { $0.id == current.id }) else { return }

        let currentGroup = current.entryParentDir ?? ""
        for i in (currentIdx + 1)..<items.count {
            let item = items[i]
            let group = item.entryParentDir ?? ""
            if group != currentGroup && (item.type == .image || item.isDirectory || item.type == .archiveZip || item.type == .archiveRar) {
                sidebarVC.selectRow(i)
                return
            }
        }
    }

    public func selectPreviousArchiveOrFolderFirstImage() {
        let items = sidebarVC.items
        guard let current = sidebarVC.selectedItem,
              let currentIdx = items.firstIndex(where: { $0.id == current.id }) else { return }

        let currentGroup = current.entryParentDir ?? ""
        var prevGroup: String? = nil

        for i in stride(from: currentIdx - 1, through: 0, by: -1) {
            let group = items[i].entryParentDir ?? ""
            if group != currentGroup {
                prevGroup = group
                break
            }
        }

        if let prevGroup = prevGroup {
            for i in 0..<currentIdx {
                let item = items[i]
                if (item.entryParentDir ?? "") == prevGroup && (item.type == .image || item.isDirectory || item.type == .archiveZip || item.type == .archiveRar) {
                    sidebarVC.selectRow(i)
                    return
                }
            }
        }
    }

    public func selectPreviousHierarchyItem() {
        guard let navMgr = navigationManager else { return }
        cancelAllIOOperations()

        let result = navMgr.navigateUp()
        let parentLocation = navMgr.currentLocation
        let parentMgr = NavigationManager(initialLocation: parentLocation)
        let parentItems = parentMgr.contents()

        if let exitedIdx = parentItems.firstIndex(where: { $0.path == result.exitedItemPath || $0.id == result.exitedItemPath }),
           exitedIdx > 0 {
            let prevSibling = parentItems[exitedIdx - 1]
            if prevSibling.isDirectory || prevSibling.type == .archiveZip || prevSibling.type == .archiveRar {
                _ = navMgr.navigateTo(prevSibling)
                reloadDirectoryContentsAsync()
            } else {
                reloadDirectoryContentsAsync(targetSelectedItemPath: prevSibling.path)
            }
        } else {
            reloadDirectoryContentsAsync(targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
        }
    }

    public func selectNextHierarchyItem() {
        guard let navMgr = navigationManager else { return }
        cancelAllIOOperations()
        let result = navMgr.navigateUp()
        let parentLocation = navMgr.currentLocation
        let parentMgr = NavigationManager(initialLocation: parentLocation)
        let parentItems = parentMgr.contents()

        if let exitedIdx = parentItems.firstIndex(where: { $0.path == result.exitedItemPath || $0.id == result.exitedItemPath }),
           exitedIdx < parentItems.count - 1 {
            let nextSibling = parentItems[exitedIdx + 1]
            if nextSibling.isDirectory || nextSibling.type == .archiveZip || nextSibling.type == .archiveRar {
                _ = navMgr.navigateTo(nextSibling)
                reloadDirectoryContentsAsync()
            } else {
                reloadDirectoryContentsAsync(targetSelectedItemPath: nextSibling.path)
            }
        } else {
            reloadDirectoryContentsAsync(targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
        }
    }

    public func activateSelectedItem() {
        if let item = sidebarVC.selectedItem {
            handleActivation(of: item)
        }
    }

    public func navigateUp() {
        guard let navMgr = navigationManager else { return }
        cancelAllIOOperations()
        let result = navMgr.navigateUp()
        reloadDirectoryContentsAsync(targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
    }

    public var imageView: MainImageView {
        return mainImageView
    }
}
