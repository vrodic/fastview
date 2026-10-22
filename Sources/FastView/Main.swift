import AppKit

var globalAppDelegate: AppDelegate?

@main
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private static let lastPathKey = "FastViewLastOpenedPath"
    private static let lastSelectedItemKey = "FastViewLastSelectedItemPath"
    private static let lastSelectedItemIdKey = "FastViewLastSelectedItemId"
    private static let recentCmdDirsKey = "FastViewRecentCmdLineDirs"
    private var recentDirsMenu: NSMenu?

    public static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        globalAppDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        let initialPath = getInitialPath()

        let windowController = MainWindowController()
        self.windowController = windowController

        if let window = windowController.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        let isFavoritesMode = UserDefaults.standard.bool(forKey: "FastViewIsFavoritesMode")
        let lastSavedSelectedItem = UserDefaults.standard.string(forKey: AppDelegate.lastSelectedItemKey)
        let lastSavedSelectedItemId = UserDefaults.standard.string(forKey: AppDelegate.lastSelectedItemIdKey)
        let targetItem = lastSavedSelectedItemId ?? lastSavedSelectedItem

        if CommandLine.arguments.count > 1, let suppliedPath = initialPath {
            addRecentCommandLineDirectory(suppliedPath)
            let loc = NavigationManager.locationForPath(suppliedPath)
            saveLastOpenedPath(suppliedPath)

            var targetPath: String? = nil
            let type = ArchiveReader.fileType(for: URL(fileURLWithPath: suppliedPath))
            if type == .image {
                targetPath = suppliedPath
            } else if let savedItem = targetItem {
                let normSupplied = URL(fileURLWithPath: suppliedPath).standardized.path
                let normSaved = URL(fileURLWithPath: savedItem).standardized.path
                if normSaved.hasPrefix(normSupplied) {
                    targetPath = savedItem
                }
            }

            DispatchQueue.main.async {
                windowController.splitVC.showFavoritesOnly = false
                windowController.splitVC.loadLocation(loc, targetSelectedItemPath: targetPath)
            }
        } else if isFavoritesMode {
            DispatchQueue.main.async {
                if let path = initialPath {
                    let loc = NavigationManager.locationForPath(path)
                    windowController.splitVC.loadLocation(loc, targetSelectedItemPath: targetItem)
                }
                windowController.splitVC.showFavoritesOnly = true
            }
        } else if let path = initialPath {
            saveLastOpenedPath(path)
            let loc = NavigationManager.locationForPath(path)
            DispatchQueue.main.async {
                windowController.splitVC.loadLocation(loc, targetSelectedItemPath: targetItem)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        saveCurrentSelectionState()
    }

    private func saveCurrentSelectionState() {
        if let splitVC = windowController?.splitVC {
            if let locPath = splitVC.currentLocationPath {
                UserDefaults.standard.set(locPath, forKey: AppDelegate.lastPathKey)
            }
            if let selectedPath = splitVC.selectedItemPath {
                UserDefaults.standard.set(selectedPath, forKey: AppDelegate.lastSelectedItemKey)
            }
            if let selectedId = splitVC.selectedItemId {
                UserDefaults.standard.set(selectedId, forKey: AppDelegate.lastSelectedItemIdKey)
            }
        }
    }

    private func getInitialPath() -> String? {
        let args = CommandLine.arguments
        if args.count > 1 {
            let path = args[1]
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        if let lastPath = UserDefaults.standard.string(forKey: AppDelegate.lastPathKey),
           FileManager.default.fileExists(atPath: lastPath) {
            return lastPath
        }

        return NSHomeDirectory()
    }

    private func saveLastOpenedPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppDelegate.lastPathKey)
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // 1. Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "FastView")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About FastView", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide FastView", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit FastView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        let recentMenuItem = NSMenuItem(title: "Open Recent Directory", action: nil, keyEquivalent: "")
        let recentSubMenu = NSMenu(title: "Open Recent Directory")
        recentMenuItem.submenu = recentSubMenu
        self.recentDirsMenu = recentSubMenu
        rebuildRecentDirsMenu()
        fileMenu.addItem(recentMenuItem)

        let infoItem = NSMenuItem(title: "Show Info", action: #selector(showInfoAction(_:)), keyEquivalent: "i")
        infoItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(infoItem)
        fileMenu.addItem(withTitle: "Toggle Favorite", action: #selector(toggleFavoriteAction(_:)), keyEquivalent: "f")
        fileMenu.addItem(withTitle: "Switch to All Mode", action: #selector(switchToAllModeAction(_:)), keyEquivalent: "l")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 3. View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        viewMenu.addItem(withTitle: "Show All Items", action: #selector(showAllItemsAction(_:)), keyEquivalent: "")
        let favModeItem = NSMenuItem(title: "Show Favorites Only", action: #selector(showFavoritesOnlyAction(_:)), keyEquivalent: "f")
        favModeItem.keyEquivalentModifierMask = [.option]
        viewMenu.addItem(favModeItem)
        viewMenu.addItem(NSMenuItem.separator())

        let flattenItem = NSMenuItem(title: "Flatten Archive Directories", action: #selector(toggleFlattenArchivesAction(_:)), keyEquivalent: "")
        flattenItem.state = ArchiveReader.flattenArchiveDirectories ? .on : .off
        viewMenu.addItem(flattenItem)

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSizeAction), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFitAction), keyEquivalent: "0")

        // 4. Controls Menu
        let controlsMenuItem = NSMenuItem()
        mainMenu.addItem(controlsMenuItem)
        let controlsMenu = NSMenu(title: "Controls")
        controlsMenuItem.submenu = controlsMenu

        controlsMenu.addItem(withTitle: "Next Image (Down Arrow)", action: #selector(nextImageAction), keyEquivalent: "\u{F701}")
        controlsMenu.addItem(withTitle: "Previous Image (Up Arrow)", action: #selector(previousImageAction), keyEquivalent: "\u{F700}")

        let nextGroupItem = NSMenuItem(title: "Next Folder / Archive First Image", action: #selector(nextGroupAction), keyEquivalent: "\u{F701}")
        nextGroupItem.keyEquivalentModifierMask = [.command]
        controlsMenu.addItem(nextGroupItem)

        let prevGroupItem = NSMenuItem(title: "Previous Folder / Archive First Image", action: #selector(prevGroupAction), keyEquivalent: "\u{F700}")
        prevGroupItem.keyEquivalentModifierMask = [.command]
        controlsMenu.addItem(prevGroupItem)

        controlsMenu.addItem(NSMenuItem.separator())

        controlsMenu.addItem(withTitle: "Next Sibling Directory or Archive", action: #selector(nextSiblingAction), keyEquivalent: "\u{F703}")
        controlsMenu.addItem(withTitle: "Previous Sibling Directory or Archive", action: #selector(prevSiblingAction), keyEquivalent: "\u{F702}")

        let enterItem = NSMenuItem(title: "Enter / Activate Selected Item", action: #selector(activateSelectedItemAction), keyEquivalent: "\r")
        controlsMenu.addItem(enterItem)

        let escapeItem = NSMenuItem(title: "Navigate Up / Exit Archive", action: #selector(navigateUpAction), keyEquivalent: "\u{1B}")
        controlsMenu.addItem(escapeItem)

        controlsMenu.addItem(NSMenuItem.separator())

        let favItem = NSMenuItem(title: "Toggle Favorite", action: #selector(toggleFavoriteAction(_:)), keyEquivalent: "f")
        favItem.keyEquivalentModifierMask = [.command]
        controlsMenu.addItem(favItem)

        let switchAllItem = NSMenuItem(title: "Switch to All Mode", action: #selector(switchToAllModeAction(_:)), keyEquivalent: "l")
        switchAllItem.keyEquivalentModifierMask = [.command]
        controlsMenu.addItem(switchAllItem)

        // 5. Options Menu
        let optionsMenuItem = NSMenuItem()
        mainMenu.addItem(optionsMenuItem)
        let optionsMenu = NSMenu(title: "Options")
        optionsMenuItem.submenu = optionsMenu

        let lowMemItem = NSMenuItem(title: "Low Memory Mode", action: #selector(toggleLowMemoryModeAction(_:)), keyEquivalent: "")
        lowMemItem.state = MemoryLRUCache.shared.isLowMemoryMode ? .on : .off
        optionsMenu.addItem(lowMemItem)

        // 6. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        // 7. Help Menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "FastView Help", action: nil, keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func toggleLowMemoryModeAction(_ sender: NSMenuItem) {
        let newState = !MemoryLRUCache.shared.isLowMemoryMode
        MemoryLRUCache.shared.isLowMemoryMode = newState
        sender.state = newState ? .on : .off
        print("[AppDelegate] Low Memory Mode set to \(newState)")
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                let path = url.path
                self?.saveLastOpenedPath(path)
                let loc = NavigationManager.locationForPath(path)
                let lastSavedSelectedItem = UserDefaults.standard.string(forKey: AppDelegate.lastSelectedItemKey)
                let lastSavedSelectedItemId = UserDefaults.standard.string(forKey: AppDelegate.lastSelectedItemIdKey)
                self?.windowController?.splitVC.loadLocation(loc, targetSelectedItemPath: lastSavedSelectedItemId ?? lastSavedSelectedItem)
            }
        }
    }

    private func addRecentCommandLineDirectory(_ path: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let dirPath: String
            if isDir.boolValue {
                dirPath = URL(fileURLWithPath: path).standardized.path
            } else {
                dirPath = URL(fileURLWithPath: path).deletingLastPathComponent().standardized.path
            }

            var recent = UserDefaults.standard.stringArray(forKey: AppDelegate.recentCmdDirsKey) ?? []
            recent.removeAll(where: { $0 == dirPath })
            recent.insert(dirPath, at: 0)
            if recent.count > 10 {
                recent = Array(recent.prefix(10))
            }
            UserDefaults.standard.set(recent, forKey: AppDelegate.recentCmdDirsKey)
            rebuildRecentDirsMenu()
        }
    }

    private func rebuildRecentDirsMenu() {
        guard let menu = recentDirsMenu else { return }
        menu.removeAllItems()

        let recent = UserDefaults.standard.stringArray(forKey: AppDelegate.recentCmdDirsKey) ?? []

        if recent.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Directories", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for dirPath in recent {
                let item = NSMenuItem(title: dirPath, action: #selector(openRecentCmdLineDirectoryAction(_:)), keyEquivalent: "")
                item.representedObject = dirPath
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentCmdLineDirectoriesAction(_:)), keyEquivalent: "")
            menu.addItem(clearItem)
        }
    }

    @objc private func openRecentCmdLineDirectoryAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String ?? (sender.title.isEmpty ? nil : sender.title) else { return }
        saveLastOpenedPath(path)
        let loc = NavigationManager.locationForPath(path)
        windowController?.splitVC.loadLocation(loc)
    }

    @objc private func clearRecentCmdLineDirectoriesAction(_ sender: Any?) {
        UserDefaults.standard.set([], forKey: AppDelegate.recentCmdDirsKey)
        rebuildRecentDirsMenu()
    }

    @objc private func showInfoAction(_ sender: Any?) {
        windowController?.splitVC.showInfoForSelectedItem()
    }

    @objc private func toggleFavoriteAction(_ sender: Any?) {
        print("[AppDelegate] toggleFavoriteAction menu item triggered")
        windowController?.splitVC.toggleFavoriteOnSelectedItem()
    }

    public func toggleFavoriteActionFromSidebar() {
        print("[AppDelegate] toggleFavoriteActionFromSidebar triggered")
        windowController?.splitVC.toggleFavoriteOnSelectedItem()
    }

    @objc private func switchToAllModeAction(_ sender: Any?) {
        windowController?.splitVC.switchToCurrentItemLocationMode()
    }

    @objc private func showAllItemsAction(_ sender: Any?) {
        print("[AppDelegate] showAllItemsAction menu item triggered")
        windowController?.splitVC.switchToCurrentItemLocationMode()
    }

    @objc private func showFavoritesOnlyAction(_ sender: Any?) {
        guard let splitVC = windowController?.splitVC else { return }
        splitVC.showFavoritesOnly = !splitVC.showFavoritesOnly
    }

    @objc private func toggleFlattenArchivesAction(_ sender: NSMenuItem) {
        let newState = !ArchiveReader.flattenArchiveDirectories
        ArchiveReader.flattenArchiveDirectories = newState
        sender.state = newState ? .on : .off
        DirectoryCache.shared.clear()
        SQLiteCache.shared.clear()
        windowController?.splitVC.reloadDirectoryContentsPublic()
    }

    @objc private func nextImageAction() {
        windowController?.splitVC.selectNextImage()
    }

    @objc private func previousImageAction() {
        windowController?.splitVC.selectPreviousImage()
    }

    @objc private func nextGroupAction() {
        windowController?.splitVC.selectNextArchiveOrFolderFirstImage()
    }

    @objc private func prevGroupAction() {
        windowController?.splitVC.selectPreviousArchiveOrFolderFirstImage()
    }

    @objc private func nextSiblingAction() {
        windowController?.splitVC.selectNextHierarchyItem()
    }

    @objc private func prevSiblingAction() {
        windowController?.splitVC.selectPreviousHierarchyItem()
    }

    @objc private func activateSelectedItemAction() {
        windowController?.splitVC.activateSelectedItem()
    }

    @objc private func navigateUpAction() {
        windowController?.splitVC.navigateUp()
    }

    @objc private func zoomInAction() {
        windowController?.splitVC.imageView.zoomIn()
    }

    @objc private func zoomOutAction() {
        windowController?.splitVC.imageView.zoomOut()
    }

    @objc private func actualSizeAction() {
        windowController?.splitVC.imageView.setActualSize()
    }

    @objc private func zoomToFitAction() {
        windowController?.splitVC.imageView.resetZoomToFit()
    }
}
