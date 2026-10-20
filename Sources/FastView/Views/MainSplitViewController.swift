import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    private let sidebarVC = SidebarViewController()
    private let mainContentVC = NSViewController()
    private let mainImageView = MainImageView()
    private let statusBarView = StatusBarView()

    private var navigationManager: NavigationManager?
    private let loadQueue = DispatchQueue(label: "com.fastview.directoryload", qos: .userInitiated)
    private static let sidebarWidthKey = "FastViewSidebarWidth"

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

    override public func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if splitViewItems.count > 0 {
            let width = splitViewItems[0].viewController.view.bounds.width
            if width > 120 {
                UserDefaults.standard.set(Double(width), forKey: MainSplitViewController.sidebarWidthKey)
            }
        }
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

            let items = mgr.contents()
            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
                self.sidebarVC.setItems(items, selectFirst: targetSelectedItemPath == nil)

                self.statusBarView.updateDirectoryStats(imageCount: imageItems.count, totalSizeBytes: 0)

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
        if item.type == .archiveZip || item.type == .archiveRar {
            loadQueue.async { [weak self] in
                let archiveItems: [FileItem]
                if item.type == .archiveZip {
                    archiveItems = ArchiveReader.listAllZipImages(archivePath: item.path)
                } else {
                    archiveItems = ArchiveReader.listAllRarImages(archivePath: item.path)
                }
                DispatchQueue.main.async {
                    self?.statusBarView.updateDirectoryStats(imageCount: archiveItems.count, totalSizeBytes: item.fileSize)
                }
            }
        }

        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            self?.mainImageView.setImage(image)
            self?.statusBarView.updateImageInfo(item: item, image: image)
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
        if item.type == .parentDirectory {
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
