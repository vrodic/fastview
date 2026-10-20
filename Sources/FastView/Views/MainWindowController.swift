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

        // Frame autosave setup
        window.frameAutosaveName = NSWindow.FrameAutosaveName("FastMainWindow")
        if !window.setFrameUsingName("FastMainWindow") {
            window.setFrame(initialFrame, display: true)
        }

        setupKeyboardMonitors()
    }

    private func setupKeyboardMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            guard let self = self else { return event }

            switch event.keyCode {
            case 125: // Down arrow
                self.splitVC.selectNextImage()
                return nil
            case 126: // Up arrow
                self.splitVC.selectPreviousImage()
                return nil
            case 36: // Return / Enter
                self.splitVC.activateSelectedItem()
                return nil
            case 123, 51: // Left Arrow or Backspace
                self.splitVC.navigateUp()
                return nil
            default:
                break
            }

            // Command key shortcuts for Zooming
            if event.modifierFlags.contains(.command) {
                if event.characters == "+" || event.characters == "=" {
                    self.splitVC.imageView.zoomIn()
                    return nil
                } else if event.characters == "-" {
                    self.splitVC.imageView.zoomOut()
                    return nil
                } else if event.characters == "0" {
                    self.splitVC.imageView.resetZoomToFit()
                    return nil
                }
            }

            return event
        }
    }
}
