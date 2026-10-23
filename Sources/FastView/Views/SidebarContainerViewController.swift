import AppKit

public class SidebarContainerViewController: NSSplitViewController {
    public let sidebarVC1 = SidebarViewController()
    public let sidebarVC2 = SidebarViewController()

    public private(set) var isDualView: Bool = false

    override public func viewDidLoad() {
        super.viewDidLoad()
        sidebarVC1.paneIndex = 1
        sidebarVC2.paneIndex = 2

        splitView.isVertical = false
        splitView.dividerStyle = .thin

        updateViewMode(isDual: false)
    }

    public func updateViewMode(isDual: Bool) {
        self.isDualView = isDual

        if let window = view.window, let responder = window.firstResponder as? NSView {
            if responder.isDescendant(of: sidebarVC2.view) {
                window.makeFirstResponder(sidebarVC1.view)
            }
        }

        for item in splitViewItems {
            removeSplitViewItem(item)
        }

        if isDual {
            let item1 = NSSplitViewItem(viewController: sidebarVC1)
            item1.minimumThickness = 80
            item1.holdingPriority = NSLayoutConstraint.Priority(250)

            let item2 = NSSplitViewItem(viewController: sidebarVC2)
            item2.minimumThickness = 80
            item2.holdingPriority = NSLayoutConstraint.Priority(250)

            addSplitViewItem(item1)
            addSplitViewItem(item2)

            sidebarVC1.showHeader = true
            sidebarVC2.showHeader = true

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let totalHeight = self.splitView.bounds.height
                if totalHeight > 100 {
                    self.splitView.setPosition(totalHeight / 2.0, ofDividerAt: 0)
                }
            }
        } else {
            let item1 = NSSplitViewItem(viewController: sidebarVC1)
            item1.minimumThickness = 80
            addSplitViewItem(item1)
            sidebarVC1.showHeader = false
        }
    }
}
