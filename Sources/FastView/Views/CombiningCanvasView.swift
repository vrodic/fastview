import AppKit

public class CombiningCanvasView: NSView {
    public var image1: NSImage? {
        didSet {
            updateCachedTransformedImage1()
            needsDisplay = true
        }
    }
    public var image2: NSImage? {
        didSet {
            updateCachedTransformedImage2()
            needsDisplay = true
        }
    }

    public var orientation1 = ImageOrientation() {
        didSet {
            updateCachedTransformedImage1()
            needsDisplay = true
        }
    }
    public var orientation2 = ImageOrientation() {
        didSet {
            updateCachedTransformedImage2()
            needsDisplay = true
        }
    }

    public var foregroundObject1: ForegroundObject? {
        didSet {
            updateCachedFgImage1()
            needsDisplay = true
        }
    }
    public var foregroundObject2: ForegroundObject? {
        didSet {
            updateCachedFgImage2()
            needsDisplay = true
        }
    }

    public var pendingFg1Position: CGPoint?
    public var pendingFg1Scale: CGFloat?
    public var pendingFg1Rotation: CGFloat?

    public var pendingFg2Position: CGPoint?
    public var pendingFg2Scale: CGFloat?
    public var pendingFg2Rotation: CGFloat?

    public var showBackground1: Bool = true { didSet { needsDisplay = true } }
    public var showBackground2: Bool = true { didSet { needsDisplay = true } }
    public var fg1OnTop: Bool = true { didSet { needsDisplay = true } }

    public var combiningMode: CanvasCombiningMode = .split { didSet { needsDisplay = true } }

    public var onRetuneDetector: ((Int, VisionDetectionMode) -> Void)?
    public var onSelectedObjectChanged: ((Int, ForegroundObject) -> Void)?

    // Merge Mode Parameters
    public var mergeLeftPercent: CGFloat = 50.0 { didSet { needsDisplay = true } }
    public var mergeRightPercent: CGFloat = 50.0 { didSet { needsDisplay = true } }
    public var alphaGradientPercent: CGFloat = 20.0 { didSet { needsDisplay = true } }

    // Foreground Combine Sliders (0..100)
    public var fgOffset1Percent: CGFloat = 50.0 {
        didSet {
            updateFGPositionsFromSliders()
            needsDisplay = true
        }
    }

    public var fgOffset2Percent: CGFloat = 50.0 {
        didSet {
            updateFGPositionsFromSliders()
            needsDisplay = true
        }
    }

    // Cached Transformed Images
    private var cachedTransformedImage1: NSImage?
    private var cachedTransformedImage2: NSImage?
    private var cachedFgImage1: NSImage?
    private var cachedFgImage2: NSImage?

    private func updateCachedTransformedImage1() {
        cachedTransformedImage1 = image1?.transformed(with: orientation1)
        updateCachedFgImage1()
    }

    private func updateCachedTransformedImage2() {
        cachedTransformedImage2 = image2?.transformed(with: orientation2)
        updateCachedFgImage2()
    }

    private func updateCachedFgImage1() {
        if let fg = foregroundObject1 {
            cachedFgImage1 = fg.image.transformed(with: orientation1)
        } else {
            cachedFgImage1 = nil
        }
    }

    private func updateCachedFgImage2() {
        if let fg = foregroundObject2 {
            cachedFgImage2 = fg.image.transformed(with: orientation2)
        } else {
            cachedFgImage2 = nil
        }
    }

    // Interactivity
    public private(set) var selectedObjectPane: Int? = nil // 1 or 2
    private var isDraggingObject: Bool = false
    private var isResizingObject: Bool = false
    private var isRotatingObject: Bool = false

