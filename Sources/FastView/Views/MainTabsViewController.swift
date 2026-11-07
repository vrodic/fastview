import AppKit

/// The window's content: the browser (`MainSplitViewController`) and, once
/// opened, the Favorites tab (`FavoritesViewController`).  The tab bar shows
/// only while there is more than one tab, so closing the Favorites tab gives
/// its space back.
public final class MainTabsViewController: NSViewController {
    public enum Tab { case browser, favorites }

    public let splitVC = MainSplitViewController()
    public private(set) var favoritesVC: FavoritesViewController?
    public private(set) var selectedTab: Tab = .browser

    private let tabBar = MainTabBarView()
    private let contentView = NSView()
    private var tabBarHeightConstraint: NSLayoutConstraint?
    private static let tabBarHeight: CGFloat = 30

    public var isFavoritesTabOpen: Bool { favoritesVC != nil }
    /// The favorites grid, while its tab is the one shown.
    public var activeFavoritesVC: FavoritesViewController? {
        selectedTab == .favorites ? favoritesVC : nil
    }

    override public func loadView() {
        let dropView = FileDropView()
        dropView.dropTitle = { [weak self] point in
            guard let self = self else { return "" }
            return self.splitVC.dropPane(at: self.view.convert(point, to: nil)) == 2 ? "Open in 2nd View" : "Open in FastView"
        }
        dropView.onDrop = { [weak self] url, point in
            guard let self = self else { return }
            let pane = self.splitVC.dropPane(at: self.view.convert(point, to: nil))
            self.select(.browser)
            NSApp.activate(ignoringOtherApps: true)
            globalAppDelegate?.open(path: url.path, pane: pane)
        }
        view = dropView
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] tab in self?.select(tab) }
        tabBar.onClose = { [weak self] tab in
            if tab == .favorites { self?.closeFavoritesTab() }
        }
        contentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentView)
        view.addSubview(tabBar)

        let height = tabBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeightConstraint = height
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
            contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        addChild(splitVC)
        embed(splitVC.view)
    }

    private func embed(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: contentView.topAnchor),
            child.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    override public func viewDidLayout() {
        super.viewDidLayout()
        tabBar.leadingInset = windowControlsInset()
    }

    /// Room for the close/minimize/zoom buttons, which sit over the tab bar.
    private func windowControlsInset() -> CGFloat {
        guard let window = view.window, let zoomButton = window.standardWindowButton(.zoomButton),
              zoomButton.window === window, !zoomButton.isHidden,
              let container = zoomButton.superview else { return 0 }
        let buttons = container.convert(zoomButton.frame, to: nil)
        let bar = tabBar.convert(tabBar.bounds, to: nil)
        guard bar.minY < buttons.maxY, bar.maxY > buttons.minY else { return 0 }
        return max(0, buttons.maxX - bar.minX + 6)
    }

    // MARK: - Tabs

    /// Opens the Favorites tab (or switches to it) and shows it.
    public func showFavoritesTab() {
        if favoritesVC == nil {
            let favorites = FavoritesViewController()
            favorites.splitVC = splitVC
            favorites.onShowInBrowser = { [weak self] item in
                self?.select(.browser)
                self?.splitVC.reveal(item)
            }
            addChild(favorites)
            embed(favorites.view)
            favorites.view.isHidden = true
            favoritesVC = favorites
            updateTabBar()
        }
        select(.favorites)
    }

    public func closeFavoritesTab() {
        guard let favorites = favoritesVC else { return }
        favorites.closeEnlarged(animated: false)
        ThumbnailGenerator.shared.cancelThumbnailTasks(inGroup: "favorites-grid", keeping: [])
        favorites.view.removeFromSuperview()
        favorites.removeFromParent()
        favoritesVC = nil
        select(.browser)
        updateTabBar()
    }

    public func select(_ tab: Tab) {
        let target: Tab = (tab == .favorites && favoritesVC == nil) ? .browser : tab
        let changed = target != selectedTab
        selectedTab = target
        splitVC.view.isHidden = target != .browser
        favoritesVC?.view.isHidden = target != .favorites
        tabBar.selectedTab = target

        switch target {
        case .favorites:
            // Favorites may have changed in the browser meanwhile.
            favoritesVC?.reload()
            if changed { favoritesVC?.focusGrid() }
        case .browser:
            if changed { splitVC.focusActiveSidebar() }
        }
    }

    public func selectNextTab() {
        guard isFavoritesTabOpen else { return }
        select(selectedTab == .browser ? .favorites : .browser)
    }

    private func updateTabBar() {
        let show = favoritesVC != nil
        tabBar.tabs = show ? [.browser, .favorites] : [.browser]
        tabBar.isHidden = !show
        tabBarHeightConstraint?.constant = show ? Self.tabBarHeight : 0
        // The window title would sit over the tabs.
        view.window?.titleVisibility = show ? .hidden : .visible
        view.needsLayout = true
    }
}

/// The strip of tabs above the content.  Its empty space drags the window.
final class MainTabBarView: NSView {
    var tabs: [MainTabsViewController.Tab] = [.browser] { didSet { rebuild() } }
    var selectedTab: MainTabsViewController.Tab = .browser { didSet { updateSelection() } }
    var onSelect: ((MainTabsViewController.Tab) -> Void)?
    var onClose: ((MainTabsViewController.Tab) -> Void)?
    var leadingInset: CGFloat = 0 {
        didSet { if oldValue != leadingInset { leadingConstraint?.constant = leadingInset + 6 } }
    }

    private let stack = NSStackView()
    private var leadingConstraint: NSLayoutConstraint?
    private var buttons: [MainTabButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually
        addSubview(stack)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = tabs.map { tab in
            let button = MainTabButton(tab: tab)
            button.onSelect = { [weak self] in self?.onSelect?(tab) }
            button.onClose = { [weak self] in self?.onClose?(tab) }
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            let preferred = button.widthAnchor.constraint(equalToConstant: 220)
            preferred.priority = .defaultLow
            preferred.isActive = true
            return button
        }
        updateSelection()
    }

    private func updateSelection() {
        buttons.forEach { $0.isSelected = $0.tab == selectedTab }
    }
}

/// One tab: icon and title; the Favorites tab also has a close button.
final class MainTabButton: NSView {
    let tab: MainTabsViewController.Tab
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true; updateColors() } }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var isHovered = false { didSet { needsDisplay = true; updateColors() } }
    private var trackingArea: NSTrackingArea?

    init(tab: MainTabsViewController.Tab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let symbol = tab == .favorites ? "star.fill" : "photo.on.rectangle"
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = tab == .favorites ? .systemYellow : .secondaryLabelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = tab == .favorites ? "Favorites" : "Browser"
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = tab != .favorites

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            iconView.trailingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            iconView.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 4),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle click closes, as in browsers.
        if event.buttonNumber == 2 && tab == .favorites { onClose?() }
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func updateColors() {
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        closeButton.alphaValue = (isSelected || isHovered) ? 1 : 0.5
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHovered {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
            path.fill()
        }
    }
}
