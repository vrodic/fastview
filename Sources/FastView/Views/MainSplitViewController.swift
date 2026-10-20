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

    public private(set) var lastMeasuredSpeedMBs: Double = 25.0 // Initial speed baseline (25 MB/s)

    public var showFavoritesOnly: Bool = false {
        didSet {
            reloadDirectoryContentsAsync()
        }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        let savedWidth = UserDefaults.standard.double(forKey: MainSplitViewController.sidebarWidthKey)
        if savedWidth > 120 && splitView.subviews.count > 0 {
            splitView.setPosition(CGFloat(savedWidth), ofDividerAt: 0)
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

    private func reloadDirectoryContentsAsync(targetSelectedItemPath: String? = nil, isNavigatingUp: Bool = false) {
        guard let navMgr = navigationManager else { return }
        cancelAllIOOperations()

        let startTime = CFAbsoluteTimeGetCurrent()
        let path = navMgr.currentLocation.physicalPath
        FileLogger.shared.log("DIR_OPEN_START", path: path)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !workItem.isCancelled, let mgr = self.navigationManager else { return }

            var items = mgr.contents()
            if workItem.isCancelled { return }

            if self.showFavoritesOnly {
                items = items.filter { item in
                    if item.type == .parentDirectory { return true }
                    return SQLiteCache.shared.isFavorite(path: item.path)
                }
            }

            if workItem.isCancelled { return }

            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
                if workItem.isCancelled { return }
                self.sidebarVC.setItems(items, selectFirst: targetSelectedItemPath == nil)

                let parentName = (path as NSString).lastPathComponent
                self.statusBarView.updateDirectoryStats(imageCount: imageItems.count, totalSizeBytes: 0, locationName: parentName)

                if let targetPath = targetSelectedItemPath,
                   let idx = items.firstIndex(where: { $0.path == targetPath || $0.id == targetPath }) {
                    self.sidebarVC.selectRow(idx)
                } else if targetSelectedItemPath == nil,
                          let firstItem = items.first(where: { $0.type == .image || $0.type == .archiveZip || $0.type == .archiveRar }) {
                    self.displayItem(firstItem)
                }

                self.sidebarVC.loadVisibleThumbnailsIfIdle()
            }
        }

        lock.lock()
        currentDirectoryLoadItem = workItem
        lock.unlock()

        loadQueue.async(execute: workItem)
    }

    public func displayItem(_ item: FileItem) {
        let parentName: String
        if let nav = navigationManager {
            parentName = (nav.currentLocation.physicalPath as NSString).lastPathComponent
        } else {
            parentName = ""
        }

        let imageItems = sidebarVC.items.filter { $0.type == .image }
        let currentIndex = imageItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        let totalImages = imageItems.count

        if item.type == .image {
            statusBarView.updateImageInfo(item: item, image: nil, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)
            mainImageView.setImage(nil, keepZoom: true) // No progress bar when loading images inside archive/directory
        } else if item.type == .archiveZip || item.type == .archiveRar {
            statusBarView.updateSelectedItemStats(item: item, containedImagesCount: nil, parentName: parentName)
            mainImageView.showLoading(fileSizeBytes: item.fileSize, pastSpeedMBs: lastMeasuredSpeedMBs) // Progress bar for archive file peeking

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

        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            guard let self = self else { return }

            let duration = CFAbsoluteTimeGetCurrent() - readStartTime
            if duration > 0 && item.fileSize > 0 {
                let speedMBs = (Double(item.fileSize) / (1024.0 * 1024.0)) / duration
                self.lastMeasuredSpeedMBs = (self.lastMeasuredSpeedMBs * 0.7) + (speedMBs * 0.3)
            }

            self.mainImageView.setImage(image, keepZoom: true)
            self.statusBarView.updateImageInfo(item: item, image: image, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)

            if let image = image {
                let cacheKey = "thumb_\(item.id)_256.0x256.0"
                let cost = Int(image.size.width * image.size.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                self.sidebarVC.updateThumbnailForSelectedItem(image: image)
            }
        }
    }

    public func toggleFavoriteOnSelectedItem() {
        if let item = sidebarVC.selectedItem {
            _ = SQLiteCache.shared.toggleFavorite(path: item.path)
            sidebarVC.reloadSelectedRow()
        }
    }

    // SidebarDelegate
    public func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem) {
        displayItem(item)
    }

    public func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem) {
        handleActivation(of: item)
    }

    public func handleActivation(of item: FileItem) {
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
        guard let selected = sidebarVC.selectedItem,
              let currentIndex = items.firstIndex(of: selected) else { return }

        let currentGroup = selected.entryParentDir

        for i in (currentIndex + 1)..<items.count {
            let item = items[i]
            if item.isDirectory || item.type == .archiveZip || item.type == .archiveRar {
                sidebarVC.selectRow(i)
                return
            } else if let group = item.entryParentDir, group != currentGroup {
                sidebarVC.selectRow(i)
                return
            }
        }

        selectNextHierarchyItem()
    }

    public func selectPreviousArchiveOrFolderFirstImage() {
        let items = sidebarVC.items
        guard let selected = sidebarVC.selectedItem,
              let currentIndex = items.firstIndex(of: selected) else { return }

        let currentGroup = selected.entryParentDir

        for i in (0..<currentIndex).reversed() {
            let item = items[i]
            if item.isDirectory || item.type == .archiveZip || item.type == .archiveRar {
                sidebarVC.selectRow(i)
                return
            } else if let group = item.entryParentDir, group != currentGroup {
                var groupStartIdx = i
                while groupStartIdx > 0 && items[groupStartIdx - 1].entryParentDir == group {
                    groupStartIdx -= 1
                }
                sidebarVC.selectRow(groupStartIdx)
                return
            }
        }

        if !items.isEmpty {
            let firstIdx = items[0].type == .parentDirectory && items.count > 1 ? 1 : 0
            sidebarVC.selectRow(firstIdx)
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
