import AppKit

public class MainWindowController: NSWindowController, NSWindowDelegate {
    public let splitVC = MainSplitViewController()

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
        window.contentViewController = splitVC

        window.setFrameAutosaveName("FastMainWindow")
        if !window.setFrameUsingName("FastMainWindow") {
            window.setFrame(initialFrame, display: true)
        }

        setupKeyboardMonitors()
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
            case 53, 51: // Escape or Backspace
                self.splitVC.navigateUp()
                return nil
            default:
                break
            }

            // Command key shortcuts
            if isCmdPressed {
                let chars = event.characters?.lowercased() ?? ""
                if chars == "+" || chars == "=" {
                    self.splitVC.imageView.zoomIn()
                    return nil
                } else if chars == "-" {
                    self.splitVC.imageView.zoomOut()
                    return nil
                } else if chars == "0" {
                    self.splitVC.imageView.resetZoomToFit()
                    return nil
                } else if chars == "f" {
                    self.splitVC.toggleFavoriteOnSelectedItem()
                    return nil
                }
            }

            return event
        }
    }
}
