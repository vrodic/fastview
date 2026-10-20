import AppKit

public protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem)
    func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem)
}

public class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public weak var delegate: SidebarDelegate?

    public private(set) var items: [FileItem] = []
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

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
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    public func setItems(_ items: [FileItem], selectFirst: Bool = true) {
        self.items = items
        tableView.reloadData()

        if selectFirst && !items.isEmpty {
            // If the first item is `(..)`, select second if present, or first
            let defaultIndex = items.count > 1 && items[0].type == .parentDirectory ? 1 : 0
            selectRow(defaultIndex)
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
        delegate?.sidebar(self, didSelectItem: items[selectedRow])
    }

    @objc public func tableRowDoubleClicked() {
        let selectedRow = tableView.clickedRow
        guard selectedRow >= 0 && selectedRow < items.count else { return }
        delegate?.sidebar(self, didActivateItem: items[selectedRow])
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        tableView.doubleAction = #selector(tableRowDoubleClicked)
        tableView.target = self
    }
}

public class SidebarTableCellView: NSTableCellView {
    private let thumbnailImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

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
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 4

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = NSFont.systemFont(ofSize: 13)

        addSubview(thumbnailImageView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnailImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailImageView.widthAnchor.constraint(equalToConstant: 48),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    public func configure(with item: FileItem) {
        titleLabel.stringValue = item.name

        if item.type == .parentDirectory {
            thumbnailImageView.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Parent")
        } else if item.type == .directory {
            thumbnailImageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        } else if item.type == .archiveZip || item.type == .archiveRar {
            thumbnailImageView.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive")
        } else {
            thumbnailImageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")
        }

        // Asynchronously load thumbnail image
        ThumbnailGenerator.shared.generateThumbnail(for: item) { [weak self] image in
            if let img = image {
                self?.thumbnailImageView.image = img
            }
        }
    }
}
