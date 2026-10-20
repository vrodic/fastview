import AppKit

@main
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private static let lastPathKey = "FastViewLastOpenedPath"

    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        let initialPath = getInitialPath()

        let windowController = MainWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)

        if let path = initialPath {
            saveLastOpenedPath(path)
            let loc = NavigationManager.locationForPath(path)

            var targetItem: FileItem? = nil
            let type = ArchiveReader.fileType(for: URL(fileURLWithPath: path))
            if type == .image {
                let name = (path as NSString).lastPathComponent
                targetItem = FileItem(id: path, name: name, path: path, type: .image)
            }

            windowController.splitVC.loadLocation(loc, targetSelectedItem: targetItem)
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

        // Application Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit FastView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+")
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-")
        let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(actualSizeAction), keyEquivalent: "1")
        let zoomToFitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFitAction), keyEquivalent: "0")

        viewMenu.addItem(zoomInItem)
        viewMenu.addItem(zoomOutItem)
        viewMenu.addItem(actualSizeItem)
        viewMenu.addItem(zoomToFitItem)

        NSApp.mainMenu = mainMenu
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
                self?.windowController?.splitVC.loadLocation(loc)
            }
        }
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
