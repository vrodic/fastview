import AppKit

public class CombinationStatesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    public static let shared = CombinationStatesWindowController()

    private static let restoreOnSelectKey = "FastViewCombinationRestoreOnSelect"

    private let tableView = CombinationTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let restoreOnSelectCheckbox = NSButton(checkboxWithTitle: "Restore on select", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let trashButton = NSButton(title: "Move to Trash", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var allStates: [SavedCombinationSummary] = []
    private var states: [SavedCombinationSummary] = []
    private var isReselecting = false

    private var previewCache: [String: NSImage] = [:]
    private var previewsLoading: Set<String> = []
    private let previewQueue = DispatchQueue(label: "FastView.CombinationPreviews", qos: .utility)

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Saved Combinations"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)
        panel.setFrameAutosaveName("FastViewSavedCombinations")
        if !panel.setFrameUsingName("FastViewSavedCombinations") {
            panel.center()
        }

        super.init(window: panel)
        setupUI()
        NotificationCenter.default.addObserver(forName: CombinationStateManager.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadStates()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        searchField.placeholderString = "Search by name or image"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        restoreOnSelectCheckbox.target = self
        restoreOnSelectCheckbox.action = #selector(restoreOnSelectToggled(_:))
        restoreOnSelectCheckbox.state = restoreOnSelect ? .on : .off
        restoreOnSelectCheckbox.toolTip = "Restore each combination as soon as it is selected, so the arrow keys step through them."

        let topBar = NSStackView(views: [searchField, restoreOnSelectCheckbox])
        topBar.orientation = .horizontal
        topBar.spacing = 12
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Combination"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 78
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(restoreAction)
        tableView.onReturn = { [weak self] in self?.restoreAction() }
        tableView.onDelete = { [weak self] in self?.trashAction() }

        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(restoreButton, #selector(restoreAction)), (renameButton, #selector(renameAction)),
                                 (revealButton, #selector(revealAction)), (trashButton, #selector(trashAction))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        restoreButton.keyEquivalent = "\r"

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: 11)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomBar = NSStackView(views: [revealButton, trashButton, spacer, countLabel, renameButton, restoreButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(topBar)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyLabel)
        contentView.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -60),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private var restoreOnSelect: Bool {
        UserDefaults.standard.object(forKey: Self.restoreOnSelectKey) as? Bool ?? true
    }

    public func showWindowAndRefresh() {
        reloadStates()
        CombinationStateManager.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(tableView)
    }

    public func reloadStates() {
        allStates = CombinationStateManager.summaries
        applyFilter()
    }

    private func applyFilter() {
        let selectedURL = selectedState?.url
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            states = allStates
        } else {
            states = allStates.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.itemNames.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
        if let url = selectedURL, let row = states.firstIndex(where: { $0.url == url }) {
            isReselecting = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isReselecting = false
        }
        updateChrome()
    }

    private func updateChrome() {
        let hasSelection = selectedState != nil
        restoreButton.isEnabled = hasSelection
        renameButton.isEnabled = hasSelection
        trashButton.isEnabled = hasSelection
        revealButton.isEnabled = true

        if allStates.isEmpty {
            emptyLabel.stringValue = "No saved combinations yet.\nUse File ▸ Save Combination State… (⌘S) in dual view."
        } else if states.isEmpty {
            emptyLabel.stringValue = "No combinations match “\(searchField.stringValue)”."
        }
        emptyLabel.isHidden = !states.isEmpty

        if allStates.count == states.count {
            countLabel.stringValue = allStates.count == 1 ? "1 combination" : "\(allStates.count) combinations"
        } else {
            countLabel.stringValue = "\(states.count) of \(allStates.count)"
        }
    }

    private var selectedState: SavedCombinationSummary? {
        let row = tableView.selectedRow
        return row >= 0 && row < states.count ? states[row] : nil
    }

    /// The row a context menu was opened on, else the selection.
    private var targetState: SavedCombinationSummary? {
        let row = tableView.clickedRow
        if row >= 0 && row < states.count { return states[row] }
        return selectedState
    }

    // MARK: - Actions

    @objc private func restoreOnSelectToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.restoreOnSelectKey)
    }

    @objc private func restoreAction() {
        guard let state = targetState else { return }
        restore(state)
    }

    private func restore(_ state: SavedCombinationSummary) {
        if let window = NSApp.mainWindow ?? globalAppDelegate?.windowController?.window,
           let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.restoreCombinationState(from: state.url)
        } else if let splitVC = globalAppDelegate?.windowController?.splitVC {
            splitVC.restoreCombinationState(from: state.url)
        }
    }

    @objc private func renameAction() {
        guard let state = targetState, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Combination"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = state.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != state.name else { return }
            CombinationStateManager.rename(state.url, to: newName) { [weak self] result in
                if case .failure(let error) = result, let window = self?.window {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func revealAction() {
        if let state = targetState {
            NSWorkspace.shared.activateFileViewerSelecting([state.url])
        } else {
            let dir = CombinationStateManager.directory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    @objc private func trashAction() {
        guard let state = targetState else { return }
        CombinationStateManager.delete(state.url)
    }

    // MARK: - NSSearchFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tableView.clickedRow >= 0 else { return }
        menu.addItem(withTitle: "Restore", action: #selector(restoreAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rename…", action: #selector(renameAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealAction), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashAction), keyEquivalent: "").target = self
    }

    // MARK: - NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return states.count
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateChrome()
        guard !isReselecting, restoreOnSelect, let state = selectedState else { return }
        restore(state)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < states.count else { return nil }
        let state = states[row]

        let cellID = NSUserInterfaceItemIdentifier("CombinationCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? CombinationCellView) ?? {
            let c = CombinationCellView()
            c.identifier = cellID
            return c
        }()

        cell.nameLabel.stringValue = state.name
        cell.itemsLabel.stringValue = state.itemNames
        var meta = [state.combiningMode]
        if state.objectCount > 0 {
            meta.append(state.objectCount == 1 ? "1 object" : "\(state.objectCount) objects")
        }
        meta.append(Self.relativeFormatter.localizedString(for: state.savedAt, relativeTo: Date()))
        cell.metaLabel.stringValue = meta.joined(separator: " · ")
        cell.metaLabel.toolTip = Self.dateFormatter.string(from: state.savedAt)
        cell.toolTip = state.url.path

        cell.warningView.isHidden = state.missingSources.isEmpty
        cell.warningView.toolTip = state.missingSources.isEmpty ? nil
            : "Missing:\n" + state.missingSources.joined(separator: "\n")

        cell.setPreview(preview(for: state))
        return cell
    }

    // MARK: - Previews

    private func previewKey(_ state: SavedCombinationSummary) -> String {
        "\(state.id)-\(state.savedAt.timeIntervalSince1970)"
    }

    private func preview(for state: SavedCombinationSummary) -> NSImage? {
        let key = previewKey(state)
        if let cached = previewCache[key] { return cached }
        guard !previewsLoading.contains(key) else { return nil }
        previewsLoading.insert(key)
        let url = CombinationStateManager.previewURL(forId: state.id)
        previewQueue.async { [weak self] in
            // Previews are saved large; rows need only a small one.
            let image = CombinationStateManager.decodedImage(at: url, maxPixelSize: 240)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.previewsLoading.remove(key)
                guard let image = image else { return }
                self.previewCache[key] = image
                if let row = self.states.firstIndex(where: { self.previewKey($0) == key }),
                   let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CombinationCellView {
                    cell.setPreview(image)
                }
            }
        }
        return nil
    }
}

/// Table that turns Return into restore and Delete into Move to Trash.
private final class CombinationTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()          // Return, Enter
        case 51, 117: onDelete?()         // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

private final class CombinationCellView: NSTableCellView {
    let previewView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let itemsLabel = NSTextField(labelWithString: "")
    let metaLabel = NSTextField(labelWithString: "")
    let warningView = NSImageView()

    private static let placeholder: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        return NSImage(systemSymbolName: "square.on.square.dashed", accessibilityDescription: "No preview")?
            .withSymbolConfiguration(config)
    }()

    init() {
        super.init(frame: .zero)

        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.contentTintColor = .tertiaryLabelColor
        previewView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        itemsLabel.font = NSFont.systemFont(ofSize: 11)
        itemsLabel.textColor = .secondaryLabelColor
        itemsLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        for label in [nameLabel, itemsLabel, metaLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Missing source")?
            .withSymbolConfiguration(config)
        warningView.contentTintColor = .systemOrange
        warningView.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, warningView])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6

        let textStack = NSStackView(views: [nameRow, itemsLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            previewView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 112),
            previewView.heightAnchor.constraint(equalToConstant: 66),

            textStack.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPreview(_ image: NSImage?) {
        if let image = image {
            previewView.image = image
            previewView.imageScaling = .scaleProportionallyUpOrDown
        } else {
            previewView.image = Self.placeholder
            previewView.imageScaling = .scaleNone
        }
    }
}
