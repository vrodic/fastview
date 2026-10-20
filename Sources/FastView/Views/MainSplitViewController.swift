import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    private let sidebarVC = SidebarViewController()
    private let mainContentVC = NSViewController()
    private let mainImageView = MainImageView()
    private let statusBarView = StatusBarView()

    private var navigationManager: NavigationManager?
    private let loadQueue = DispatchQueue(label: "com.fastview.directoryload", qos: .userInitiated)
    private static let sidebarWidthKey = "FastViewSidebarWidth"

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
        navigationManager = NavigationManager(initialLocation: location)
        reloadDirectoryContentsAsync(targetSelectedItemPath: targetSelectedItemPath)
    }

    private func reloadDirectoryContentsAsync(targetSelectedItemPath: String? = nil) {
        guard let navMgr = navigationManager else { return }
        ThumbnailGenerator.shared.cancelAllPendingTasks()

        let startTime = CFAbsoluteTimeGetCurrent()
        let path = navMgr.currentLocation.physicalPath
        FileLogger.shared.log("DIR_OPEN_START", path: path)

        loadQueue.async { [weak self] in
            guard let self = self, let mgr = self.navigationManager else { return }

            var items = mgr.contents()
            if self.showFavoritesOnly {
                items = items.filter { $0.type == .parentDirectory || SQLiteCache.shared.isFavorite(path: $0.path) }
            }

            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
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
            }
        }
    }

    public func displayItem(_ item: FileItem) {
        mainImageView.showLoading()

        let imageItems = sidebarVC.items.filter { $0.type == .image }
        let currentIndex = imageItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        let totalImages = imageItems.count

        let parentName: String
        if let nav = navigationManager {
            parentName = (nav.currentLocation.physicalPath as NSString).lastPathComponent
        } else {
            parentName = ""
        }

        if item.type == .archiveZip || item.type == .archiveRar {
            loadQueue.async { [weak self] in
                let archiveItems: [FileItem]
                if item.type == .archiveZip {
                    archiveItems = ArchiveReader.listAllZipImages(archivePath: item.path)
                } else {
                    archiveItems = ArchiveReader.listAllRarImages(archivePath: item.path)
                }
                DispatchQueue.main.async {
                    self?.statusBarView.updateDirectoryStats(imageCount: archiveItems.count, totalSizeBytes: item.fileSize, locationName: parentName)
                }
            }
        }

        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            guard let self = self else { return }
            self.mainImageView.setImage(image, keepZoom: true)
            self.statusBarView.updateImageInfo(item: item, image: image, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)

            if let image = image {
                let cacheKey = "thumb_\(item.id)_256.0x256.0"
                if MemoryLRUCache.shared.object(forKey: cacheKey) == nil {
                    let cost = Int(image.size.width * image.size.height * 4)
                    MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                }
            }
        }
    }

    public func toggleFavoriteOnSelectedItem() {
        if let item = sidebarVC.selectedItem {
            _ = SQLiteCache.shared.toggleFavorite(path: item.path)
            reloadDirectoryContentsAsync()
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

    public func activateSelectedItem() {
        if let item = sidebarVC.selectedItem {
            handleActivation(of: item)
        }
    }

    public func navigateUp() {
        guard let navMgr = navigationManager else { return }
        let result = navMgr.navigateUp()
        reloadDirectoryContentsAsync(targetSelectedItemPath: result.exitedItemPath)
    }

    public var imageView: MainImageView {
        return mainImageView
    }
}
