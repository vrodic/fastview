import AppKit

public class MainWindowController: NSWindowController, NSWindowDelegate {
    public let tabsVC = MainTabsViewController()
    public var splitVC: MainSplitViewController { tabsVC.splitVC }

    public convenience init() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let windowWidth = floor(screenFrame.width * 0.75)
        let windowHeight = floor(screenFrame.height * 0.75)
        let originX = screenFrame.origin.x + floor((screenFrame.width - windowWidth) / 2)
        let originY = screenFrame.origin.y + floor((screenFrame.height - windowHeight) / 2)

        let initialFrame = NSRect(
            x: originX,
            y: originY,
            width: windowWidth,
            height: windowHeight
        )

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FastView"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        window.contentViewController = tabsVC

        window.setFrameAutosaveName("FastMainWindow")
        if !window.setFrameUsingName("FastMainWindow") {
            window.setFrame(initialFrame, display: true)
        }

        setupKeyboardMonitors()
    }

    /// There is one main window and nothing to do without it.
    public func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        splitVC.setFullScreenMode(true)
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        splitVC.setFullScreenMode(false)
    }

    private func setupKeyboardMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            guard let self = self else { return event }

            if let keyWindow = NSApp.keyWindow, keyWindow != self.window {
                return event
            }

            let isCmdPressed = event.modifierFlags.contains(.command)

            let isControlPressed = event.modifierFlags.contains(.control)

            // The Favorites tab handles its own keys; Cmd+Return still toggles full screen.
            if let favorites = self.tabsVC.activeFavoritesVC {
                if isCmdPressed && (event.keyCode == 36 || event.keyCode == 76) {
                    self.window?.toggleFullScreen(nil)
                    return nil
                }
                return favorites.handleKeyDown(event) ? nil : event
            }

            // While censoring, Esc stops it and ⌘Z undoes the last censor.
            if let censoring = self.splitVC.censoringImageView {
                if event.keyCode == 53 {
                    censoring.endCensoring()
                    return nil
                }
                if isCmdPressed && event.charactersIgnoringModifiers?.lowercased() == "z" {
                    censoring.undoCensor()
                    return nil
                }
            }

            // Esc stops drawing an outline, and leaves full screen before going up a folder.
            if event.keyCode == 53 {
                if let outlining = self.splitVC.outliningImageView {
                    outlining.cancelFreehandSelection()
                    return nil
                }
                if self.window?.styleMask.contains(.fullScreen) == true {
                    self.window?.toggleFullScreen(nil)
                    return nil
                }
            }

            switch event.keyCode {
            case 125: // Down arrow
                if isControlPressed {
                    self.splitVC.selectNextImagePane2()
                } else if isCmdPressed {
                    self.splitVC.selectNextArchiveOrFolderFirstImage()
                } else {
                    self.splitVC.selectNextImage()
                }
                return nil
            case 126: // Up arrow
                if isControlPressed {
                    self.splitVC.selectPreviousImagePane2()
                } else if isCmdPressed {
                    self.splitVC.selectPreviousArchiveOrFolderFirstImage()
                } else {
                    self.splitVC.selectPreviousImage()
                }
                return nil
            case 124: // Right Arrow
                self.splitVC.selectNextHierarchyItem()
                return nil
            case 123: // Left Arrow
                self.splitVC.selectPreviousHierarchyItem()
                return nil
            case 36, 76: // Return / Enter (Cmd: toggle full screen)
                if isCmdPressed {
                    self.window?.toggleFullScreen(nil)
                    return nil
                }
                self.splitVC.activateSelectedItem()
                return nil
            case 53, 51: // Escape or Backspace (Cmd+Backspace is Move to Trash)
                if isCmdPressed { return event }
                self.splitVC.navigateUp()
                return nil
            case 116, 121, 115, 119: // Page Up, Page Down, Home, End
                let keys: [UInt16: PageKeyType] = [116: .pageUp, 121: .pageDown, 115: .home, 119: .end]
                if let key = keys[event.keyCode] { self.splitVC.activeSidebar.handlePageNavigation(keyType: key) }
                return nil
            case 48 where !isControlPressed && !isCmdPressed: // Tab
                self.splitVC.switchActivePane()
                return nil
            default:
                break
            }

            // Command key shortcuts
            if isCmdPressed {
                let chars = event.characters?.lowercased() ?? ""
                if chars == "+" || chars == "=" {
                    self.splitVC.activeImageView.zoomIn()
                    return nil
                } else if chars == "-" {
                    self.splitVC.activeImageView.zoomOut()
                    return nil
                } else if chars == "0" {
                    self.splitVC.activeImageView.resetZoomToFit(announce: true)
                    return nil
                } else if chars == "f" && !event.modifierFlags.contains(.shift) {
                    self.splitVC.toggleFavoriteOnSelectedItem()
                    return nil
                }
            }

            return event
        }
    }
}
