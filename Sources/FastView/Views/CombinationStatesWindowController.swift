import AppKit

public class CombinationStatesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = CombinationStatesWindowController()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let loadButton = NSButton(title: "Load Selected", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    private var states: [SavedCombinationState] = []

    public init() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Saved Combination States"
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = window else { return }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autoresizesSubviews = true

        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(loadAction)
        tableView.target = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NameCol"))
        nameCol.title = "Name"
        nameCol.width = 180

        let modeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ModeCol"))
        modeCol.title = "Mode"
        modeCol.width = 110

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DateCol"))
        dateCol.title = "Saved At"
        dateCol.width = 140

        let pathsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PathsCol"))
        pathsCol.title = "Items"
        pathsCol.width = 160

        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(modeCol)
        tableView.addTableColumn(dateCol)
        tableView.addTableColumn(pathsCol)

        scrollView.documentView = tableView

        loadButton.translatesAutoresizingMaskIntoConstraints = false
        loadButton.bezelStyle = .rounded
        loadButton.target = self
        loadButton.action = #selector(loadAction)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteAction)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeAction))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [deleteButton, NSView(), loadButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        window.contentView?.addSubview(scrollView)
        window.contentView?.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
            buttonStack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12),
            buttonStack.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    public func showWindowAndRefresh() {
        reloadStates()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    public func reloadStates() {
        states = CombinationStateManager.getAllSavedStates()
        tableView.reloadData()
    }

    @objc private func loadAction() {
        let row = tableView.selectedRow
        guard row >= 0 && row < states.count else { return }
        let state = states[row]

        if let window = NSApp.mainWindow ?? globalAppDelegate?.windowController?.window,
           let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.restoreCombinationState(state)
        } else if let splitVC = globalAppDelegate?.windowController?.splitVC {
            splitVC.restoreCombinationState(state)
        }
    }

    @objc private func deleteAction() {
        let row = tableView.selectedRow
        guard row >= 0 && row < states.count else { return }
        let state = states[row]
        CombinationStateManager.deleteState(id: state.id)
        reloadStates()
        globalAppDelegate?.updateRestoreCombinationMenu()
    }

    @objc private func closeAction() {
        window?.close()
    }

    // NSTableViewDataSource
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return states.count
    }

    // NSTableViewDelegate
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < states.count else { return nil }
        let state = states[row]

        let cellID = NSUserInterfaceItemIdentifier("TextCell")
        var textField = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField
        if textField == nil {
            textField = NSTextField(labelWithString: "")
            textField?.identifier = cellID
            textField?.font = NSFont.systemFont(ofSize: 12)
            textField?.lineBreakMode = .byTruncatingMiddle
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        if tableColumn?.identifier.rawValue == "NameCol" {
            textField?.stringValue = state.name
            textField?.font = NSFont.boldSystemFont(ofSize: 12)
        } else if tableColumn?.identifier.rawValue == "ModeCol" {
            textField?.stringValue = state.combiningMode
        } else if tableColumn?.identifier.rawValue == "DateCol" {
            textField?.stringValue = dateFormatter.string(from: state.savedAt)
        } else if tableColumn?.identifier.rawValue == "PathsCol" {
            let n1 = (state.itemPath1 ?? state.path1 as NSString).lastPathComponent
            let n2 = (state.itemPath2 ?? state.path2 as NSString).lastPathComponent
            textField?.stringValue = "\(n1) + \(n2)"
        }

        return textField
    }
}
