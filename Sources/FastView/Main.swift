import AppKit

var globalAppDelegate: AppDelegate?

@main
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private static let lastPathKey = "FastViewLastOpenedPath"
    private static let lastSelectedItemKey = "FastViewLastSelectedItemPath"
    private static let lastSelectedItemIdKey = "FastViewLastSelectedItemId"

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
        fileMenu.addItem(withTitle: "Pick Folder for 2nd View…", action: #selector(openSecondFolderAction(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Close 2nd View", action: #selector(closeSecondViewAction(_:)), keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Show Info", action: #selector(showInfoAction(_:)), keyEquivalent: "i")
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
        viewMenu.addItem(withTitle: "Show Favorites Only", action: #selector(showFavoritesOnlyAction(_:)), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Pick Folder for 2nd View…", action: #selector(openSecondFolderAction(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Close 2nd View", action: #selector(closeSecondViewAction(_:)), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())

        let flattenItem = NSMenuItem(title: "Flatten Archive Directories", action: #selector(toggleFlattenArchivesAction(_:)), keyEquivalent: "")
        flattenItem.state = ArchiveReader.flattenArchiveDirectories ? .on : .off
        viewMenu.addItem(flattenItem)

        let lowMemItem = NSMenuItem(title: "Low Memory Mode", action: #selector(toggleLowMemoryModeAction(_:)), keyEquivalent: "")
        lowMemItem.state = MemoryLRUCache.shared.isLowMemoryMode ? .on : .off
        viewMenu.addItem(lowMemItem)

        let combiningControlsItem = NSMenuItem(title: "Image Combining Controls", action: #selector(toggleCombiningControlsAction(_:)), keyEquivalent: "c")
        combiningControlsItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(combiningControlsItem)

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Rotate Right 90°", action: #selector(rotateRightAction), keyEquivalent: "r")
        let rotLeftItem = NSMenuItem(title: "Rotate Left 90°", action: #selector(rotateLeftAction), keyEquivalent: "r")
        rotLeftItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(rotLeftItem)
        viewMenu.addItem(withTitle: "Flip Horizontal", action: #selector(flipHorizontalAction), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Flip Vertical", action: #selector(flipVerticalAction), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Reset Orientation", action: #selector(resetOrientationAction), keyEquivalent: "")

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

        let nextPane2Item = NSMenuItem(title: "Next Image in 2nd View", action: #selector(nextImagePane2Action), keyEquivalent: "\u{F701}")
        nextPane2Item.keyEquivalentModifierMask = [.control]
        controlsMenu.addItem(nextPane2Item)

        let prevPane2Item = NSMenuItem(title: "Previous Image in 2nd View", action: #selector(prevImagePane2Action), keyEquivalent: "\u{F700}")
        prevPane2Item.keyEquivalentModifierMask = [.control]
        controlsMenu.addItem(prevPane2Item)

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

        let toggleFavModeItem = NSMenuItem(title: "Toggle Favorites Mode", action: #selector(toggleFavoritesModeAction(_:)), keyEquivalent: "f")
        toggleFavModeItem.keyEquivalentModifierMask = [.option]
        controlsMenu.addItem(toggleFavModeItem)

        let switchAllItem = NSMenuItem(title: "Switch to All Mode", action: #selector(switchToAllModeAction(_:)), keyEquivalent: "l")
        switchAllItem.keyEquivalentModifierMask = [.command]
        controlsMenu.addItem(switchAllItem)

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        // 5. Help Menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "FastView Help", action: nil, keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showInfoAction(_ sender: Any?) {
        windowController?.splitVC.showInfoForSelectedItem()
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
        windowController?.splitVC.showFavoritesOnly = true
    }

    @objc private func toggleFavoritesModeAction(_ sender: Any?) {
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

    @objc private func toggleLowMemoryModeAction(_ sender: NSMenuItem) {
        let newState = !MemoryLRUCache.shared.isLowMemoryMode
        MemoryLRUCache.shared.isLowMemoryMode = newState
        sender.state = newState ? .on : .off
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

    @objc private func openSecondFolderAction(_ sender: Any?) {
        windowController?.splitVC.openSecondFolder()
    }

    @objc private func closeSecondViewAction(_ sender: Any?) {
        windowController?.splitVC.closeSecondView()
    }

    @objc private func nextImagePane2Action() {
        windowController?.splitVC.selectNextImagePane2()
    }

    @objc private func prevImagePane2Action() {
        windowController?.splitVC.selectPreviousImagePane2()
    }

    @objc private func rotateRightAction() {
        windowController?.splitVC.rotateRightForActivePane()
    }

    @objc private func rotateLeftAction() {
        windowController?.splitVC.rotateLeftForActivePane()
    }

    @objc private func flipHorizontalAction() {
        windowController?.splitVC.flipHorizontalForActivePane()
    }

    @objc private func flipVerticalAction() {
        windowController?.splitVC.flipVerticalForActivePane()
    }

    @objc private func resetOrientationAction() {
        windowController?.splitVC.resetOrientationForActivePane()
    }

    @objc private func toggleCombiningControlsAction(_ sender: Any?) {
        windowController?.splitVC.toggleCombiningControls()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleCombiningControlsAction(_:)) ||
           menuItem.action == #selector(closeSecondViewAction(_:)) {
            return windowController?.splitVC.sidebarContainerVC.isDualView ?? false
        }
        return true
    }
}
