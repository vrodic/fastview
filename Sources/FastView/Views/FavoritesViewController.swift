import AppKit

/// The Favorites tab: every favorite as a large thumbnail in a grid, sized
/// with `GridSizePicker`.  Double click or Return enlarges the selected one
/// to fill the tab (`EnlargedFavoriteView`); arrows then step through the
/// favorites and Esc, Return or a double click goes back to the grid.
public final class FavoritesViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    /// For Show in Browser and Show Info.
    public weak var splitVC: MainSplitViewController?
    /// Show in Browser: the tab hands the item to the browser tab.
    public var onShowInBrowser: ((FileItem) -> Void)?

    public private(set) var items: [FileItem] = []

    private let topBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "Favorites")
    private let countLabel = NSTextField(labelWithString: "")
    private let layoutLabel = NSTextField(labelWithString: "")
    private let sizePicker = GridSizePicker()
    private let scrollView = NSScrollView()
    private let collectionView = FavoritesCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let emptyLabel = NSTextField(labelWithString: "No favorites yet. Press ⌘F on an image in the browser to add it.")

    private var gridSize = FavoritesGridSize.saved
    private var metrics = FavoritesGridMetrics(size: FavoritesGridSize.saved, area: NSSize(width: 1200, height: 800))
    private var thumbnailTimer: Timer?
    private let thumbnailGroup = "favorites-grid"
    private let fullImageGroup = "favorites"
    private let loadQueue = DispatchQueue(label: "com.fastview.favorites", qos: .userInitiated)

    private var enlargedView: EnlargedFavoriteView?
    private var enlargedIndex: Int?
    public var isEnlarged: Bool { enlargedView != nil }

    public var selectedIndex: Int? {
        collectionView.selectionIndexPaths.first.map(\.item).flatMap { $0 < items.count ? $0 : nil }
    }

    public var selectedItem: FileItem? {
        if let i = enlargedIndex, i < items.count { return items[i] }
        return selectedIndex.map { items[$0] }
    }

    override public func loadView() {
        view = NSView()
        view.wantsLayer = true
        setupUI()
    }

    private func setupUI() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        layoutLabel.translatesAutoresizingMaskIntoConstraints = false
        layoutLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        layoutLabel.textColor = .secondaryLabelColor
        layoutLabel.alignment = .right

        sizePicker.select(gridSize, sendAction: false)
        sizePicker.target = self
        sizePicker.action = #selector(gridSizeChanged(_:))

        topBar.addSubview(titleLabel)
        topBar.addSubview(countLabel)
        topBar.addSubview(layoutLabel)
        topBar.addSubview(sizePicker)

        flowLayout.minimumInteritemSpacing = FavoritesGridMetrics.spacing
        flowLayout.minimumLineSpacing = FavoritesGridMetrics.spacing
        let inset = FavoritesGridMetrics.inset
        flowLayout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [NSColor.underPageBackgroundColor]
        collectionView.register(FavoriteGridItem.self, forItemWithIdentifier: FavoriteGridItem.identifier)
        collectionView.onDoubleClick = { [weak self] index in self?.enlarge(at: index) }
        collectionView.menuProvider = { [weak self] index in self?.contextMenu(for: index) }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(gridDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        view.addSubview(scrollView)
        view.addSubview(topBar)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            sizePicker.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            sizePicker.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            layoutLabel.trailingAnchor.constraint(equalTo: sizePicker.leadingAnchor, constant: -10),
            layoutLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            layoutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40)
        ])
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        updateMetrics()
    }

    /// Fits the cells of `gridSize` to the grid's width.
    private func updateMetrics() {
        let area = scrollView.contentView.bounds.size
        guard area.width > 0 else { return }
        let new = FavoritesGridMetrics(size: gridSize, area: area)
        sizePicker.gridArea = area
        let rows = Int(ceil(new.visibleRows - 0.15))
        layoutLabel.stringValue = "\(new.columns) × \(max(1, rows))"
        guard new.columns != metrics.columns || new.cellWidth != metrics.cellWidth
                || flowLayout.itemSize.width != new.cellWidth else {
            metrics = new
            return
        }
        let firstVisible = collectionView.indexPathsForVisibleItems().map(\.item).min()
        metrics = new
        flowLayout.itemSize = NSSize(width: new.cellWidth, height: new.cellHeight)
        flowLayout.invalidateLayout()
        // Keep the selection, or else the top-left item, in view.
        if let index = selectedIndex ?? firstVisible, index < items.count {
            DispatchQueue.main.async { [weak self] in
                self?.collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
            }
        }
        scheduleThumbnailLoad()
    }

    @objc private func gridSizeChanged(_ sender: GridSizePicker) {
        setGridSize(sender.selectedSize)
    }

    private func setGridSize(_ size: FavoritesGridSize) {
        guard size != gridSize else { return }
        gridSize = size
        FavoritesGridSize.saved = size
        sizePicker.select(size, sendAction: false)
        // Thumbnails of the old size are no longer wanted.
        ThumbnailGenerator.shared.cancelThumbnailTasks(inGroup: thumbnailGroup, keeping: [])
        updateMetrics()
        for case let cell as FavoriteGridItem in collectionView.visibleItems() {
            if let id = cell.itemID, let item = items.first(where: { $0.id == id }) {
                cell.configure(with: item, thumbnail: bestCachedThumbnail(for: item))
            }
        }
    }

    public func focusGrid() {
        view.window?.makeFirstResponder(enlargedView?.imageView ?? collectionView)
    }

    // MARK: - Favorites

    /// Reads the favorites again (newest first), keeping the selection.
    public func reload() {
        loadQueue.async { [weak self] in
            let favorites = SQLiteCache.shared.getAllFavorites()
            DispatchQueue.main.async { self?.setItems(favorites) }
        }
    }

    private func setItems(_ newItems: [FileItem]) {
        let selectedID = selectedItem?.id
        let oldIndex = selectedIndex
        items = newItems
        collectionView.reloadData()
        countLabel.stringValue = newItems.count == 1 ? "1 item" : "\(newItems.count) items"
        emptyLabel.isHidden = !newItems.isEmpty

        if let id = selectedID, let index = newItems.firstIndex(where: { $0.id == id }) {
            select(index, scroll: false)
        } else if !newItems.isEmpty {
            select(min(oldIndex ?? 0, newItems.count - 1), scroll: oldIndex != nil)
        }
        if let index = enlargedIndex {
            if newItems.isEmpty {
                closeEnlarged(animated: false)
            } else if newItems.indices.contains(index), newItems[index].id == selectedID {
                enlargedView?.setInfo(item: newItems[index], index: index, count: newItems.count)
            } else {
                showEnlarged(at: selectedIndex ?? 0)
            }
        }
        scheduleThumbnailLoad(delay: 0)
    }

    private func select(_ index: Int, scroll: Bool = true) {
        guard index >= 0 && index < items.count else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        if scroll {
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        }
    }

    private func removeFavorite(at index: Int) {
        guard index < items.count else { return }
        _ = SQLiteCache.shared.toggleFavorite(item: items[index])
        if splitVC?.showFavoritesOnly == true || splitVC?.showFavoritesOnlyPane2 == true {
            splitVC?.reloadDirectoryContentsPublic()
        }
        // The item now at its place is selected next.
        collectionView.selectionIndexPaths = []
        items.remove(at: index)
        collectionView.reloadData()
        countLabel.stringValue = items.count == 1 ? "1 item" : "\(items.count) items"
        emptyLabel.isHidden = !items.isEmpty
        guard !items.isEmpty else {
            closeEnlarged(animated: false)
            return
        }
        let next = min(index, items.count - 1)
        if enlargedIndex != nil {
            showEnlarged(at: next)
        } else {
            select(next)
        }
        scheduleThumbnailLoad(delay: 0)
    }

    // MARK: - Thumbnails

    /// Pixel size the cells ask for: the cell's width on screen, in steps so
    /// window resizes reuse cached thumbnails.
    private var thumbnailSize: CGSize {
        let scale = view.window?.backingScaleFactor ?? 2
        let pixels = metrics.cellWidth * scale
        let side = [384, 512, 768, 1024, 1536].map(CGFloat.init).first { $0 >= pixels } ?? 1536
        return CGSize(width: side, height: side)
    }

    private func cacheKey(for item: FileItem, size: CGSize) -> String {
        "thumb_\(item.id)_\(size.width)x\(size.height)"
    }

    /// The thumbnail of the grid's size, else the sidebar's smaller one.
    private func bestCachedThumbnail(for item: FileItem) -> NSImage? {
        MemoryLRUCache.shared.object(forKey: cacheKey(for: item, size: thumbnailSize))
            ?? MemoryLRUCache.shared.object(forKey: cacheKey(for: item, size: CGSize(width: 256, height: 256)))
    }

    @objc private func gridDidScroll(_ notification: Notification) {
        scheduleThumbnailLoad()
    }

    private func scheduleThumbnailLoad(delay: TimeInterval = 0.12) {
        thumbnailTimer?.invalidate()
        // Common modes, so it also fires while the scroller knob is dragged.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.loadVisibleThumbnails()
        }
        RunLoop.main.add(timer, forMode: .common)
        thumbnailTimer = timer
    }

    /// Drops thumbnail work for cells scrolled away and requests the visible
    /// ones, top to bottom.
    private func loadVisibleThumbnails() {
        guard view.window != nil, !items.isEmpty else { return }
        let visible = collectionView.indexPathsForVisibleItems().map(\.item).filter { $0 < items.count }.sorted()
        ThumbnailGenerator.shared.cancelThumbnailTasks(inGroup: thumbnailGroup, keeping: Set(visible.map { items[$0].id }))
        let size = thumbnailSize
        for index in visible {
            let item = items[index]
            if MemoryLRUCache.shared.object(forKey: cacheKey(for: item, size: size)) != nil {
                continue
            }
            ThumbnailGenerator.shared.generateThumbnailWithStats(for: item, targetSize: size, group: thumbnailGroup) { [weak self] image, _ in
                guard let image = image else { return }
                self?.thumbnailArrived(image, for: item.id)
            }
        }
    }

    private func thumbnailArrived(_ image: NSImage, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? FavoriteGridItem, cell.itemID == id {
            cell.setThumbnail(image)
        }
    }

    // MARK: - NSCollectionViewDataSource

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FavoriteGridItem.identifier, for: indexPath)
        if let cell = cell as? FavoriteGridItem, indexPath.item < items.count {
            let item = items[indexPath.item]
            cell.configure(with: item, thumbnail: bestCachedThumbnail(for: item))
        }
        // Missing thumbnails are requested once scrolling settles.
        scheduleThumbnailLoad()
        return cell
    }

    // MARK: - Keys

    /// Keys the main window routes here while this tab shows; true when handled.
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCmd = flags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isCmd {
            if chars == "f" && !flags.contains(.shift), let item = selectedItem, let index = items.firstIndex(of: item) {
                removeFavorite(at: index)
                return true
            }
            if let enlarged = enlargedView {
                switch chars {
                case "+", "=": enlarged.imageView.zoomIn(); return true
                case "-": enlarged.imageView.zoomOut(); return true
                case "0": enlarged.imageView.resetZoomToFit(); return true
                default: return false
                }
            }
            switch chars {
            case "+", "=":
                if let bigger = gridSize.bigger { setGridSize(bigger) }
                return true
            case "-":
                if let smaller = gridSize.smaller { setGridSize(smaller) }
                return true
            default:
                return false
            }
        }

        if let index = enlargedIndex {
            switch event.keyCode {
            case 123, 126, 116: // Left, Up, Page Up
                if index > 0 { showEnlarged(at: index - 1) }
                return true
            case 124, 125, 121, 49: // Right, Down, Page Down, Space
                if index + 1 < items.count { showEnlarged(at: index + 1) }
                return true
            case 115: // Home
                showEnlarged(at: 0)
                return true
            case 119: // End
                showEnlarged(at: items.count - 1)
                return true
            case 36, 76, 53, 51: // Return, Enter, Escape, Backspace
                closeEnlarged(animated: true)
                return true
            default:
                return false
            }
        }

        guard !items.isEmpty else { return false }
        let current = selectedIndex
        let columns = metrics.columns
        let page = columns * max(1, Int(floor(metrics.visibleRows)))
        switch event.keyCode {
        case 123: select(max(0, (current ?? 1) - 1)); return true // Left
        case 124: select(min(items.count - 1, (current ?? -1) + 1)); return true // Right
        case 126: select(max(0, (current ?? 0) - columns)); return true // Up
        case 125: select(current.map { min(items.count - 1, $0 + columns) } ?? 0); return true // Down
        case 116: select(max(0, (current ?? 0) - page)); return true // Page Up
        case 121: select(min(items.count - 1, (current ?? 0) + page)); return true // Page Down
        case 115: select(0); return true // Home
        case 119: select(items.count - 1); return true // End
        case 36, 76, 49: // Return, Enter, Space
            enlarge(at: current ?? 0)
            return true
        default:
            return false
        }
    }

    // MARK: - Enlarged view

    private func enlarge(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        select(index, scroll: false)

        let enlarged = EnlargedFavoriteView()
        enlarged.translatesAutoresizingMaskIntoConstraints = false
        enlarged.onClose = { [weak self] in self?.closeEnlarged(animated: true) }
        enlarged.onStep = { [weak self] step in
            guard let self = self, let current = self.enlargedIndex else { return }
            let next = current + step
            if next >= 0 && next < self.items.count { self.showEnlarged(at: next) }
        }
        view.addSubview(enlarged)
        NSLayoutConstraint.activate([
            enlarged.topAnchor.constraint(equalTo: view.topAnchor),
            enlarged.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            enlarged.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            enlarged.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        enlargedView = enlarged
        view.layoutSubtreeIfNeeded()
        showEnlarged(at: index)
        view.window?.makeFirstResponder(enlarged.imageView)

        // Grows from the thumbnail to the full tab.
        if let start = thumbnailFrame(at: index), let image = bestCachedThumbnail(for: items[index]) {
            let zoom = NSImageView(frame: start)
            zoom.image = image
            zoom.imageScaling = .scaleProportionallyUpOrDown
            zoom.wantsLayer = true
            view.addSubview(zoom)
            enlarged.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                zoom.animator().frame = view.bounds
                enlarged.animator().alphaValue = 1
            }, completionHandler: {
                zoom.removeFromSuperview()
            })
        }
    }

    /// The cell's image area in this view's coordinates.
    private func thumbnailFrame(at index: Int) -> NSRect? {
        guard let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? FavoriteGridItem else { return nil }
        let frame = cell.imageAreaFrame
        return cell.view.convert(frame, to: view)
    }

    private func showEnlarged(at index: Int) {
        guard let enlarged = enlargedView, index >= 0 && index < items.count else { return }
        let item = items[index]
        enlargedIndex = index
        select(index)
        enlarged.setInfo(item: item, index: index, count: items.count)

        let imageView = enlarged.imageView
        imageView.resetOrientation()
        imageView.setImage(bestCachedThumbnail(for: item), keepZoom: false)
        imageView.beginLoading(statusText: "Loading \(item.name)...")
        ThumbnailGenerator.shared.loadFullImage(for: item, group: fullImageGroup, progress: { [weak imageView] update in
            imageView?.updateLoadingProgress(update)
        }) { [weak self, weak imageView] image in
            guard let self = self, let imageView = imageView, self.enlargedIndex == index,
                  index < self.items.count, self.items[index].id == item.id else { return }
            guard let image = image else {
                imageView.hideLoading()
                return
            }
            if item.type == .image {
                SQLiteCache.shared.markImageAsViewed(key: SidebarTableCellView.viewedKey(for: item))
            }
            imageView.setImage(image, keepZoom: false)
        }
    }

    public func closeEnlarged(animated: Bool) {
        guard let enlarged = enlargedView else { return }
        let index = enlargedIndex
        enlargedView = nil
        enlargedIndex = nil
        ThumbnailGenerator.shared.cancelPriorityTasks(inGroup: fullImageGroup)
        ThumbnailGenerator.shared.setMainImageLoading(false)
        view.window?.makeFirstResponder(collectionView)

        if let index = index { select(index) }
        collectionView.layoutSubtreeIfNeeded()
        // Full-image loads drop queued thumbnails; ask for them again.
        scheduleThumbnailLoad(delay: 0)

        guard animated, let i = index, let end = thumbnailFrame(at: i) else {
            enlarged.removeFromSuperview()
            return
        }
        let zoom = NSImageView(frame: view.bounds)
        zoom.image = enlarged.imageView.rawImage ?? bestCachedThumbnail(for: items[i])
        zoom.imageScaling = .scaleProportionallyUpOrDown
        zoom.wantsLayer = true
        view.addSubview(zoom)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            zoom.animator().frame = end
            enlarged.animator().alphaValue = 0
        }, completionHandler: {
            zoom.removeFromSuperview()
            enlarged.removeFromSuperview()
        })
    }

    // MARK: - Context menu

    private func contextMenu(for index: Int) -> NSMenu? {
        guard index < items.count else { return nil }
        select(index, scroll: false)
        let item = items[index]
        let menu = NSMenu(title: "Favorite")
        func add(_ title: String, _ action: Selector) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }
        add("View Large", #selector(viewLargeAction(_:)))
        add("Show in Browser", #selector(showInBrowserAction(_:)))
        add("Show Info", #selector(showInfoAction(_:)))
        add("Show in Finder", #selector(showInFinderAction(_:)))
        menu.addItem(.separator())
        add("Copy Image to Clipboard", #selector(copyImageAction(_:)))
        add("Copy File Path", #selector(copyPathAction(_:)))
        menu.addItem(.separator())
        add("Remove from Favorites", #selector(removeFavoriteAction(_:)))
        return menu
    }

    private func index(of sender: NSMenuItem) -> Int? {
        guard let item = sender.representedObject as? FileItem else { return nil }
        return items.firstIndex(of: item)
    }

    @objc private func viewLargeAction(_ sender: NSMenuItem) {
        if let index = index(of: sender) { enlarge(at: index) }
    }

    @objc private func showInBrowserAction(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem { onShowInBrowser?(item) }
    }

    @objc private func showInfoAction(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem { splitVC?.showInfo(for: item) }
    }

    @objc private func showInFinderAction(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FileItem { FileActions.showInFinder(item) }
    }

    @objc private func copyImageAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        copyImage(of: item)
    }

    /// Copies the full image of `item`.
    public func copyImage(of item: FileItem) {
        ThumbnailGenerator.shared.loadFullImage(for: item, group: fullImageGroup) { [weak self] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.copyImage(image)
                if let view = self?.view { HUDMessageView.show("Copied Image", in: view) }
            }
        }
    }

    @objc private func copyPathAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }

    @objc private func removeFavoriteAction(_ sender: NSMenuItem) {
        if let index = index(of: sender) { removeFavorite(at: index) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        thumbnailTimer?.invalidate()
    }
}

/// Reports double clicks and asks for the context menu of the item clicked.
final class FavoritesCollectionView: NSCollectionView {
    var onDoubleClick: ((Int) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2,
           let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(path.item)
    }
}

/// One favorite in the grid: a square thumbnail with the name below.
final class FavoriteGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FavoriteGridItem")

    private let imageArea = NSView()
    private let thumbnailView = NSImageView()
    private let placeholderView = NSImageView()
    private let typeBadge = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private(set) var itemID: String?

    /// The square the thumbnail is drawn in, in the item view's coordinates.
    var imageAreaFrame: NSRect {
        guard let image = thumbnailView.image, image.size.width > 0, image.size.height > 0 else { return imageArea.frame }
        let area = imageArea.frame.insetBy(dx: 4, dy: 4)
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        imageArea.translatesAutoresizingMaskIntoConstraints = false
        imageArea.wantsLayer = true
        imageArea.layer?.cornerRadius = 8
        imageArea.layer?.borderWidth = 3

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .light))
        placeholderView.contentTintColor = .tertiaryLabelColor

        typeBadge.translatesAutoresizingMaskIntoConstraints = false
        typeBadge.imageScaling = .scaleProportionallyUpOrDown
        typeBadge.contentTintColor = .controlAccentColor
        typeBadge.isHidden = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center

        view.addSubview(imageArea)
        imageArea.addSubview(placeholderView)
        imageArea.addSubview(thumbnailView)
        imageArea.addSubview(typeBadge)
        view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            imageArea.topAnchor.constraint(equalTo: view.topAnchor),
            imageArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageArea.heightAnchor.constraint(equalTo: imageArea.widthAnchor),

            thumbnailView.topAnchor.constraint(equalTo: imageArea.topAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor, constant: -4),
            thumbnailView.bottomAnchor.constraint(equalTo: imageArea.bottomAnchor, constant: -4),

            placeholderView.centerXAnchor.constraint(equalTo: imageArea.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor),

            typeBadge.topAnchor.constraint(equalTo: imageArea.topAnchor, constant: 6),
            typeBadge.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: 6),
            typeBadge.widthAnchor.constraint(equalToConstant: 44),
            typeBadge.heightAnchor.constraint(equalToConstant: 44),

            nameLabel.topAnchor.constraint(equalTo: imageArea.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
        updateSelection()
    }

    func configure(with item: FileItem, thumbnail: NSImage?) {
        itemID = item.id
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.archivePath.map { "\($0) › \(item.path)" } ?? item.path

        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        if item.isDirectory {
            typeBadge.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?.withSymbolConfiguration(badgeConfig)
            typeBadge.isHidden = false
        } else if item.type == .archiveZip || item.type == .archiveRar {
            typeBadge.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive")?.withSymbolConfiguration(badgeConfig)
            typeBadge.isHidden = false
        } else {
            typeBadge.isHidden = true
        }

        thumbnailView.image = thumbnail
        placeholderView.isHidden = thumbnail != nil
    }

    func setThumbnail(_ image: NSImage) {
        thumbnailView.image = image
        placeholderView.isHidden = true
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateSelection()
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            imageArea.layer?.backgroundColor = (isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
            imageArea.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        nameLabel.textColor = isSelected ? .controlAccentColor : .labelColor
    }
}

/// `MainImageView` that reports double clicks (to leave the enlarged view).
final class FavoriteImageView: MainImageView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && !isCensoring && !isFreehandSelectionMode {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// A favorite filling the tab: zoomable image, name and position, a close
/// button and previous/next buttons.
final class EnlargedFavoriteView: NSView {
    let imageView = FavoriteImageView()
    var onClose: (() -> Void)?
    var onStep: ((Int) -> Void)?

    private let infoContainer = NSView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onDoubleClick = { [weak self] in self?.onClose?() }
        addSubview(imageView)

        infoContainer.translatesAutoresizingMaskIntoConstraints = false
        infoContainer.wantsLayer = true
        infoContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        infoContainer.layer?.cornerRadius = 10
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = .white
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoContainer.addSubview(infoLabel)
        addSubview(infoContainer)

        configure(closeButton, symbol: "xmark.circle.fill", label: "Back to Grid", action: #selector(closeClicked))
        configure(previousButton, symbol: "chevron.left.circle.fill", label: "Previous Favorite", action: #selector(previousClicked))
        configure(nextButton, symbol: "chevron.right.circle.fill", label: "Next Favorite", action: #selector(nextClicked))

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            infoContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            infoContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            infoContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -140),
            infoLabel.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -12),
            infoLabel.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 5),
            infoLabel.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -5),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            previousButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        button.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        button.toolTip = label
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        addSubview(button)
    }

    func setInfo(item: FileItem, index: Int, count: Int) {
        infoLabel.stringValue = "\(item.name)    \(index + 1) of \(count)"
        previousButton.isHidden = index == 0
        nextButton.isHidden = index + 1 >= count
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func previousClicked() { onStep?(-1) }
    @objc private func nextClicked() { onStep?(1) }
}