    private var dragStartPoint: CGPoint = .zero
    private var initialObjPosition: CGPoint = .zero
    private var initialObjScale: CGFloat = 1.0
    private var initialObjRotation: CGFloat = 0.0
    private var initialDistToCenter: CGFloat = 1.0

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override public var isFlipped: Bool { return false }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFGPositionsFromSliders()
    }

    public func updateFGPositionsFromSliders() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let midX = bounds.width / 2.0
        let midY = bounds.height / 2.0

        if foregroundObject1 != nil {
            let defaultX = bounds.width * 0.25
            let moveAmount = (midX - defaultX) * (fgOffset1Percent / 100.0)
            if !isDraggingObject || selectedObjectPane != 1 {
                foregroundObject1?.position = CGPoint(x: defaultX + moveAmount, y: midY)
            }
        }

        if foregroundObject2 != nil {
            let defaultX = bounds.width * 0.75
            let moveAmount = (midX - defaultX) * (fgOffset2Percent / 100.0)
            if !isDraggingObject || selectedObjectPane != 2 {
                foregroundObject2?.position = CGPoint(x: defaultX - moveAmount, y: midY)
            }
        }
    }

    private func defaultFitScale(for fg: ForegroundObject) -> CGFloat {
        guard bounds.width > 0 && bounds.height > 0 else { return fg.scale }
        let maxW = bounds.width * 0.4
        let maxH = bounds.height * 0.75
        let imgW = max(1.0, fg.image.size.width)
        let imgH = max(1.0, fg.image.size.height)
        let fit = min(maxW / imgW, maxH / imgH)
        return fg.scale * fit
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        switch combiningMode {
        case .split:
            drawSplitView(in: bounds, context: context)
        case .merge:
            drawMergeView(in: bounds, context: context)
        case .foregroundCombine:
            drawForegroundCombineView(in: bounds, context: context)
        }
    }

    // MARK: - Normal Split View
    private func drawSplitView(in rect: CGRect, context: CGContext) {
        let halfWidth = rect.width / 2.0

        if let img1 = cachedTransformedImage1 ?? image1?.transformed(with: orientation1) {
            let rect1 = CGRect(x: 0, y: 0, width: halfWidth, height: rect.height)
            drawAspectFit(image: img1, in: rect1, context: context)
        }

        if let img2 = cachedTransformedImage2 ?? image2?.transformed(with: orientation2) {
            let rect2 = CGRect(x: halfWidth, y: 0, width: halfWidth, height: rect.height)
            drawAspectFit(image: img2, in: rect2, context: context)
        }

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(2.0)
        context.move(to: CGPoint(x: halfWidth, y: 0))
        context.addLine(to: CGPoint(x: halfWidth, y: rect.height))
        context.strokePath()
    }

    // MARK: - Merge View with Alpha Gradient
    private func drawMergeView(in rect: CGRect, context: CGContext) {
        let transformed1 = cachedTransformedImage1 ?? image1?.transformed(with: orientation1)
        let transformed2 = cachedTransformedImage2 ?? image2?.transformed(with: orientation2)

        if let img1 = transformed1 {
            let leftWidth = rect.width * (mergeLeftPercent / 100.0)
            let leftRect = CGRect(x: 0, y: 0, width: max(leftWidth, 10), height: rect.height)
            drawAspectFill(image: img1, in: leftRect, context: context)
        }

        if let img2 = transformed2 {
            let rightWidth = rect.width * (mergeRightPercent / 100.0)
            let rightX = rect.width - rightWidth
            let rightRect = CGRect(x: rightX, y: 0, width: max(rightWidth, 10), height: rect.height)

            context.saveGState()

            let blendZoneWidth = rect.width * (alphaGradientPercent / 100.0)
            if blendZoneWidth > 0 && rightX < rect.width {
                let colors = [NSColor.clear.cgColor, NSColor.black.cgColor] as CFArray
                let locations: [CGFloat] = [0.0, 1.0]
                if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                   let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {

                    let blendStart = CGPoint(x: rightX, y: 0)
                    let blendEnd = CGPoint(x: rightX + blendZoneWidth, y: 0)

                    context.clip(to: rightRect)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    drawAspectFill(image: img2, in: rightRect, context: context)

                    context.setBlendMode(.destinationIn)
                    context.drawLinearGradient(gradient, start: blendStart, end: blendEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.endTransparencyLayer()
                    context.restoreGState()
                    return
                }
            }

            drawAspectFill(image: img2, in: rightRect, context: context)
            context.restoreGState()
        }
    }

    // MARK: - Foreground Combine View
    private func drawForegroundCombineView(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setAlpha(0.35)
        let halfWidth = rect.width / 2.0

        if showBackground1, let img1 = cachedTransformedImage1 ?? image1?.transformed(with: orientation1) {
            drawAspectFit(image: img1, in: CGRect(x: 0, y: 0, width: halfWidth, height: rect.height), context: context)
        }
        if showBackground2, let img2 = cachedTransformedImage2 ?? image2?.transformed(with: orientation2) {
            drawAspectFit(image: img2, in: CGRect(x: halfWidth, y: 0, width: halfWidth, height: rect.height), context: context)
        }
        context.restoreGState()

        if fg1OnTop {
            if let fg2 = foregroundObject2 {
                drawForegroundObject(fg2, paneIndex: 2, in: rect, context: context)
            }
            if let fg1 = foregroundObject1 {
                drawForegroundObject(fg1, paneIndex: 1, in: rect, context: context)
            }
        } else {
            if let fg1 = foregroundObject1 {
                drawForegroundObject(fg1, paneIndex: 1, in: rect, context: context)
            }
            if let fg2 = foregroundObject2 {
                drawForegroundObject(fg2, paneIndex: 2, in: rect, context: context)
            }
        }
    }

    private func drawForegroundObject(_ obj: ForegroundObject, paneIndex: Int, in rect: CGRect, context: CGContext) {
        context.saveGState()

        let orientation = (paneIndex == 1) ? orientation1 : orientation2
        let cached = (paneIndex == 1) ? cachedFgImage1 : cachedFgImage2
        let orientedImg = cached ?? obj.image.transformed(with: orientation)

        let effectiveScale = defaultFitScale(for: obj)
        let targetWidth = orientedImg.size.width * effectiveScale
        let targetHeight = orientedImg.size.height * effectiveScale
        let drawRect = CGRect(
            x: -targetWidth / 2.0,
            y: -targetHeight / 2.0,
            width: targetWidth,
            height: targetHeight
        )

        context.translateBy(x: obj.position.x, y: obj.position.y)
        context.rotate(by: obj.rotationDegrees * .pi / 180.0)

        orientedImg.draw(in: drawRect)

        if selectedObjectPane == paneIndex {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2.0)
            context.stroke(drawRect)

            let handleSize: CGFloat = 10.0
            let corners = [
                CGPoint(x: drawRect.minX, y: drawRect.minY),
                CGPoint(x: drawRect.maxX, y: drawRect.minY),
                CGPoint(x: drawRect.minX, y: drawRect.maxY),
                CGPoint(x: drawRect.maxX, y: drawRect.maxY)
            ]
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            for c in corners {
                let hRect = CGRect(x: c.x - handleSize/2, y: c.y - handleSize/2, width: handleSize, height: handleSize)
                context.fill(hRect)
            }

            let rotateStemY = drawRect.maxY + 20.0
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: 0, y: drawRect.maxY))
            context.addLine(to: CGPoint(x: 0, y: rotateStemY))
            context.strokePath()

            let rotateCircleRect = CGRect(x: -6, y: rotateStemY - 6, width: 12, height: 12)
            context.setFillColor(NSColor.systemYellow.cgColor)
            context.fillEllipse(in: rotateCircleRect)
        }

        context.restoreGState()
    }

    private func drawAspectFit(image: NSImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0 && rect.height > 0 && image.size.width > 0 && image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        var w = rect.width
        var h = w / aspect
        if h > rect.height {
            h = rect.height
            w = h * aspect
        }
        let x = rect.origin.x + (rect.width - w) / 2.0
        let y = rect.origin.y + (rect.height - h) / 2.0
        image.draw(in: CGRect(x: x, y: y, width: w, height: h))
    }

    private func drawAspectFill(image: NSImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0 && rect.height > 0 && image.size.width > 0 && image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        var w = rect.width
        var h = w / aspect
        if h < rect.height {
            h = rect.height
            w = h * aspect
        }
        let x = rect.origin.x + (rect.width - w) / 2.0
        let y = rect.origin.y + (rect.height - h) / 2.0

        context.saveGState()
        context.clip(to: rect)
        image.draw(in: CGRect(x: x, y: y, width: w, height: h))
        context.restoreGState()
    }

    // MARK: - Context Menu for Foreground Objects
    override public func menu(for event: NSEvent) -> NSMenu? {
        guard combiningMode == .foregroundCombine else {
            return super.menu(for: event)
        }

        let pt = convert(event.locationInWindow, from: nil)
        var clickedPane: Int? = nil

        for (fgOpt, pane) in [(foregroundObject1, 1), (foregroundObject2, 2)] {
            guard let fg = fgOpt else { continue }
            let orientation = (pane == 1) ? orientation1 : orientation2
            let orientedImg = fg.image.transformed(with: orientation)
            let effectiveScale = defaultFitScale(for: fg)
            let w = orientedImg.size.width * effectiveScale
            let h = orientedImg.size.height * effectiveScale

            let dx = pt.x - fg.position.x
            let dy = pt.y - fg.position.y
            let rad = -fg.rotationDegrees * .pi / 180.0
            let localPt = CGPoint(
                x: dx * cos(rad) - dy * sin(rad),
                y: dx * sin(rad) + dy * cos(rad)
            )

            let localRect = CGRect(x: -w/2, y: -h/2, width: w, height: h)
            if localRect.contains(localPt) {
                clickedPane = pane
                selectedObjectPane = pane
                needsDisplay = true
                break
            }
        }

        guard let pane = clickedPane else { return super.menu(for: event) }

        let menu = NSMenu(title: "Foreground Object Menu")

        let flipHItem = NSMenuItem(title: "Flip Object Horizontal", action: #selector(contextFlipHorizontalAction(_:)), keyEquivalent: "")
        flipHItem.target = self
        flipHItem.representedObject = pane
        menu.addItem(flipHItem)

        let flipVItem = NSMenuItem(title: "Flip Object Vertical", action: #selector(contextFlipVerticalAction(_:)), keyEquivalent: "")
        flipVItem.target = self
        flipVItem.representedObject = pane
        menu.addItem(flipVItem)

        menu.addItem(NSMenuItem.separator())

        let zOrderTitle = (pane == 1 && fg1OnTop) || (pane == 2 && !fg1OnTop) ? "Send Object to Back" : "Bring Object to Front"
        let zOrderItem = NSMenuItem(title: zOrderTitle, action: #selector(contextToggleZOrderAction), keyEquivalent: "")
        zOrderItem.target = self
        menu.addItem(zOrderItem)

        menu.addItem(NSMenuItem.separator())

        let tuningItem = NSMenuItem(title: "Vision Detector Tuning", action: nil, keyEquivalent: "")
        let tuningMenu = NSMenu(title: "Vision Detector Tuning")

        let currentMode = (pane == 1) ? foregroundObject1?.detectionMode : foregroundObject2?.detectionMode

        for mode in VisionDetectionMode.allCases {
            let modeItem = NSMenuItem(title: mode.rawValue, action: #selector(contextSelectDetectionModeAction(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = ["pane": pane, "mode": mode] as [String : Any]
            if currentMode == mode {
                modeItem.state = .on
            }
            tuningMenu.addItem(modeItem)
        }

        tuningItem.submenu = tuningMenu
        menu.addItem(tuningItem)

        return menu
    }

    @objc private func contextFlipHorizontalAction(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? Int else { return }
        if pane == 1 {
            foregroundObject1?.isFlippedHorizontal.toggle()
            orientation1.toggleFlipHorizontal()
        } else {
            foregroundObject2?.isFlippedHorizontal.toggle()
            orientation2.toggleFlipHorizontal()
        }
        needsDisplay = true
    }

    @objc private func contextFlipVerticalAction(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? Int else { return }
        if pane == 1 {
            foregroundObject1?.isFlippedVertical.toggle()
            orientation1.toggleFlipVertical()
        } else {
            foregroundObject2?.isFlippedVertical.toggle()
            orientation2.toggleFlipVertical()
        }
        needsDisplay = true
    }

    @objc private func contextToggleZOrderAction() {
        fg1OnTop.toggle()
    }

    @objc private func contextSelectDetectionModeAction(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let pane = dict["pane"] as? Int,
              let mode = dict["mode"] as? VisionDetectionMode else { return }

        onRetuneDetector?(pane, mode)
    }

    // MARK: - Interactive Canvas Mouse Events
    override public func mouseDown(with event: NSEvent) {
        guard combiningMode == .foregroundCombine else {
            super.mouseDown(with: event)
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        dragStartPoint = pt

        for (fgOpt, pane) in [(foregroundObject1, 1), (foregroundObject2, 2)] {
            guard let fg = fgOpt else { continue }

            let orientation = (pane == 1) ? orientation1 : orientation2
            let orientedImg = fg.image.transformed(with: orientation)
            let effectiveScale = defaultFitScale(for: fg)
            let w = orientedImg.size.width * effectiveScale
            let h = orientedImg.size.height * effectiveScale

            let dx = pt.x - fg.position.x
            let dy = pt.y - fg.position.y
            let rad = -fg.rotationDegrees * .pi / 180.0
            let localPt = CGPoint(
                x: dx * cos(rad) - dy * sin(rad),
                y: dx * sin(rad) + dy * cos(rad)
            )

            let rotHandleLocal = CGPoint(x: 0, y: h/2 + 20)
            if hypot(localPt.x - rotHandleLocal.x, localPt.y - rotHandleLocal.y) <= 12 {
                selectedObjectPane = pane
                isRotatingObject = true
                initialObjRotation = fg.rotationDegrees
                needsDisplay = true
                return
            }

            let localCorners = [
                CGPoint(x: -w/2, y: -h/2),
                CGPoint(x: w/2, y: -h/2),
                CGPoint(x: -w/2, y: h/2),
                CGPoint(x: w/2, y: h/2)
            ]
            for c in localCorners {
                if hypot(localPt.x - c.x, localPt.y - c.y) <= 12 {
                    selectedObjectPane = pane
                    isResizingObject = true
                    initialObjScale = fg.scale
                    initialDistToCenter = max(1.0, hypot(pt.x - fg.position.x, pt.y - fg.position.y))
                    needsDisplay = true
                    return
                }
            }

            let localRect = CGRect(x: -w/2, y: -h/2, width: w, height: h)
            if localRect.contains(localPt) {
                selectedObjectPane = pane
                isDraggingObject = true
                initialObjPosition = fg.position
                needsDisplay = true
                notifySelectedObjectChanged()
                return
            }
        }

        selectedObjectPane = nil
        isDraggingObject = false
        isResizingObject = false
        isRotatingObject = false
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        guard combiningMode == .foregroundCombine, let pane = selectedObjectPane else {
            super.mouseDragged(with: event)
            return
        }

        let currentPt = convert(event.locationInWindow, from: nil)

        if isRotatingObject {
            let fg = (pane == 1) ? foregroundObject1 : foregroundObject2
            guard let fgObj = fg else { return }
            let angle = atan2(currentPt.y - fgObj.position.y, currentPt.x - fgObj.position.x) * 180.0 / .pi - 90.0
            if pane == 1 {
                foregroundObject1?.rotationDegrees = angle
            } else {
                foregroundObject2?.rotationDegrees = angle
            }
            notifySelectedObjectChanged()
        } else if isResizingObject {
            let fg = (pane == 1) ? foregroundObject1 : foregroundObject2
            guard let fgObj = fg else { return }
            let currentDist = hypot(currentPt.x - fgObj.position.x, currentPt.y - fgObj.position.y)
            let factor = max(0.1, currentDist / initialDistToCenter)
            if pane == 1 {
                foregroundObject1?.scale = initialObjScale * factor
            } else {
                foregroundObject2?.scale = initialObjScale * factor
            }
            notifySelectedObjectChanged()
        } else if isDraggingObject {
            let deltaX = currentPt.x - dragStartPoint.x
            let deltaY = currentPt.y - dragStartPoint.y
            if pane == 1 {
                foregroundObject1?.position = CGPoint(x: initialObjPosition.x + deltaX, y: initialObjPosition.y + deltaY)
            } else if pane == 2 {
                foregroundObject2?.position = CGPoint(x: initialObjPosition.x + deltaX, y: initialObjPosition.y + deltaY)
            }
            notifySelectedObjectChanged()
        }

        needsDisplay = true
    }

    private func notifySelectedObjectChanged() {
        guard let pane = selectedObjectPane else { return }
        if pane == 1, let fg1 = foregroundObject1 {
            onSelectedObjectChanged?(1, fg1)
        } else if pane == 2, let fg2 = foregroundObject2 {
            onSelectedObjectChanged?(2, fg2)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        isDraggingObject = false
        isResizingObject = false
        isRotatingObject = false
        super.mouseUp(with: event)
    }
}
