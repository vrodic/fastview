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
        tableView.rowHeight = 96
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onEnterPressed = { [weak self] in
            self?.activateCurrentSelection()
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
        loadVisibleThumbnailsIfIdle()
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
        guard !ThumbnailGenerator.shared.isLoadingMainImage else { return }
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
        tableView.scrollRowToVisible(index)
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

    public func reloadSelectedRow() {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow), columnIndexes: IndexSet(integer: 0))
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

class CustomTableView: NSTableView {
    var onEnterPressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Return / Enter
            onEnterPressed?()
            return
        }
        super.keyDown(with: event)
    }
}

public class SidebarTableCellView: NSTableCellView {
    private let thumbnailImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let favoriteBadge = NSImageView()
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
        favoriteBadge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")
        favoriteBadge.contentTintColor = NSColor.systemYellow
        favoriteBadge.isHidden = true

        addSubview(thumbnailImageView)
        addSubview(nameLabel)
        addSubview(favoriteBadge)

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
            favoriteBadge.widthAnchor.constraint(equalToConstant: 20),
            favoriteBadge.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    public func configure(with item: FileItem) {
        self.currentItem = item
        nameLabel.stringValue = item.name

        let isFav = SQLiteCache.shared.isFavorite(path: item.path)
        favoriteBadge.isHidden = !isFav

        let cacheKey = "thumb_\(item.id)_256.0x256.0"
        if let cached = MemoryLRUCache.shared.object(forKey: cacheKey) {
            setThumbnailLoaded(cached)
            return
        }

        showFilenameTextOnly()
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
    }

    private func showFilenameTextOnly() {
        thumbnailImageView.image = nil
        thumbnailImageView.isHidden = true
        nameLabel.isHidden = false
    }
}
