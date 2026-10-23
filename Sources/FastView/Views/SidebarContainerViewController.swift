import AppKit

public class SidebarContainerViewController: NSSplitViewController {
    public let sidebarVC1 = SidebarViewController()
    public let sidebarVC2 = SidebarViewController()

    private var item1: NSSplitViewItem?
    private var item2: NSSplitViewItem?

    public private(set) var isDualView: Bool = false
    private static let previewSubSplitPositionKey = "FastViewPreviewSubSplitPosition"
    private static let previewSubSplitIsVerticalKey = "FastViewPreviewSubSplitIsVertical"

    public var isSubSplitVertical: Bool {
        get { return splitView.isVertical }
        set {
            guard splitView.isVertical != newValue else { return }
            splitView.isVertical = newValue
            UserDefaults.standard.set(newValue, forKey: SidebarContainerViewController.previewSubSplitIsVerticalKey)
            if isDualView {
                makeEvenSplit()
            }
        }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        sidebarVC1.paneIndex = 1
        sidebarVC2.paneIndex = 2

        let savedVertical = UserDefaults.standard.bool(forKey: SidebarContainerViewController.previewSubSplitIsVerticalKey)
        splitView.isVertical = savedVertical
        splitView.dividerStyle = .thin

        let i1 = NSSplitViewItem(viewController: sidebarVC1)
        i1.minimumThickness = 80
        i1.holdingPriority = NSLayoutConstraint.Priority(250)
        self.item1 = i1
        addSplitViewItem(i1)

        let i2 = NSSplitViewItem(viewController: sidebarVC2)
        i2.minimumThickness = 80
        i2.holdingPriority = NSLayoutConstraint.Priority(250)
        self.item2 = i2
        addSplitViewItem(i2)

        updateViewMode(isDual: false)
    }

    public func updateViewMode(isDual: Bool) {
        FileLogger.shared.log("SIDEBAR_CONTAINER", path: "updateViewMode isDual: \(isDual)")
        self.isDualView = isDual

        guard let i2 = item2 else { return }

        if isDual {
            i2.isCollapsed = false
            sidebarVC1.showHeader = true
            sidebarVC2.showHeader = true

            DispatchQueue.main.async { [weak self] in
                self?.adjustSubSplitRatio()
            }
        } else {
            if let window = view.window, let responder = window.firstResponder as? NSView {
                if responder.isDescendant(of: sidebarVC2.view) {
                    window.makeFirstResponder(sidebarVC1.view)
                }
            }
            i2.isCollapsed = true
            sidebarVC1.showHeader = false
        }
    }

    public func makeEvenSplit() {
        guard isDualView else { return }
        let totalSpan = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        if totalSpan > 100 {
            splitView.setPosition(totalSpan / 2.0, ofDividerAt: 0)
        }
    }

    override public func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if isDualView && splitView.subviews.count > 0 {
            let currentSpan = splitView.isVertical ? splitView.subviews[0].frame.width : splitView.subviews[0].frame.height
            if currentSpan > 40 {
                UserDefaults.standard.set(currentSpan, forKey: SidebarContainerViewController.previewSubSplitPositionKey)
            }
        }
    }
}
