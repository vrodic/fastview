import AppKit

public class MainWindowController: NSWindowController, NSWindowDelegate {
    public let splitVC = MainSplitViewController()

    public convenience init() {
        let screenSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let windowWidth = screenSize.width * 0.75
        let windowHeight = screenSize.height * 0.75

        let window = NSWindow(
            contentRect: NSRect(
                x: (screenSize.width - windowWidth) / 2,
                y: (screenSize.height - windowHeight) / 2,
                width: windowWidth,
                height: windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FastView"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 600, height: 400)

        self.init(window: window)
        window.delegate = self
        window.contentViewController = splitVC

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
            case 51, 123: // Backspace or Left Arrow
                if event.keyCode == 51 || event.modifierFlags.contains(.command) {
                    self.splitVC.navigateUp()
                    return nil
                }
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
