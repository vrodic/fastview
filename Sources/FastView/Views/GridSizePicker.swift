import AppKit

/// Thumbnail size of the favorites viewer grid (persisted in UserDefaults).
public enum FavoritesGridSize: Int, CaseIterable {
    case huge, large, medium, small

    private static let defaultsKey = "FastViewFavoritesGridSize"

    /// Width a cell aims for; the columns that fit share the row evenly.
    var targetCellWidth: CGFloat {
        switch self {
        case .huge: return 560
        case .large: return 380
        case .medium: return 260
        case .small: return 170
        }
    }

    var title: String {
        switch self {
        case .huge: return "Huge"
        case .large: return "Large"
        case .medium: return "Medium"
        case .small: return "Small"
        }
    }

    static var saved: FavoritesGridSize {
        get { FavoritesGridSize(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .large }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var bigger: FavoritesGridSize? { FavoritesGridSize(rawValue: rawValue - 1) }
    var smaller: FavoritesGridSize? { FavoritesGridSize(rawValue: rawValue + 1) }
}

/// How a grid of one size lays out in a given area.
struct FavoritesGridMetrics {
    static let inset: CGFloat = 16
    static let spacing: CGFloat = 12
    static let labelHeight: CGFloat = 22

    let columns: Int
    let cellWidth: CGFloat
    /// Square image area plus the name below it.
    var cellHeight: CGFloat { cellWidth + Self.labelHeight }
    /// Rows on screen at once, the last one possibly partly.
    let visibleRows: CGFloat

    init(size: FavoritesGridSize, area: NSSize) {
        let width = max(1, area.width - 2 * Self.inset)
        let fit = Int(floor((width + Self.spacing) / (size.targetCellWidth + Self.spacing)))
        columns = max(1, fit)
        cellWidth = max(40, floor((width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)))
        let rowHeight = cellWidth + Self.labelHeight + Self.spacing
        visibleRows = max(0.2, (area.height - Self.inset) / rowHeight)
    }

    var visibleCount: Int { columns * max(1, Int(ceil(visibleRows - 0.15))) }
}

/// Segmented picker for `FavoritesGridSize`: each segment draws a small
/// copy of the grid area with the cells that size would show in it, so the
/// choice shows both how big the thumbnails get and how many fit.
final class GridSizePicker: NSControl {
    private(set) var selectedSize = FavoritesGridSize.saved
    /// The size of the area the grid fills, for the miniatures.
    var gridArea = NSSize(width: 1200, height: 800) {
        didSet {
            if oldValue != gridArea { needsDisplay = true; updateToolTips() }
        }
    }

    private let segmentWidth: CGFloat = 46
    private let segmentGap: CGFloat = 2
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        updateToolTips()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(FavoritesGridSize.allCases.count)
        return NSSize(width: count * segmentWidth + (count - 1) * segmentGap + 4, height: 32)
    }

    override var isFlipped: Bool { true }

    func select(_ size: FavoritesGridSize, sendAction: Bool) {
        guard size != selectedSize else { return }
        selectedSize = size
        needsDisplay = true
        if sendAction { self.sendAction(action, to: target) }
    }

    private func segmentRect(_ index: Int) -> NSRect {
        NSRect(x: 2 + CGFloat(index) * (segmentWidth + segmentGap), y: 2, width: segmentWidth, height: bounds.height - 4)
    }

    private func index(at point: NSPoint) -> Int? {
        FavoritesGridSize.allCases.indices.first { segmentRect($0).contains(point) }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for (i, size) in FavoritesGridSize.allCases.enumerated() {
            let metrics = FavoritesGridMetrics(size: size, area: gridArea)
            addToolTip(segmentRect(i), owner: "\(size.title): \(metrics.columns) per row, about \(metrics.visibleCount) on screen" as NSString, userData: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        updateToolTips()
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = index(at: convert(event.locationInWindow, from: nil))
        if hovered != hoveredIndex { hoveredIndex = hovered; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        select(FavoritesGridSize.allCases[i], sendAction: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        background.fill()

        for (i, size) in FavoritesGridSize.allCases.enumerated() {
            let rect = segmentRect(i)
            let isSelected = size == selectedSize
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            } else if hoveredIndex == i {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            drawMiniature(of: size, in: rect.insetBy(dx: 7, dy: 5), selected: isSelected)
        }
    }

    /// The grid area scaled into `rect` (keeping its shape), with the cells
    /// of `size` laid out as the grid would, the last row cut off.
    private func drawMiniature(of size: FavoritesGridSize, in rect: NSRect, selected: Bool) {
        let aspect = max(0.6, min(2.4, gridArea.width / max(1, gridArea.height)))
        var frame = rect
        if rect.width / rect.height > aspect {
            frame.size.width = rect.height * aspect
        } else {
            frame.size.height = rect.width / aspect
        }
        frame.origin.x = rect.midX - frame.width / 2
        frame.origin.y = rect.midY - frame.height / 2
        frame = frame.integral

        let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
        let ink = selected ? NSColor.white : NSColor.secondaryLabelColor
        ink.withAlphaComponent(0.7).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let metrics = FavoritesGridMetrics(size: size, area: gridArea)
        let scale = frame.width / max(1, gridArea.width)
        let pad = max(1, FavoritesGridMetrics.inset * scale)
        let gap = max(1, FavoritesGridMetrics.spacing * scale)
        let cols = metrics.columns
        let cellW = (frame.width - 2 * pad - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let cellH = max(1, cellW)
        let content = frame.insetBy(dx: pad, dy: pad)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: content).addClip()
        ink.withAlphaComponent(selected ? 0.95 : 0.6).setFill()
        var y = content.minY
        while y < content.maxY {
            for c in 0..<cols {
                let cell = NSRect(x: content.minX + CGFloat(c) * (cellW + gap), y: y, width: cellW, height: cellH)
                if cellW >= 4 {
                    NSBezierPath(roundedRect: cell, xRadius: 1, yRadius: 1).fill()
                } else {
                    cell.fill()
                }
            }
            y += cellH + gap + max(0.5, FavoritesGridMetrics.labelHeight * scale)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
