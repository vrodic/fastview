import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    private let sidebarVC = SidebarViewController()
    private let mainImageVC = NSViewController()
    private let mainImageView = MainImageView()

    private var navigationManager: NavigationManager!

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        sidebarVC.delegate = self

        mainImageVC.view = mainImageView

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 450
        sidebarItem.preferredThicknessFraction = 0.25

        let mainItem = NSSplitViewItem(viewController: mainImageVC)
        mainItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
    }

    public func loadLocation(_ location: NavigationLocation, targetSelectedItem: FileItem? = nil) {
        navigationManager = NavigationManager(initialLocation: location)
        reloadDirectoryContentsAsync(targetSelectedItem: targetSelectedItem)
    }

    private func reloadDirectoryContentsAsync(targetSelectedItem: FileItem? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let items = self.navigationManager.contents()

            DispatchQueue.main.async {
                self.sidebarVC.setItems(items, selectFirst: targetSelectedItem == nil)

                if let target = targetSelectedItem, let idx = items.firstIndex(where: { $0.id == target.id || $0.path == target.path }) {
                    self.sidebarVC.selectRow(idx)
                } else if let firstItem = items.first(where: { $0.type == .image || $0.type == .archiveZip || $0.type == .archiveRar }) {
                    self.displayItem(firstItem)
                }

                // Background thumbnail prefetching for the next 20 items
                self.prefetchNextThumbnails(items: items, count: 20)
            }
        }
    }

    private func prefetchNextThumbnails(items: [FileItem], count: Int) {
        let itemsToPrefetch = Array(items.prefix(count))
        DispatchQueue.global(qos: .utility).async {
            for item in itemsToPrefetch {
                ThumbnailGenerator.shared.generateThumbnail(for: item) { _ in }
            }
        }
    }

    public func displayItem(_ item: FileItem) {
        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            self?.mainImageView.setImage(image)
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

    // Key event actions
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
