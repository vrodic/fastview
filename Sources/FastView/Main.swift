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

            if isFavoritesMode {
                windowController.splitVC.showFavoritesOnly = true
            } else {
                windowController.splitVC.loadLocation(loc, targetSelectedItemPath: targetPath)
            }
        } else if isFavoritesMode {
            windowController.splitVC.showFavoritesOnly = true
        } else if let path = initialPath {
            saveLastOpenedPath(path)
            let loc = NavigationManager.locationForPath(path)
            windowController.splitVC.loadLocation(loc, targetSelectedItemPath: targetItem)
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
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSizeAction), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Zoom to Fit", action: #selector(zoomToFitAction), keyEquivalent: "0")

        // 4. Window Menu
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
        windowController?.splitVC.showFavoritesOnly = false
    }

    @objc private func showFavoritesOnlyAction(_ sender: Any?) {
        windowController?.splitVC.showFavoritesOnly = true
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
