import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    private let sidebarVC = SidebarViewController()
    private let mainContentVC = NSViewController()
    private let mainImageView = MainImageView()
    private let statusBarView = StatusBarView()

    private var navigationManager: NavigationManager!

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
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
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 450
        sidebarItem.preferredThicknessFraction = 0.25

        let mainItem = NSSplitViewItem(viewController: mainContentVC)
        mainItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
    }

    public func loadLocation(_ location: NavigationLocation, targetSelectedItem: FileItem? = nil) {
        navigationManager = NavigationManager(initialLocation: location)
        reloadDirectoryContentsAsync(targetSelectedItem: targetSelectedItem)
    }

    private func reloadDirectoryContentsAsync(targetSelectedItem: FileItem? = nil) {
        ThumbnailGenerator.shared.cancelAllPendingTasks()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.navigationManager.contents()

            let imageItems = items.filter { $0.type == .image }
            let totalBytes = items.reduce(0) { $0 + $1.fileSize }

            DispatchQueue.main.async {
                self.sidebarVC.setItems(items, selectFirst: targetSelectedItem == nil)

                self.statusBarView.updateDirectoryStats(imageCount: imageItems.count, totalSizeBytes: totalBytes)

                if let target = targetSelectedItem, let idx = items.firstIndex(where: { $0.id == target.id || $0.path == target.path }) {
                    self.sidebarVC.selectRow(idx)
                } else if let firstItem = items.first(where: { $0.type == .image || $0.type == .archiveZip || $0.type == .archiveRar }) {
                    self.displayItem(firstItem)
                } else {
                    self.mainImageView.setImage(nil)
                    self.statusBarView.clearImageInfo()
                }
            }
        }
    }

    public func displayItem(_ item: FileItem) {
        if item.type == .archiveZip || item.type == .archiveRar {
            let archiveItems: [FileItem]
            if item.type == .archiveZip {
                archiveItems = ArchiveReader.listAllZipImages(archivePath: item.path)
            } else {
                archiveItems = ArchiveReader.listAllRarImages(archivePath: item.path)
            }
            statusBarView.updateDirectoryStats(imageCount: archiveItems.count, totalSizeBytes: item.fileSize)
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
        if item.type == .parentDirectory {
            _ = navigationManager.navigateUp()
            reloadDirectoryContentsAsync()
        } else if item.isDirectory || item.type == .archiveZip || item.type == .archiveRar {
            if let _ = navigationManager.navigateTo(item) {
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
        _ = navigationManager.navigateUp()
        reloadDirectoryContentsAsync()
    }

    public var imageView: MainImageView {
        return mainImageView
    }
}
