import AppKit

public protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem)
    func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem)
    func sidebarDidBecomeActive(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, didChangeSort options: ListSortOptions)
}

public class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public weak var delegate: SidebarDelegate?

    public var paneIndex: Int = 1 {
        didSet {
            sortOptions = ListSortOptions.load(pane: paneIndex)
        }
    }
    public private(set) var sortOptions = ListSortOptions.default {
        didSet {
            updateSortControls()
        }
    }
    public var isActivePane: Bool = false {
        didSet {
            updateHeaderFocusStyle()
        }
    }
    public var showHeader: Bool = false {
        didSet {
            headerContainerView.isHidden = !showHeader
            headerHeightConstraint?.constant = showHeader ? 28 : 0
        }
    }

    public private(set) var items: [FileItem] = []
    private let headerContainerView = NSView()
    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let headerAccentIndicator = NSView()
    private var headerHeightConstraint: NSLayoutConstraint?
    private let sortBarView = NSView()
    private let sortKeyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortDirectionButton = NSButton(title: "", target: nil, action: nil)
    private var isRestoringSelection = false
    private var headerTitleLeadingConstraint: NSLayoutConstraint?
    private var sortLabelLeadingConstraint: NSLayoutConstraint?
    private let headerTitleLeadingPadding: CGFloat = 6
    private let sortLabelLeadingPadding: CGFloat = 8

    private let scrollView = NSScrollView()
    private let tableView = CustomTableView()
    private var scrollDebounceTimer: Timer?
    // Thumbnails are requested only once scrolling has been quiet this long,
    // so rows that merely scroll past never start (and stop) archive reads.
    private let thumbnailRefreshDelay: TimeInterval = 0.3
    private lazy var thumbnailGroup = "sidebar-\(ObjectIdentifier(self).hashValue)"

    public var selectedItem: FileItem? {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return nil }
        return items[selectedRow]
    }

    override public func loadView() {
        self.view = NSView()
        setupUI()
    }

    public func setHeaderTitle(_ title: String) {
        headerTitleLabel.stringValue = "Pane \(paneIndex): \(title)"
    }

    private func updateHeaderFocusStyle() {
        view.wantsLayer = true
        if isActivePane {
            headerContainerView.wantsLayer = true
            headerContainerView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            headerAccentIndicator.wantsLayer = true
            headerAccentIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            headerTitleLabel.font = NSFont.boldSystemFont(ofSize: 11)
            headerTitleLabel.textColor = NSColor.labelColor
        } else {
            headerContainerView.wantsLayer = true
            headerContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
            headerAccentIndicator.wantsLayer = true
            headerAccentIndicator.layer?.backgroundColor = NSColor.clear.cgColor
            headerTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            headerTitleLabel.textColor = NSColor.secondaryLabelColor
        }
    }

    private func setupSortBar() {
        sortBarView.translatesAutoresizingMaskIntoConstraints = false
        sortBarView.wantsLayer = true
        sortBarView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor

        let sortLabel = NSTextField(labelWithString: "Sort:")
        sortLabel.translatesAutoresizingMaskIntoConstraints = false
        sortLabel.font = NSFont.systemFont(ofSize: 11)
        sortLabel.textColor = NSColor.secondaryLabelColor

        sortKeyPopUp.translatesAutoresizingMaskIntoConstraints = false
        sortKeyPopUp.controlSize = .small
        sortKeyPopUp.font = NSFont.systemFont(ofSize: 11)
        for key in ListSortKey.allCases {
            sortKeyPopUp.addItem(withTitle: key.title)
            sortKeyPopUp.lastItem?.representedObject = key.rawValue
        }
        sortKeyPopUp.target = self
        sortKeyPopUp.action = #selector(sortKeyChanged(_:))
        sortKeyPopUp.refusesFirstResponder = true

        sortDirectionButton.translatesAutoresizingMaskIntoConstraints = false
        sortDirectionButton.bezelStyle = .recessed
        sortDirectionButton.controlSize = .small
        sortDirectionButton.font = NSFont.systemFont(ofSize: 11)
        sortDirectionButton.imagePosition = .imageLeading
        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(sortDirectionToggled(_:))
        sortDirectionButton.refusesFirstResponder = true
        sortDirectionButton.toolTip = "Reverse sort order"

        sortBarView.addSubview(sortLabel)
        sortBarView.addSubview(sortKeyPopUp)
        sortBarView.addSubview(sortDirectionButton)

        let sortLabelLeading = sortLabel.leadingAnchor.constraint(equalTo: sortBarView.leadingAnchor, constant: sortLabelLeadingPadding)
        sortLabelLeadingConstraint = sortLabelLeading

        NSLayoutConstraint.activate([
            sortLabelLeading,
            sortLabel.centerYAnchor.constraint(equalTo: sortBarView.centerYAnchor),

            sortKeyPopUp.leadingAnchor.constraint(equalTo: sortLabel.trailingAnchor, constant: 4),
            sortKeyPopUp.centerYAnchor.constraint(equalTo: sortBarView.centerYAnchor),

            sortDirectionButton.leadingAnchor.constraint(equalTo: sortKeyPopUp.trailingAnchor, constant: 6),
            sortDirectionButton.trailingAnchor.constraint(lessThanOrEqualTo: sortBarView.trailingAnchor, constant: -6),
            sortDirectionButton.centerYAnchor.constraint(equalTo: sortBarView.centerYAnchor)
        ])

        updateSortControls()
    }

    private func updateSortControls() {
        guard isViewLoaded else { return }
        sortKeyPopUp.selectItem(withTitle: sortOptions.key.title)
        sortDirectionButton.title = sortOptions.directionTitle
        let symbol = sortOptions.ascending ? "arrow.up" : "arrow.down"
        sortDirectionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: sortOptions.directionTitle)
    }

    @objc private func sortKeyChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let key = ListSortKey(rawValue: raw),
              key != sortOptions.key else { return }
        // Name reads A→Z; the others start with what is most useful on top:
        // newest, favorites, viewed.
        applySortOptions(ListSortOptions(key: key, ascending: key == .name))
    }

    @objc private func sortDirectionToggled(_ sender: NSButton) {
        applySortOptions(ListSortOptions(key: sortOptions.key, ascending: !sortOptions.ascending))
    }

    private func applySortOptions(_ options: ListSortOptions) {
        sortOptions = options
        options.save(pane: paneIndex)
        delegate?.sidebar(self, didChangeSort: options)
    }

    private func setupUI() {
        setupSortBar()

        headerContainerView.translatesAutoresizingMaskIntoConstraints = false
        headerContainerView.wantsLayer = true
        headerContainerView.isHidden = true

        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        headerTitleLabel.textColor = NSColor.secondaryLabelColor
        headerTitleLabel.lineBreakMode = .byTruncatingMiddle

        headerAccentIndicator.translatesAutoresizingMaskIntoConstraints = false

        headerContainerView.addSubview(headerAccentIndicator)
        headerContainerView.addSubview(headerTitleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autoresizesSubviews = true

        tableView.headerView = nil
        tableView.rowHeight = 120
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onFocusGained = { [weak self] in
            guard let self = self else { return }
            self.delegate?.sidebarDidBecomeActive(self)
        }
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
        tableView.onContextToggleFavorite = { [weak self] row in
            guard let self = self, row >= 0 && row < self.items.count else { return }
            let item = self.items[row]
            _ = SQLiteCache.shared.toggleFavorite(item: item)
            self.reloadSelectedRow()
            if let splitVC = (self.parent as? SidebarContainerViewController)?.parent as? MainSplitViewController {
                if (self.paneIndex == 1 && splitVC.showFavoritesOnly) || (self.paneIndex == 2 && splitVC.showFavoritesOnlyPane2) {
                    splitVC.reloadDirectoryContentsPublic()
                }
            }
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        view.addSubview(headerContainerView)
        view.addSubview(sortBarView)
        view.addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let hHeight = headerContainerView.heightAnchor.constraint(equalToConstant: 0)
        self.headerHeightConstraint = hHeight
        let titleLeading = headerTitleLabel.leadingAnchor.constraint(equalTo: headerAccentIndicator.trailingAnchor, constant: headerTitleLeadingPadding)
        self.headerTitleLeadingConstraint = titleLeading

        NSLayoutConstraint.activate([
            headerContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hHeight,

            headerAccentIndicator.leadingAnchor.constraint(equalTo: headerContainerView.leadingAnchor),
            headerAccentIndicator.topAnchor.constraint(equalTo: headerContainerView.topAnchor),
            headerAccentIndicator.bottomAnchor.constraint(equalTo: headerContainerView.bottomAnchor),
            headerAccentIndicator.widthAnchor.constraint(equalToConstant: 4),

            titleLeading,
            headerTitleLabel.trailingAnchor.constraint(equalTo: headerContainerView.trailingAnchor, constant: -6),
            headerTitleLabel.centerYAnchor.constraint(equalTo: headerContainerView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sortBarView.topAnchor.constraint(equalTo: headerContainerView.bottomAnchor),
            sortBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sortBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sortBarView.heightAnchor.constraint(equalToConstant: 26),

            scrollView.topAnchor.constraint(equalTo: sortBarView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        updateHeaderFocusStyle()
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        scheduleThumbnailRefresh()
    }

    private func scheduleThumbnailRefresh() {
        scrollDebounceTimer?.invalidate()
        scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: thumbnailRefreshDelay, repeats: false) { [weak self] _ in
            self?.loadVisibleThumbnailsIfIdle()
        }
    }

    /// The window has a transparent, full-size title bar, so the pane at
    /// the top left lies under the close/minimize/zoom buttons; its top bar
    /// starts after them.
    private func updateWindowControlsInsets() {
        let titleInset = windowControlsInset(for: headerContainerView)
        let sortInset = windowControlsInset(for: sortBarView)
        if headerTitleLeadingConstraint?.constant != headerTitleLeadingPadding + titleInset {
            headerTitleLeadingConstraint?.constant = headerTitleLeadingPadding + titleInset
        }
        if sortLabelLeadingConstraint?.constant != sortLabelLeadingPadding + sortInset {
            sortLabelLeadingConstraint?.constant = sortLabelLeadingPadding + sortInset
        }
    }

    private func windowControlsInset(for bar: NSView) -> CGFloat {
        guard let window = view.window, !bar.isHidden, bar.frame.height > 0,
              let zoomButton = window.standardWindowButton(.zoomButton),
              zoomButton.window === window, !zoomButton.isHidden,
              let buttonsContainer = zoomButton.superview else { return 0 }
        let buttons = buttonsContainer.convert(zoomButton.frame, to: nil)
        let barRect = bar.convert(bar.bounds, to: nil)
        guard barRect.minY < buttons.maxY, barRect.maxY > buttons.minY, barRect.minX < buttons.maxX else { return 0 }
        return buttons.maxX - barRect.minX
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        updateWindowControlsInsets()
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
        // One query for the whole list instead of one per configured row.
        _ = SQLiteCache.shared.getViewedCount(keys: items.filter { $0.type == .image }.map(SidebarTableCellView.viewedKey))
        tableView.reloadData()

        if selectFirst && !items.isEmpty {
            let defaultIndex = items.count > 1 && items[0].type == .parentDirectory ? 1 : 0
            selectRow(defaultIndex)
        }
    }

    /// Shows the same items in a new order, keeping the selected item
    /// selected without reporting it as a new selection.
    public func setReorderedItems(_ items: [FileItem]) {
        let selectedID = selectedItem?.id
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        self.items = items
        tableView.reloadData()
        if let id = selectedID, let index = items.firstIndex(where: { $0.id == id }) {
            selectRow(index)
        } else {
            tableView.deselectAll(nil)
        }
        loadVisibleThumbnailsIfIdle()
    }

    /// Drops thumbnail work for rows that are no longer visible (killing a
    /// running archive read) and requests the visible rows, top to bottom.
    /// Work for rows that stayed visible keeps running.
    public func loadVisibleThumbnailsIfIdle() {
        let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
        let rows = (visibleRows.location..<NSMaxRange(visibleRows)).filter { $0 >= 0 && $0 < items.count }

        ThumbnailGenerator.shared.cancelThumbnailTasks(inGroup: thumbnailGroup, keeping: Set(rows.map { items[$0].id }))

        for row in rows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTableCellView {
                cell.loadThumbnailIfIdle(for: items[row], group: thumbnailGroup)
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

    public func refreshStatsForSelectedItem() {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0,
           let cell = tableView.view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? SidebarTableCellView {
            cell.refreshStats()
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
        // Thumbnails for newly shown rows are requested once scrolling settles.
        scheduleThumbnailRefresh()
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return }
        let selectedItem = items[selectedRow]
        if isRestoringSelection { return }

        if let cell = tableView.view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? SidebarTableCellView {
            cell.loadThumbnailOnSelection(for: selectedItem, group: thumbnailGroup)
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

    deinit {
        cleanup()
    }

    public func cleanup() {
        NotificationCenter.default.removeObserver(self)
        scrollDebounceTimer?.invalidate()
        scrollDebounceTimer = nil
    }
}

public enum PageKeyType {
    case pageUp
    case pageDown
    case home
    case end
}

class CustomTableView: NSTableView {
    var onFocusGained: (() -> Void)?
    var onEnterPressed: (() -> Void)?
    var onPageKey: ((PageKeyType) -> Void)?
    var onToggleFavoritePressed: (() -> Void)?
    var onContextToggleFavorite: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 && clickedRow < numberOfRows else { return nil }

        if !isRowSelected(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let menu = NSMenu(title: "Context Menu")

        if let vc = delegate as? SidebarViewController, clickedRow < vc.items.count {
            let item = vc.items[clickedRow]
            let isFav = SQLiteCache.shared.isFavorite(path: item.id) || SQLiteCache.shared.isFavorite(path: item.path)
            let favTitle = isFav ? "Remove Favorite" : "Add Favorite"
            let favMenuItem = NSMenuItem(title: favTitle, action: #selector(contextToggleFavoriteAction(_:)), keyEquivalent: "")
            favMenuItem.target = self
            favMenuItem.representedObject = clickedRow
            menu.addItem(favMenuItem)

            menu.addItem(NSMenuItem.separator())

            if item.type == .image {
                let addObjectItem = NSMenuItem(title: "Add Object to Canvas", action: #selector(contextAddObjectToCanvasAction(_:)), keyEquivalent: "")
                addObjectItem.target = self
                addObjectItem.representedObject = item
                menu.addItem(addObjectItem)

                menu.addItem(NSMenuItem.separator())
            }

            let infoItem = NSMenuItem(title: "Show Info", action: #selector(contextShowInfoAction(_:)), keyEquivalent: "")
            infoItem.target = self
            infoItem.representedObject = clickedRow
            menu.addItem(infoItem)

            menu.addItem(NSMenuItem.separator())

            let copyImageItem = NSMenuItem(title: "Copy Image to Clipboard", action: #selector(contextCopyImageAction(_:)), keyEquivalent: "")
            copyImageItem.target = self
            copyImageItem.representedObject = item
            menu.addItem(copyImageItem)

            let copyItem = NSMenuItem(title: "Copy File Path", action: #selector(contextCopyPathAction(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = item.path
            menu.addItem(copyItem)
        }

        return menu
    }

    @objc private func contextAddObjectToCanvasAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem,
              let vc = delegate as? SidebarViewController else { return }
        let splitVC = (vc.parent as? MainSplitViewController)
            ?? ((vc.parent as? SidebarContainerViewController)?.parent as? MainSplitViewController)
        splitVC?.addObjectToCanvas(from: item)
    }

    @objc private func contextToggleFavoriteAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        onContextToggleFavorite?(row)
    }

    @objc private func contextShowInfoAction(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
              let vc = delegate as? SidebarViewController,
              row >= 0 && row < vc.items.count else { return }
        let item = vc.items[row]
        if let mainSplitVC = vc.parent as? MainSplitViewController {
            mainSplitVC.showInfo(for: item)
        } else if let container = vc.parent as? SidebarContainerViewController,
                  let mainSplitVC = container.parent as? MainSplitViewController {
            mainSplitVC.showInfo(for: item)
        }
    }

    @objc private func contextCopyImageAction(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        ThumbnailGenerator.shared.loadFullImage(for: item) { image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.copyImage(image)
            }
        }
    }

    @objc private func contextCopyPathAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        onFocusGained?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusGained?()
        }
        return result
    }

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
    private let typeBadge = NSImageView()
    private let statsBadgeContainer = NSView()
    private let statsBadgeLabel = NSTextField(labelWithString: "")
    private let favoriteCountContainer = NSView()
    private let favoriteCountLabel = NSTextField(labelWithString: "")
    private let archiveNameContainer = NSView()
    private let archiveNameLabel = NSTextField(labelWithString: "")
    private var currentItem: FileItem?
    private var isViewed = false

    /// Muted green behind viewed images; light enough to keep thumbnails and
    /// badges the focus.  `systemGreen` adapts to light and dark mode.
    private static let viewedTint = NSColor.systemGreen.withAlphaComponent(0.16)

    /// The viewed-images key of an image row.
    static func viewedKey(for item: FileItem) -> String {
        item.archivePath.map { "\($0)#\(item.id)" } ?? item.id
    }

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
        layer?.cornerRadius = 6

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

        favoriteBadge.translatesAutoresizingMaskIntoConstraints = false
        favoriteBadge.wantsLayer = true
        favoriteBadge.layer?.zPosition = 10
        let starConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        let starImg = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")?.withSymbolConfiguration(starConfig)
        favoriteBadge.image = starImg
        favoriteBadge.imageScaling = .scaleProportionallyUpOrDown
        favoriteBadge.contentTintColor = NSColor.systemYellow
        favoriteBadge.isHidden = true

        typeBadge.translatesAutoresizingMaskIntoConstraints = false
        typeBadge.wantsLayer = true
        typeBadge.layer?.zPosition = 10
        typeBadge.imageScaling = .scaleProportionallyUpOrDown
        typeBadge.contentTintColor = NSColor.controlAccentColor
        typeBadge.isHidden = true

        statsBadgeContainer.translatesAutoresizingMaskIntoConstraints = false
        statsBadgeContainer.wantsLayer = true
        statsBadgeContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        statsBadgeContainer.layer?.cornerRadius = 4
        statsBadgeContainer.layer?.zPosition = 10
        statsBadgeContainer.isHidden = true

        statsBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        statsBadgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        statsBadgeLabel.textColor = NSColor.white
        statsBadgeLabel.alignment = .center

        statsBadgeContainer.addSubview(statsBadgeLabel)

        favoriteCountContainer.translatesAutoresizingMaskIntoConstraints = false
        favoriteCountContainer.wantsLayer = true
        favoriteCountContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        favoriteCountContainer.layer?.cornerRadius = 4
        favoriteCountContainer.layer?.zPosition = 10
        favoriteCountContainer.isHidden = true

        favoriteCountLabel.translatesAutoresizingMaskIntoConstraints = false
        favoriteCountLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        favoriteCountLabel.textColor = NSColor.systemYellow
        favoriteCountLabel.alignment = .center

        favoriteCountContainer.addSubview(favoriteCountLabel)

        archiveNameContainer.translatesAutoresizingMaskIntoConstraints = false
        archiveNameContainer.wantsLayer = true
        archiveNameContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        archiveNameContainer.layer?.cornerRadius = 4
        archiveNameContainer.layer?.zPosition = 10
        archiveNameContainer.isHidden = true

        archiveNameLabel.translatesAutoresizingMaskIntoConstraints = false
        archiveNameLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        archiveNameLabel.textColor = NSColor.white
        archiveNameLabel.lineBreakMode = .byTruncatingMiddle
        archiveNameLabel.maximumNumberOfLines = 1

        archiveNameContainer.addSubview(archiveNameLabel)

        addSubview(thumbnailImageView)
        addSubview(nameLabel)
        addSubview(typeBadge)
        addSubview(favoriteBadge)
        addSubview(statsBadgeContainer)
        addSubview(archiveNameContainer)
        addSubview(favoriteCountContainer)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnailImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            thumbnailImageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnailImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            typeBadge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            typeBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            typeBadge.widthAnchor.constraint(equalToConstant: 44),
            typeBadge.heightAnchor.constraint(equalToConstant: 44),

            favoriteBadge.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            favoriteBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            favoriteBadge.widthAnchor.constraint(equalToConstant: 44),
            favoriteBadge.heightAnchor.constraint(equalToConstant: 44),

            statsBadgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statsBadgeContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            statsBadgeLabel.leadingAnchor.constraint(equalTo: statsBadgeContainer.leadingAnchor, constant: 5),
            statsBadgeLabel.trailingAnchor.constraint(equalTo: statsBadgeContainer.trailingAnchor, constant: -5),
            statsBadgeLabel.topAnchor.constraint(equalTo: statsBadgeContainer.topAnchor, constant: 2),
            statsBadgeLabel.bottomAnchor.constraint(equalTo: statsBadgeContainer.bottomAnchor, constant: -2),

            archiveNameContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            archiveNameContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            archiveNameContainer.trailingAnchor.constraint(lessThanOrEqualTo: statsBadgeContainer.leadingAnchor, constant: -8),

            archiveNameLabel.leadingAnchor.constraint(equalTo: archiveNameContainer.leadingAnchor, constant: 5),
            archiveNameLabel.trailingAnchor.constraint(equalTo: archiveNameContainer.trailingAnchor, constant: -5),
            archiveNameLabel.topAnchor.constraint(equalTo: archiveNameContainer.topAnchor, constant: 2),
            archiveNameLabel.bottomAnchor.constraint(equalTo: archiveNameContainer.bottomAnchor, constant: -2),

            favoriteCountContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            favoriteCountContainer.bottomAnchor.constraint(equalTo: archiveNameContainer.topAnchor, constant: -4),

            favoriteCountLabel.leadingAnchor.constraint(equalTo: favoriteCountContainer.leadingAnchor, constant: 5),
            favoriteCountLabel.trailingAnchor.constraint(equalTo: favoriteCountContainer.trailingAnchor, constant: -5),
            favoriteCountLabel.topAnchor.constraint(equalTo: favoriteCountContainer.topAnchor, constant: 2),
            favoriteCountLabel.bottomAnchor.constraint(equalTo: favoriteCountContainer.bottomAnchor, constant: -2)
        ])
    }

    public func configure(with item: FileItem) {
        self.currentItem = item
        nameLabel.stringValue = item.name

        let badgeConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        if item.isDirectory || item.type == .parentDirectory {
            typeBadge.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")?.withSymbolConfiguration(badgeConfig)
            typeBadge.isHidden = false
        } else if item.type == .archiveZip || item.type == .archiveRar {
            typeBadge.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive")?.withSymbolConfiguration(badgeConfig)
            typeBadge.isHidden = false
        } else {
            typeBadge.isHidden = true
        }

        if item.type == .archiveZip || item.type == .archiveRar {
            archiveNameLabel.stringValue = item.name
            archiveNameContainer.isHidden = false
        } else {
            archiveNameContainer.isHidden = true
        }

        if let stats = FolderStatsCalculator.cachedStats(for: item) {
            applyStats(stats)
        } else {
            statsBadgeContainer.isHidden = true
            favoriteCountContainer.isHidden = true
        }

        let isFav = SQLiteCache.shared.isFavorite(path: item.id) || SQLiteCache.shared.isFavorite(path: item.path)
        favoriteBadge.isHidden = !isFav
        updateViewedState()

        let cacheKey = "thumb_\(item.id)_256.0x256.0"
        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            setThumbnailLoaded(cached)
            return
        }

        // Generating a missing thumbnail is left to the sidebar's debounced
        // refresh, so scrolling past a row never starts work for it.
        showFilenameTextOnly()
    }

    public func loadThumbnailIfIdle(for item: FileItem, group: String) {
        guard currentItem?.id == item.id else { return }
        ThumbnailGenerator.shared.generateThumbnailWithStats(for: item, group: group) { [weak self] image, stats in
            DispatchQueue.main.async {
                guard let self = self, self.currentItem?.id == item.id else { return }
                if let img = image {
                    self.setThumbnailLoaded(img)
                }
                if let stats = stats {
                    self.applyStats(stats)
                }
            }
        }
    }

    public func loadThumbnailOnSelection(for item: FileItem, group: String) {
        guard currentItem?.id == item.id else { return }

        let cacheKey = "thumb_\(item.id)_256.0x256.0"
        if (item.type == .archiveZip || item.type == .archiveRar) && MemoryLRUCache.shared.object(forKey: cacheKey) == nil {
            FolderStatsCalculator.cancelPendingCountCalculations()
        }

        ThumbnailGenerator.shared.generateThumbnailWithStats(for: item, group: group) { [weak self] image, stats in
            DispatchQueue.main.async {
                guard let self = self, self.currentItem?.id == item.id else { return }
                if let img = image {
                    self.setThumbnailLoaded(img)
                }
                if let stats = stats {
                    self.applyStats(stats)
                }
            }
        }
    }

    public func refreshStats() {
        guard let item = currentItem, let stats = FolderStatsCalculator.cachedStats(for: item) else { return }
        applyStats(stats)
    }

    private func applyStats(_ stats: FolderStats) {
        if !stats.badgeString.isEmpty {
            statsBadgeLabel.stringValue = stats.badgeString
            statsBadgeContainer.isHidden = false
        } else {
            statsBadgeContainer.isHidden = true
        }
        if !stats.favoriteBadgeString.isEmpty {
            favoriteCountLabel.stringValue = stats.favoriteBadgeString
            favoriteCountContainer.isHidden = false
        } else {
            favoriteCountContainer.isHidden = true
        }
    }

    public func setThumbnailLoaded(_ image: NSImage) {
        thumbnailImageView.image = image
        thumbnailImageView.isHidden = false
        nameLabel.isHidden = true

        let isFav = currentItem.map { SQLiteCache.shared.isFavorite(path: $0.id) || SQLiteCache.shared.isFavorite(path: $0.path) } ?? false
        favoriteBadge.isHidden = !isFav
        // The selected image is marked viewed just before its image is set.
        updateViewedState()
    }

    private func updateViewedState() {
        isViewed = currentItem.map { $0.type == .image && SQLiteCache.shared.isImageViewed(key: Self.viewedKey(for: $0)) } ?? false
        updateViewedBackground()
    }

    // Selected rows keep the plain selection highlight.
    override public var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateViewedBackground() }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateViewedBackground()
    }

    private func updateViewedBackground() {
        let isSelected = (superview as? NSTableRowView)?.isSelected ?? false
        let tinted = isViewed && !isSelected && backgroundStyle != .emphasized
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tinted ? Self.viewedTint.cgColor : nil
        }
    }

    private func showFilenameTextOnly() {
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
        nameLabel.isHidden = false
    }
}
