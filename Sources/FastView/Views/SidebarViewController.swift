import AppKit

public protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem)
    func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem)
}

public class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public weak var delegate: SidebarDelegate?

    public private(set) var items: [FileItem] = []
    private let scrollView = NSScrollView()
    private let tableView = CustomTableView()
    private var scrollDebounceTimer: Timer?

    public var selectedItem: FileItem? {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return nil }
        return items[selectedRow]
    }

    override public func loadView() {
        self.view = NSView()
        setupUI()
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autoresizesSubviews = true

        tableView.headerView = nil
        tableView.rowHeight = 120
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onEnterPressed = { [weak self] in
            self?.activateCurrentSelection()
        }
        tableView.onPageKey = { [weak self] keyType in
            self?.handlePageNavigation(keyType: keyType)
        }
        tableView.onToggleFavoritePressed = { [weak self] in
            (self?.parent as? MainSplitViewController)?.toggleFavoriteOnSelectedItem()
                ?? globalAppDelegate?.toggleFavoriteActionFromSidebar()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        scrollDebounceTimer?.invalidate()
        scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.loadVisibleThumbnailsIfIdle()
        }
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        if width > 0 {
            let targetRowHeight = max(80, min(800, width * 0.75))
            if abs(tableView.rowHeight - targetRowHeight) > 5 {
                tableView.rowHeight = targetRowHeight
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            }
        }
    }

    public func setItems(_ items: [FileItem], selectFirst: Bool = true) {
        self.items = items
        tableView.reloadData()

        if selectFirst && !items.isEmpty {
            let defaultIndex = items.count > 1 && items[0].type == .parentDirectory ? 1 : 0
            selectRow(defaultIndex)
        }
    }

    public func loadVisibleThumbnailsIfIdle() {
        let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
        guard visibleRows.length > 0 else { return }

        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            guard row >= 0 && row < items.count else { continue }
            let item = items[row]
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTableCellView {
                cell.loadThumbnailIfIdle(for: item)
            }
        }
    }

    public func selectRow(_ index: Int) {
        guard index >= 0 && index < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        scrollToCenter(row: index)
    }

    public func scrollToCenter(row: Int) {
        guard row >= 0 && row < items.count else { return }
        let rowRect = tableView.rect(ofRow: row)
        let clipBounds = scrollView.contentView.bounds

        let centerY = rowRect.origin.y + (rowRect.size.height / 2.0) - (clipBounds.size.height / 2.0)
        let maxY = max(0, tableView.bounds.size.height - clipBounds.size.height)
        let targetY = max(0, min(maxY, centerY))

        let targetPoint = NSPoint(x: 0, y: targetY)
        scrollView.contentView.scroll(to: targetPoint)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    public func selectNext() {
        let current = tableView.selectedRow
        let next = min(items.count - 1, current + 1)
        if next >= 0 { selectRow(next) }
    }

    public func selectPrevious() {
        let current = tableView.selectedRow
        let prev = max(0, current - 1)
        if prev < items.count { selectRow(prev) }
    }

    public func handlePageNavigation(keyType: PageKeyType) {
        guard !items.isEmpty else { return }
        let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
        let currentRow = tableView.selectedRow

        switch keyType {
        case .pageUp:
            let pageStep = max(1, visibleRows.length - 1)
            let target = max(0, currentRow - pageStep)
            selectRow(target)
        case .pageDown:
            let pageStep = max(1, visibleRows.length - 1)
            let target = min(items.count - 1, currentRow + pageStep)
            selectRow(target)
        case .home:
            let firstIdx = items[0].type == .parentDirectory && items.count > 1 ? 1 : 0
            selectRow(firstIdx)
        case .end:
            selectRow(items.count - 1)
        }
    }

    public func reloadSelectedRow() {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow), columnIndexes: IndexSet(integer: 0))
            if let cell = tableView.view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? SidebarTableCellView,
               selectedRow < items.count {
                cell.configure(with: items[selectedRow])
            }
        }
    }

    public func updateThumbnailForSelectedItem(image: NSImage) {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0,
           let cell = tableView.view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? SidebarTableCellView {
            cell.setThumbnailLoaded(image)
        }
    }

    public func activateCurrentSelection() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return }
        delegate?.sidebar(self, didActivateItem: items[selectedRow])
    }

    // NSTableViewDataSource
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    // NSTableViewDelegate
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cellID = NSUserInterfaceItemIdentifier("SidebarCell")

        var cell = tableView.makeView(withIdentifier: cellID, owner: self) as? SidebarTableCellView
        if cell == nil {
            cell = SidebarTableCellView()
            cell?.identifier = cellID
        }

        cell?.configure(with: item)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return }
        let selectedItem = items[selectedRow]

        if let cell = tableView.view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? SidebarTableCellView {
            cell.loadThumbnailOnSelection(for: selectedItem)
        }

        delegate?.sidebar(self, didSelectItem: selectedItem)
    }

    @objc public func tableRowDoubleClicked() {
        activateCurrentSelection()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        tableView.doubleAction = #selector(tableRowDoubleClicked)
        tableView.target = self
    }
}

