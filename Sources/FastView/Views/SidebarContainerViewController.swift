import AppKit

public class SidebarContainerViewController: NSSplitViewController {
    public let sidebarVC1 = SidebarViewController()
    public let sidebarVC2 = SidebarViewController()

    public private(set) var isDualView: Bool = false

    override public func viewDidLoad() {
        super.viewDidLoad()
        sidebarVC1.paneIndex = 1
        sidebarVC2.paneIndex = 2

        // By default, split view orientation: isVertical = false creates a horizontal divider (top/bottom split)
        splitView.isVertical = false
        splitView.dividerStyle = .thin

        updateViewMode(isDual: false)
    }

    public func updateViewMode(isDual: Bool) {
        self.isDualView = isDual

        // Remove all split items
        for item in splitViewItems {
            removeSplitViewItem(item)
        }

        let item1 = NSSplitViewItem(viewController: sidebarVC1)
        item1.minimumThickness = 80
        addSplitViewItem(item1)

        sidebarVC1.showHeader = isDual

        if isDual {
            let item2 = NSSplitViewItem(viewController: sidebarVC2)
            item2.minimumThickness = 80
            addSplitViewItem(item2)
            sidebarVC2.showHeader = true
        }
    }
}