public enum PageKeyType {
    case pageUp
    case pageDown
    case home
    case end
}

class CustomTableView: NSTableView {
    var onEnterPressed: (() -> Void)?
    var onPageKey: ((PageKeyType) -> Void)?
    var onToggleFavoritePressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            onEnterPressed?()
            return
        case 116: // PageUp
            onPageKey?(.pageUp)
            return
        case 121: // PageDown
            onPageKey?(.pageDown)
            return
        case 115: // Home
            onPageKey?(.home)
            return
        case 119: // End
            onPageKey?(.end)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }
}

public class SidebarTableCellView: NSTableCellView {
    private let thumbnailImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let favoriteBadge = NSImageView()
    private let checkmarkBadge = NSImageView()
    private let typeBadge = NSImageView()
    private let topLeftBadgeStack = NSStackView()
    private var currentItem: FileItem?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        self.wantsLayer = true

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 6

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = NSColor.labelColor
        nameLabel.alignment = .center

        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)

        favoriteBadge.translatesAutoresizingMaskIntoConstraints = false
        favoriteBadge.imageScaling = .scaleProportionallyUpOrDown
        favoriteBadge.wantsLayer = true
        favoriteBadge.layer?.zPosition = 10
        let starImg = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")?.withSymbolConfiguration(badgeConfig)
        favoriteBadge.image = starImg
        favoriteBadge.contentTintColor = NSColor.systemYellow
        favoriteBadge.isHidden = true

        typeBadge.translatesAutoresizingMaskIntoConstraints = false
        typeBadge.imageScaling = .scaleProportionallyUpOrDown
        typeBadge.wantsLayer = true
        typeBadge.layer?.zPosition = 10
        typeBadge.isHidden = true

        checkmarkBadge.translatesAutoresizingMaskIntoConstraints = false
        checkmarkBadge.imageScaling = .scaleProportionallyUpOrDown
        checkmarkBadge.wantsLayer = true
        checkmarkBadge.layer?.zPosition = 10
        let checkImg = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Viewed")?.withSymbolConfiguration(badgeConfig)
        checkmarkBadge.image = checkImg
        checkmarkBadge.contentTintColor = NSColor.systemGreen
        checkmarkBadge.isHidden = true

        topLeftBadgeStack.translatesAutoresizingMaskIntoConstraints = false
        topLeftBadgeStack.orientation = .horizontal
        topLeftBadgeStack.spacing = 4
        topLeftBadgeStack.alignment = .centerY
        topLeftBadgeStack.wantsLayer = true
        topLeftBadgeStack.layer?.zPosition = 10

        topLeftBadgeStack.addArrangedSubview(typeBadge)
        topLeftBadgeStack.addArrangedSubview(checkmarkBadge)

        addSubview(thumbnailImageView)
        addSubview(nameLabel)
        addSubview(favoriteBadge)
        addSubview(topLeftBadgeStack)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            thumbnailImageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnailImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            favoriteBadge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            favoriteBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            favoriteBadge.widthAnchor.constraint(equalToConstant: 44),
            favoriteBadge.heightAnchor.constraint(equalToConstant: 44),

            topLeftBadgeStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            topLeftBadgeStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            topLeftBadgeStack.heightAnchor.constraint(equalToConstant: 44),

            typeBadge.widthAnchor.constraint(equalToConstant: 44),
            typeBadge.heightAnchor.constraint(equalToConstant: 44),

            checkmarkBadge.widthAnchor.constraint(equalToConstant: 44),
            checkmarkBadge.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    public func configure(with item: FileItem) {
        self.currentItem = item
        nameLabel.stringValue = item.name

        let isFav = SQLiteCache.shared.isFavorite(path: item.id) || SQLiteCache.shared.isFavorite(path: item.path)
        favoriteBadge.isHidden = !isFav

        updateTypeBadge(for: item)

        let isViewed = SQLiteCache.shared.isViewed(item: item)
        checkmarkBadge.isHidden = !isViewed

        print("[SidebarCell] configure item '\(item.name)' (id: \(item.id)), isFav: \(isFav), isViewed: \(isViewed)")

        let cacheKey = "thumb_\(item.id)_256.0x256.0"
        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            setThumbnailLoaded(cached)
            return
        }

        showFilenameTextOnly()

        let isTopLevelArchive = (item.type == .archiveZip || item.type == .archiveRar) && (item.archivePath == nil || item.archivePath?.isEmpty == true)

        if item.type == .image || item.isDirectory || ((item.type == .archiveZip || item.type == .archiveRar) && !isTopLevelArchive) {
            ThumbnailGenerator.shared.generateThumbnail(for: item) { [weak self] image in
                guard let self = self, self.currentItem?.id == item.id else { return }
                if let img = image {
                    self.setThumbnailLoaded(img)
                }
            }
        }
    }

    private func updateTypeBadge(for item: FileItem) {
        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        if item.isDirectory || item.type == .directory {
            typeBadge.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?.withSymbolConfiguration(badgeConfig)
            typeBadge.contentTintColor = NSColor.systemBlue
            typeBadge.isHidden = false
        } else if item.type == .archiveZip || item.type == .archiveRar {
            typeBadge.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive")?.withSymbolConfiguration(badgeConfig)
            typeBadge.contentTintColor = NSColor.systemOrange
            typeBadge.isHidden = false
        } else {
            typeBadge.image = nil
            typeBadge.isHidden = true
        }
    }

    public func loadThumbnailIfIdle(for item: FileItem) {
        guard currentItem?.id == item.id else { return }
        ThumbnailGenerator.shared.generateThumbnail(for: item) { [weak self] image in
            guard let self = self, self.currentItem?.id == item.id else { return }
            if let img = image {
                self.setThumbnailLoaded(img)
            }
        }
    }

    public func loadThumbnailOnSelection(for item: FileItem) {
        guard currentItem?.id == item.id else { return }

        ThumbnailGenerator.shared.generateThumbnail(for: item) { [weak self] image in
            guard let self = self, self.currentItem?.id == item.id else { return }
            if let img = image {
                self.setThumbnailLoaded(img)
            }
        }
    }

    public func setThumbnailLoaded(_ image: NSImage) {
        thumbnailImageView.image = image
        thumbnailImageView.isHidden = false
        nameLabel.isHidden = true

        let isFav = currentItem.map { SQLiteCache.shared.isFavorite(path: $0.id) || SQLiteCache.shared.isFavorite(path: $0.path) } ?? false
        favoriteBadge.isHidden = !isFav

        if let item = currentItem {
            updateTypeBadge(for: item)
        } else {
            typeBadge.isHidden = true
        }

        let isViewed = currentItem.map { SQLiteCache.shared.isViewed(item: $0) } ?? false
        checkmarkBadge.isHidden = !isViewed

        print("[SidebarCell] setThumbnailLoaded item '\(currentItem?.name ?? "")', isFav: \(isFav), isViewed: \(isViewed)")
    }

    private func showFilenameTextOnly() {
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
        nameLabel.isHidden = false
    }
}
