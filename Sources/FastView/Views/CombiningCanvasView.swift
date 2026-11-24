import AppKit

public class CombiningCanvasView: NSView {
    public var canvasBackgroundColor: NSColor = .black {
        didSet {
            layer?.backgroundColor = canvasBackgroundColor.cgColor
            needsDisplay = true
        }
    }

    public var image1: NSImage? {
        didSet {
            needsDisplay = true
        }
    }
    public var image2: NSImage? {
        didSet {
            needsDisplay = true
        }
    }

    public var orientation1 = ImageOrientation() {
        didSet {
            needsDisplay = true
        }
    }
    public var orientation2 = ImageOrientation() {
        didSet {
            needsDisplay = true
        }
    }

    public var objects: [ForegroundObject] = [] {
        didSet {
            if !extraSelectedIDs.isEmpty {
                let ids = Set(objects.map(\.id))
                if !extraSelectedIDs.isSubset(of: ids) { extraSelectedIDs.formIntersection(ids) }
            }
            needsDisplay = true
        }
    }

    /// Objects restored before the canvas had a size, with positions as fractions of the canvas.
    private var pendingNormalizedObjects: [(ForegroundObject, CGPoint?)]?

    public func foregroundObject(forPane pane: Int) -> ForegroundObject? {
        return objects.first { $0.sourcePane == pane }
    }

    /// Replaces the object auto-detected from `pane` in place, keeping its z order.
    public func setForegroundObject(_ object: ForegroundObject?, forPane pane: Int) {
        let idx = objects.firstIndex { $0.sourcePane == pane }
        guard var obj = object else {
            if let idx = idx {
                objects.remove(at: idx)
                if let sel = selectedObjectIndex {
                    selectedObjectIndex = sel == idx ? nil : (sel > idx ? sel - 1 : sel)
                }
            }
            return
        }
        obj.sourcePane = pane
        if let idx = idx {
            objects[idx] = obj
        } else {
            objects.append(obj)
        }
        if obj.position == .zero {
            positionFromSlider(pane: pane)
        }
    }

    public func normalizedPosition(of object: ForegroundObject) -> CGPoint? {
        guard bounds.width > 0 && bounds.height > 0 else { return nil }
        return CGPoint(x: object.position.x / bounds.width, y: object.position.y / bounds.height)
    }

    /// Replaces all objects in the given z order (first is bottom). A normalized
    /// position, when given, is a fraction of the canvas size and wins over `position`.
    public func setRestoredObjects(_ restored: [(ForegroundObject, CGPoint?)]) {
        guard bounds.width > 0 && bounds.height > 0 else {
            pendingNormalizedObjects = restored
            objects = restored.map { $0.0 }
            selectedObjectIndex = nil
            return
        }
        pendingNormalizedObjects = nil
        objects = restored.map { obj, norm in
            var o = obj
            if let n = norm {
                o.position = CGPoint(x: n.x * bounds.width, y: n.y * bounds.height)
            }
            return o
        }
        selectedObjectIndex = nil
    }

    private var isRenderingPreview = false

    /// The canvas as it looks now, without selection handles, at most `maxDimension` points on its long side.
    public func renderPreview(maxDimension: CGFloat) -> NSImage? {
        guard bounds.width > 0 && bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        isRenderingPreview = true
        cacheDisplay(in: bounds, to: rep)
        isRenderingPreview = false

        let scale = min(1.0, maxDimension / max(bounds.width, bounds.height))
        let size = NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let full = NSImage(size: bounds.size)
        full.addRepresentation(rep)
        let preview = NSImage(size: size)
        preview.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(origin: .zero, size: size))
        preview.unlockFocus()
        return preview
    }

    /// Called after a colour match with how many objects were matched by their skin, and how many in all.
    public var onColorMatchFinished: ((_ bySkin: Int, _ total: Int, _ referenceHasSkin: Bool) -> Void)?

    /// Gives every other object the colours of the object at `referenceIndex`, led by skin tones.
    public func matchColorsOfOtherObjects(to referenceIndex: Int) {
        guard referenceIndex >= 0 && referenceIndex < objects.count else { return }
        let referenceImage = objects[referenceIndex].image
        let targets = objects.enumerated()
            .filter { $0.offset != referenceIndex }
            .map { (id: $0.element.id, base: $0.element.unadjustedImage ?? $0.element.image) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let reference = ColorMatcher.profile(of: referenceImage) else { return }
            var results: [(id: UUID, adjustment: ColorAdjustment, base: NSImage, adjusted: NSImage)] = []
            var bySkin = 0
            for target in targets {
                guard let profile = ColorMatcher.profile(of: target.base) else { continue }
                let match = ColorMatcher.adjustment(matching: profile, to: reference)
                if let adjusted = ColorMatcher.apply(match.adjustment, to: target.base) {
                    results.append((target.id, match.adjustment, target.base, adjusted))
                    if match.bySkin { bySkin += 1 }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for result in results {
                    guard let i = self.objects.firstIndex(where: { $0.id == result.id }) else { continue }
                    self.objects[i].unadjustedImage = result.base
                    self.objects[i].image = result.adjusted
                    self.objects[i].colorAdjustment = result.adjustment
                }
                self.onColorMatchFinished?(bySkin, results.count, reference.skin != nil)
            }
        }
    }

    public func resetColors(at index: Int) {
        guard index >= 0 && index < objects.count, let base = objects[index].unadjustedImage else { return }
        objects[index].image = base
        objects[index].unadjustedImage = nil
        objects[index].colorAdjustment = nil
    }

    // Resizing happens here rather than in layout() so positions are always in
    // the current size's coordinates, whenever a restore or save reads them.
    override public func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard newSize.width > 0 && newSize.height > 0, newSize != oldSize else { return }

        if let pending = pendingNormalizedObjects {
            setRestoredObjects(pending)
            return
        }
        // Keep objects at the same place relative to the canvas; their size already follows it.
        guard oldSize.width > 0 && oldSize.height > 0 else { return }
        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height
        for i in objects.indices {
            objects[i].position = CGPoint(x: objects[i].position.x * sx, y: objects[i].position.y * sy)
        }
    }

    public var showBackground1: Bool = true { didSet { needsDisplay = true } }
    public var showBackground2: Bool = true { didSet { needsDisplay = true } }

    public var combiningMode: CanvasCombiningMode = .split {
        didSet {
            if combiningMode != .foregroundCombine { endCarving() }
            needsDisplay = true
        }
    }

    /// Shown in the status bar: instructions and results of carving.
    public var onStatusMessage: ((String) -> Void)?

    private enum CarveAction {
        /// Keep only the foreground inside the outline.
        case carveOut
        /// Clear what is inside the outline.
        case erase
        /// Add the foreground inside the outline as a new object on top.
        case newObject

        var carve: (keepsInside: Bool, detectsForeground: Bool) {
            return self == .erase ? (false, false) : (true, true)
        }
    }

    // Carving: while set, a drag draws an outline over this object that then carves it.
    private var carveObjectID: UUID?
    private var carveAction: CarveAction = .carveOut
    private var carvePath: [CGPoint] = []
    private var isApplyingCarve = false
    private var carveKeyMonitor: Any?

    /// Called with the object's index in `objects`.
    public var onRetuneDetector: ((Int, VisionDetectionMode) -> Void)?
    public var onSelectedObjectChanged: ((Int, ForegroundObject) -> Void)?

    // Merge Mode Parameters
    public var mergeLeftPercent: CGFloat = 50.0 { didSet { needsDisplay = true } }
    public var mergeRightPercent: CGFloat = 50.0 { didSet { needsDisplay = true } }
    public var alphaGradientPercent: CGFloat = 20.0 { didSet { needsDisplay = true } }

    // Foreground Combine Sliders (0..100)
    public var fgOffset1Percent: CGFloat = 50.0 {
        didSet {
            positionFromSlider(pane: 1)
            needsDisplay = true
        }
    }

    public var fgOffset2Percent: CGFloat = 50.0 {
        didSet {
            positionFromSlider(pane: 2)
            needsDisplay = true
        }
    }

    // Interactivity
    public var selectedObjectIndex: Int? = nil {
        didSet {
            if selectedObjectIndex == nil { extraSelectedIDs.removeAll() }
            needsDisplay = true
            if let idx = selectedObjectIndex, idx >= 0 && idx < objects.count {
                let pane = idx + 1
                onSelectedObjectChanged?(pane, objects[idx])
            }
        }
    }

    public var selectedObjectPane: Int? {
        get {
            guard let idx = selectedObjectIndex else { return nil }
            return idx + 1
        }
        set {
            extraSelectedIDs.removeAll()
            if let val = newValue, val >= 1 && val <= objects.count {
                selectedObjectIndex = val - 1
            } else {
                selectedObjectIndex = nil
            }
        }
    }

    /// Objects selected along with `selectedObjectIndex` (⇧/⌘-click or a drag over empty canvas);
    /// they move, resize and rotate together.
    private var extraSelectedIDs: Set<UUID> = [] { didSet { needsDisplay = true } }

    /// Indices of all selected objects, in z order.
    var selectedIndices: [Int] {
        guard let primary = selectedObjectIndex, primary >= 0 && primary < objects.count else { return [] }
        return objects.indices.filter { $0 == primary || extraSelectedIDs.contains(objects[$0].id) }
    }

    private func isSelected(_ i: Int) -> Bool {
        return i == selectedObjectIndex || extraSelectedIDs.contains(objects[i].id)
    }

    /// Makes `indices` the selection, with `primary` (one of them) as `selectedObjectIndex`.
    private func setSelection(_ indices: [Int], primary: Int?) {
        let primary = primary ?? indices.last
        extraSelectedIDs = Set(indices.filter { $0 != primary }.map { objects[$0].id })
        if selectedObjectIndex != primary { selectedObjectIndex = primary }
    }

    private struct ObjectTransform { let position: CGPoint; let scale: CGFloat; let rotation: CGFloat }

    // Moving, resizing and rotating several objects at once.
    private var groupStart: [UUID: ObjectTransform] = [:]
    private var groupCenter: CGPoint = .zero
    private var isResizingGroup = false
    private var isRotatingGroup = false

    // Rubber-band selection over empty canvas.
    private var selectionRect: CGRect?
    private var selectionBase: [Int] = []

    private var isDraggingObject: Bool = false
    private var isResizingObject: Bool = false
    private var isRotatingObject: Bool = false
    private var isBottomRotateHandle: Bool = false

    private var dragStartPoint: CGPoint = .zero
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
        layer?.backgroundColor = canvasBackgroundColor.cgColor
    }

    override public var isFlipped: Bool { return false }

    public func addObject(_ object: ForegroundObject) {
        var obj = object
        if obj.position == .zero {
            let midX = bounds.width > 0 ? bounds.width / 2.0 : 300
            let midY = bounds.height > 0 ? bounds.height / 2.0 : 300
            let offset = CGFloat(objects.count * 20)
            obj.position = CGPoint(x: midX + offset, y: midY + offset)
        }
        objects.append(obj)
        selectedObjectIndex = objects.count - 1
        needsDisplay = true
    }

    public func removeSelectedObject() {
        guard let idx = selectedObjectIndex, idx >= 0 && idx < objects.count else { return }
        objects.remove(at: idx)
        if objects.isEmpty {
            selectedObjectIndex = nil
        } else {
            selectedObjectIndex = min(idx, objects.count - 1)
        }
        needsDisplay = true
    }

    /// Places the object auto-detected from `pane` on its slider track (pane 1 left, pane 2 right).
    public func positionFromSlider(pane: Int) {
        guard bounds.width > 0 && bounds.height > 0,
              let idx = objects.firstIndex(where: { $0.sourcePane == pane }) else { return }
        if isDraggingObject && isSelected(idx) { return }
        let midX = bounds.width / 2.0
        let midY = bounds.height / 2.0
        if pane == 1 {
            let defaultX = bounds.width * 0.25
            objects[idx].position = CGPoint(x: defaultX + (midX - defaultX) * (fgOffset1Percent / 100.0), y: midY)
        } else {
            let defaultX = bounds.width * 0.75
            objects[idx].position = CGPoint(x: defaultX - (defaultX - midX) * (fgOffset2Percent / 100.0), y: midY)
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
        context.setFillColor(canvasBackgroundColor.cgColor)
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

        if let img1 = image1 {
            let rect1 = CGRect(x: 0, y: 0, width: halfWidth, height: rect.height)
            drawAspectFit(image: img1, orientation: orientation1, in: rect1, context: context)
        }

        if let img2 = image2 {
            let rect2 = CGRect(x: halfWidth, y: 0, width: halfWidth, height: rect.height)
            drawAspectFit(image: img2, orientation: orientation2, in: rect2, context: context)
        }

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(2.0)
        context.move(to: CGPoint(x: halfWidth, y: 0))
        context.addLine(to: CGPoint(x: halfWidth, y: rect.height))
        context.strokePath()
    }

    // MARK: - Merge View with Alpha Gradient
    private func drawMergeView(in rect: CGRect, context: CGContext) {
        let img1 = image1
        let img2 = image2

        if let img1 = img1 {
            let leftWidth = rect.width * (mergeLeftPercent / 100.0)
            let leftRect = CGRect(x: 0, y: 0, width: max(leftWidth, 10), height: rect.height)
            drawAspectFill(image: img1, orientation: orientation1, in: leftRect, context: context)
        }

        if let img2 = img2 {
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
                    drawAspectFill(image: img2, orientation: orientation2, in: rightRect, context: context)

                    context.setBlendMode(.destinationIn)
                    context.drawLinearGradient(gradient, start: blendStart, end: blendEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.endTransparencyLayer()
                    context.restoreGState()
                    return
                }
            }

            drawAspectFill(image: img2, orientation: orientation2, in: rightRect, context: context)
            context.restoreGState()
        }
    }

    // MARK: - Foreground Combine View
    private func drawForegroundCombineView(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setAlpha(0.35)
        let halfWidth = rect.width / 2.0

        if showBackground1, let img1 = image1 {
            drawAspectFit(image: img1, orientation: orientation1, in: CGRect(x: 0, y: 0, width: halfWidth, height: rect.height), context: context)
        }
        if showBackground2, let img2 = image2 {
            drawAspectFit(image: img2, orientation: orientation2, in: CGRect(x: halfWidth, y: 0, width: halfWidth, height: rect.height), context: context)
        }
        context.restoreGState()

        // 1. Draw all object images in array order (bottom to top)
        for obj in objects {
            drawForegroundObjectBody(obj, in: rect, context: context)
        }

        // 2. Overlay pass: Draw selection outline & handles on top of ALL objects for selected object
        if !isRenderingPreview {
            let selected = selectedIndices
            if selected.count == 1 {
                drawSelectedObjectHandles(objects[selected[0]], in: rect, context: context)
            } else if selected.count > 1 {
                for i in selected { drawObjectOutline(objects[i], context: context) }
                drawGroupHandles(groupBounds(of: selected), context: context)
            }
            if let band = selectionRect {
                context.saveGState()
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
                context.fill(band)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.0)
                context.stroke(band.insetBy(dx: 0.5, dy: 0.5))
                context.restoreGState()
            }
        }

        // 3. The carve outline being drawn
        if !isRenderingPreview && carvePath.count > 1 {
            drawCarvePath(in: context)
        }
    }

    private func drawForegroundObjectBody(_ obj: ForegroundObject, in rect: CGRect, context: CGContext) {
        let baseImg = obj.effects.featherEdges ? featheredImage(of: obj) : obj.image
        let effectiveScale = defaultFitScale(for: obj)
        let targetWidth = baseImg.size.width * effectiveScale
        let targetHeight = baseImg.size.height * effectiveScale

        if obj.effects.shadow, let shadow = cachedEffect(.shadow, of: obj) {
            // Falls straight down in canvas space, whatever the object's rotation.
            context.saveGState()
            context.translateBy(x: obj.position.x, y: obj.position.y - max(targetWidth, targetHeight) * ObjectEffectsRenderer.shadowDrop)
            context.rotate(by: obj.rotationDegrees * .pi / 180.0)
            context.scaleBy(x: obj.isFlippedHorizontal ? -1 : 1, y: obj.isFlippedVertical ? -1 : 1)
            let pad = ObjectEffectsRenderer.shadowPadding
            shadow.draw(in: CGRect(x: -targetWidth * (0.5 + pad), y: -targetHeight * (0.5 + pad),
                                   width: targetWidth * (1 + 2 * pad), height: targetHeight * (1 + 2 * pad)),
                        from: .zero, operation: .sourceOver, fraction: 0.6)
            context.restoreGState()
        }

        context.saveGState()
        context.translateBy(x: obj.position.x, y: obj.position.y)
        context.rotate(by: obj.rotationDegrees * .pi / 180.0)

        let scaleX: CGFloat = obj.isFlippedHorizontal ? -1.0 : 1.0
        let scaleY: CGFloat = obj.isFlippedVertical ? -1.0 : 1.0
        if scaleX != 1.0 || scaleY != 1.0 {
            context.scaleBy(x: scaleX, y: scaleY)
        }

        let drawRect = CGRect(
            x: -targetWidth / 2.0,
            y: -targetHeight / 2.0,
            width: targetWidth,
            height: targetHeight
        )

        baseImg.draw(in: drawRect)

        context.restoreGState()
    }

    // MARK: - Effects

    private enum EffectKind { case feather, shadow }
    private struct EffectKey: Hashable { let id: UUID; let kind: EffectKind }

    /// Feathered copies and shadows of object images, by object, for the image they were made from.
    private var effectCache: [EffectKey: (source: ObjectIdentifier, image: NSImage)] = [:]
    private var effectPending: Set<EffectKey> = []

    /// The object's image with feathered edges; the plain image until the feathered one is ready.
    private func featheredImage(of obj: ForegroundObject) -> NSImage {
        cachedEffect(.feather, of: obj) ?? obj.image
    }

    /// A cached effect image for the object's current image; nil while it is being made (the canvas redraws when ready).
    private func cachedEffect(_ kind: EffectKind, of obj: ForegroundObject) -> NSImage? {
        let key = EffectKey(id: obj.id, kind: kind)
        let source = ObjectIdentifier(obj.image)
        if let cached = effectCache[key], cached.source == source { return cached.image }
        if !effectPending.contains(key) {
            effectPending.insert(key)
            let image = obj.image
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let made = kind == .feather ? ObjectEffectsRenderer.feather(image) : ObjectEffectsRenderer.shadow(of: image)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.effectPending.remove(key)
                    if let made = made { self.effectCache[key] = (source, made) }
                    self.needsDisplay = true
                }
            }
        }
        return nil
    }

    /// The object's corners' bounding box on the canvas.
    func canvasBounds(of obj: ForegroundObject) -> CGRect {
        let scale = defaultFitScale(for: obj)
        let w = obj.image.size.width * scale, h = obj.image.size.height * scale
        let rad = obj.rotationDegrees * .pi / 180.0
        let corners = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map { x, y in
            CGPoint(x: obj.position.x + x * cos(rad) - y * sin(rad), y: obj.position.y + x * sin(rad) + y * cos(rad))
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Draws the objects at `indices` (in z order) into an RGBA bitmap of `area` (canvas points) at `scale`
    /// pixels per point, over `background` (transparent when nil), with their effects.
    func renderObjects(_ indices: [Int], area: CGRect, scale: CGFloat, background: NSColor?) -> RGBABuffer? {
        let w = max(1, Int((area.width * scale).rounded())), h = max(1, Int((area.height * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if let background = background {
                ctx.setFillColor(background.usingColorSpace(.sRGB)?.cgColor ?? background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -area.minX, y: -area.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for i in indices where i >= 0 && i < objects.count {
                drawForegroundObjectBody(objects[i], in: bounds, context: ctx)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return ok ? RGBABuffer(width: w, height: h, pixels: pixels) : nil
    }

    /// Matches the object's colours and light to the objects beneath it, led by skin tones.
    public func harmonizeWithObjectsBelow(_ index: Int) {
        guard index > 0, index < objects.count else {
            onEffectMessage?("There are no objects beneath this one to match.")
            return
        }
        let obj = objects[index]
        let area = canvasBounds(of: obj).insetBy(dx: -canvasBounds(of: obj).width * 0.25, dy: -canvasBounds(of: obj).height * 0.25).intersection(bounds)
        guard !area.isNull, let below = renderObjects(Array(0..<index), area: area, scale: 1, background: nil),
              let belowImage = below.makeCGImage() else { return }
        let reference = NSImage(cgImage: belowImage, size: area.size)
        let base = obj.unadjustedImage ?? obj.image
        let id = obj.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let refProfile = ColorMatcher.profile(of: reference), let profile = ColorMatcher.profile(of: base) else {
                DispatchQueue.main.async { self?.onEffectMessage?("There is too little beneath this object to match.") }
                return
            }
            let match = ColorMatcher.adjustment(matching: profile, to: refProfile)
            guard let adjusted = ColorMatcher.apply(match.adjustment, to: base) else { return }
            DispatchQueue.main.async {
                guard let self = self, let i = self.objects.firstIndex(where: { $0.id == id }) else { return }
                self.objects[i].unadjustedImage = base
                self.objects[i].image = adjusted
                self.objects[i].colorAdjustment = match.adjustment
            }
        }
    }

    /// Short notices from effect actions, for the status bar.
    public var onEffectMessage: ((String) -> Void)?


    private func drawSelectedObjectHandles(_ obj: ForegroundObject, in rect: CGRect, context: CGContext) {
        context.saveGState()

        let baseImg = obj.image
        let effectiveScale = defaultFitScale(for: obj)
        let targetWidth = baseImg.size.width * effectiveScale
        let targetHeight = baseImg.size.height * effectiveScale

        context.translateBy(x: obj.position.x, y: obj.position.y)
        context.rotate(by: obj.rotationDegrees * .pi / 180.0)

        let scaleX: CGFloat = obj.isFlippedHorizontal ? -1.0 : 1.0
        let scaleY: CGFloat = obj.isFlippedVertical ? -1.0 : 1.0
        if scaleX != 1.0 || scaleY != 1.0 {
            context.scaleBy(x: scaleX, y: scaleY)
        }

        let drawRect = CGRect(
            x: -targetWidth / 2.0,
            y: -targetHeight / 2.0,
            width: targetWidth,
            height: targetHeight
        )

        // Bounding Box
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2.0)
        context.stroke(drawRect)

        let handleSize: CGFloat = 10.0

        // Corner handles (4)
        let cornerHandles = [
            CGPoint(x: drawRect.minX, y: drawRect.minY),
            CGPoint(x: drawRect.maxX, y: drawRect.minY),
            CGPoint(x: drawRect.minX, y: drawRect.maxY),
            CGPoint(x: drawRect.maxX, y: drawRect.maxY)
        ]

        // Vertical side midpoint handles (2) - half-length of vertical sides
        let sideHandles = [
            CGPoint(x: drawRect.minX, y: 0),
            CGPoint(x: drawRect.maxX, y: 0)
        ]

        context.setFillColor(NSColor.controlAccentColor.cgColor)
        for h in (cornerHandles + sideHandles) {
            let hRect = CGRect(x: h.x - handleSize/2, y: h.y - handleSize/2, width: handleSize, height: handleSize)
            context.fill(hRect)
        }

        // Top rotate handle
        let topRotateStemY = drawRect.maxY + 20.0
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: 0, y: drawRect.maxY))
        context.addLine(to: CGPoint(x: 0, y: topRotateStemY))
        context.strokePath()

        let topRotateCircleRect = CGRect(x: -6, y: topRotateStemY - 6, width: 12, height: 12)
        context.setFillColor(NSColor.systemYellow.cgColor)
        context.fillEllipse(in: topRotateCircleRect)

        // Bottom rotate handle
        let bottomRotateStemY = drawRect.minY - 20.0
        context.move(to: CGPoint(x: 0, y: drawRect.minY))
        context.addLine(to: CGPoint(x: 0, y: bottomRotateStemY))
        context.strokePath()

        let bottomRotateCircleRect = CGRect(x: -6, y: bottomRotateStemY - 6, width: 12, height: 12)
        context.setFillColor(NSColor.systemYellow.cgColor)
        context.fillEllipse(in: bottomRotateCircleRect)

        context.restoreGState()
    }

    /// The rotated frame of a selected object, without handles.
    private func drawObjectOutline(_ obj: ForegroundObject, context: CGContext) {
        let scale = defaultFitScale(for: obj)
        let w = obj.image.size.width * scale, h = obj.image.size.height * scale
        context.saveGState()
        context.translateBy(x: obj.position.x, y: obj.position.y)
        context.rotate(by: obj.rotationDegrees * .pi / 180.0)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.stroke(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        context.restoreGState()
    }

    private func groupBounds(of indices: [Int]) -> CGRect {
        return indices.reduce(CGRect.null) { $0.union(canvasBounds(of: objects[$1])) }
    }

    private static let groupRotateStem: CGFloat = 20.0

    private func groupCornerHandles(_ box: CGRect) -> [CGPoint] {
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
    }

    private func groupRotateHandle(_ box: CGRect) -> CGPoint {
        return CGPoint(x: box.midX, y: box.maxY + Self.groupRotateStem)
    }

    /// The selection's bounding box with corner handles (resize all) and a rotate handle above.
    private func drawGroupHandles(_ box: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6.0, 3.0])
        context.stroke(box)
        context.setLineDash(phase: 0, lengths: [])

        let handleSize: CGFloat = 10.0
        context.setFillColor(NSColor.controlAccentColor.cgColor)
        for h in groupCornerHandles(box) {
            context.fill(CGRect(x: h.x - handleSize / 2, y: h.y - handleSize / 2, width: handleSize, height: handleSize))
        }

        let rot = groupRotateHandle(box)
        context.move(to: CGPoint(x: box.midX, y: box.maxY))
        context.addLine(to: rot)
        context.strokePath()
        context.setFillColor(NSColor.systemYellow.cgColor)
        context.fillEllipse(in: CGRect(x: rot.x - 6, y: rot.y - 6, width: 12, height: 12))
        context.restoreGState()
    }

    /// Remembers where the selected objects start, for moving, resizing or rotating them together.
    private func beginGroupTransform(around center: CGPoint) {
        groupCenter = center
        groupStart = [:]
        for i in selectedIndices {
            let o = objects[i]
            groupStart[o.id] = ObjectTransform(position: o.position, scale: o.scale, rotation: o.rotationDegrees)
        }
    }

    private func drawCarvePath(in context: CGContext) {
        context.saveGState()
        let cgPath = CGMutablePath()
        cgPath.addLines(between: carvePath)
        cgPath.closeSubpath()

        let color: NSColor = carveAction == .erase ? .systemRed : .controlAccentColor
        context.addPath(cgPath)
        context.setFillColor(color.withAlphaComponent(0.25).cgColor)
        context.fillPath()

        context.addPath(cgPath)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(3.0)
        context.setLineDash(phase: 0, lengths: [6.0, 3.0])
        context.strokePath()
        context.restoreGState()
    }

    /// Draws `image` with `orientation` applied as a context transform, filling `target` (sized in oriented space).
    private func drawOriented(image: NSImage, orientation: ImageOrientation, in target: CGRect, context: CGContext) {
        let size = orientation.orientedSize(target.size)
        context.saveGState()
        context.translateBy(x: target.midX, y: target.midY)
        if orientation.isFlippedHorizontal { context.scaleBy(x: -1.0, y: 1.0) }
        if orientation.isFlippedVertical { context.scaleBy(x: 1.0, y: -1.0) }
        context.rotate(by: orientation.rotationDegrees * .pi / 180.0)
        image.draw(in: CGRect(x: -size.width / 2.0, y: -size.height / 2.0, width: size.width, height: size.height))
        context.restoreGState()
    }

    private func drawAspectFit(image: NSImage, orientation: ImageOrientation, in rect: CGRect, context: CGContext) {
        let imgSize = orientation.orientedSize(image.size)
        guard rect.width > 0 && rect.height > 0 && imgSize.width > 0 && imgSize.height > 0 else { return }
        let aspect = imgSize.width / imgSize.height
        var w = rect.width
        var h = w / aspect
        if h > rect.height {
            h = rect.height
            w = h * aspect
        }
        let x = rect.origin.x + (rect.width - w) / 2.0
        let y = rect.origin.y + (rect.height - h) / 2.0
        drawOriented(image: image, orientation: orientation, in: CGRect(x: x, y: y, width: w, height: h), context: context)
    }

    private func drawAspectFill(image: NSImage, orientation: ImageOrientation, in rect: CGRect, context: CGContext) {
        let imgSize = orientation.orientedSize(image.size)
        guard rect.width > 0 && rect.height > 0 && imgSize.width > 0 && imgSize.height > 0 else { return }
        let aspect = imgSize.width / imgSize.height
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
        drawOriented(image: image, orientation: orientation, in: CGRect(x: x, y: y, width: w, height: h), context: context)
        context.restoreGState()
    }

    private func isPixelOpaque(in image: NSImage, atNormalizedPoint normPt: CGPoint) -> Bool {
        guard normPt.x >= 0 && normPt.x <= 1 && normPt.y >= 0 && normPt.y <= 1 else { return false }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return false }

        let pixelX = max(0, min(width - 1, Int(normPt.x * CGFloat(width))))
        let pixelY = max(0, min(height - 1, Int((1.0 - normPt.y) * CGFloat(height))))

        guard let crop = cgImage.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)) else { return false }

        var alpha: UInt8 = 0
        if let context = CGContext(
            data: &alpha,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) {
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return alpha > 12
        }
        return true
    }

    // MARK: - Context Menu for Foreground Objects
    override public func menu(for event: NSEvent) -> NSMenu? {
        guard combiningMode == .foregroundCombine else {
            return super.menu(for: event)
        }

        let pt = convert(event.locationInWindow, from: nil)
        var clickedIdx: Int? = nil

        for i in stride(from: objects.count - 1, through: 0, by: -1) {
            let fg = objects[i]
            let effectiveScale = defaultFitScale(for: fg)
            let w = fg.image.size.width * effectiveScale
            let h = fg.image.size.height * effectiveScale

            let dx = pt.x - fg.position.x
            let dy = pt.y - fg.position.y
            let rad = -fg.rotationDegrees * .pi / 180.0
            let localPt = CGPoint(
                x: dx * cos(rad) - dy * sin(rad),
                y: dx * sin(rad) + dy * cos(rad)
            )

            let xInRect = (fg.isFlippedHorizontal ? -localPt.x : localPt.x) + w / 2.0
            let yInRect = (fg.isFlippedVertical ? -localPt.y : localPt.y) + h / 2.0
            let normPt = CGPoint(x: xInRect / w, y: yInRect / h)

            if normPt.x >= 0 && normPt.x <= 1 && normPt.y >= 0 && normPt.y <= 1 {
                if isPixelOpaque(in: fg.image, atNormalizedPoint: normPt) {
                    clickedIdx = i
                    // Right-clicking one of several selected objects keeps them selected.
                    setSelection(isSelected(i) ? selectedIndices : [i], primary: i)
                    needsDisplay = true
                    break
                }
            }
        }

        guard let idx = clickedIdx else { return super.menu(for: event) }

        let menu = NSMenu(title: "Foreground Object Menu")
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(title: "Copy Object to Clipboard", action: #selector(contextCopyObjectAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = idx
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        let matchItem = NSMenuItem(title: "Match Other Objects' Colors to This Object", action: #selector(contextMatchColorsAction(_:)), keyEquivalent: "")
        matchItem.target = self
        matchItem.representedObject = idx
        matchItem.isEnabled = objects.count > 1
        menu.addItem(matchItem)

        let resetColorsItem = NSMenuItem(title: "Reset Object Colors", action: #selector(contextResetColorsAction(_:)), keyEquivalent: "")
        resetColorsItem.target = self
        resetColorsItem.representedObject = idx
        resetColorsItem.isEnabled = objects[idx].colorAdjustment != nil
        menu.addItem(resetColorsItem)

        let harmonizeItem = NSMenuItem(title: "Match Colors and Light to Objects Below", action: #selector(contextHarmonizeAction(_:)), keyEquivalent: "")
        harmonizeItem.target = self
        harmonizeItem.representedObject = idx
        harmonizeItem.isEnabled = idx > 0
        menu.addItem(harmonizeItem)

        menu.addItem(NSMenuItem.separator())

        let shadowItem = NSMenuItem(title: "Drop Shadow", action: #selector(contextToggleShadowAction(_:)), keyEquivalent: "")
        shadowItem.target = self
        shadowItem.representedObject = idx
        shadowItem.state = objects[idx].effects.shadow ? .on : .off
        menu.addItem(shadowItem)

        let featherItem = NSMenuItem(title: "Feather Edges", action: #selector(contextToggleFeatherAction(_:)), keyEquivalent: "")
        featherItem.target = self
        featherItem.representedObject = idx
        featherItem.state = objects[idx].effects.featherEdges ? .on : .off
        menu.addItem(featherItem)

        menu.addItem(NSMenuItem.separator())

        let flipHItem = NSMenuItem(title: "Flip Object Horizontal", action: #selector(contextFlipHorizontalAction(_:)), keyEquivalent: "")
        flipHItem.target = self
        flipHItem.representedObject = idx
        menu.addItem(flipHItem)

        let flipVItem = NSMenuItem(title: "Flip Object Vertical", action: #selector(contextFlipVerticalAction(_:)), keyEquivalent: "")
        flipVItem.target = self
        flipVItem.representedObject = idx
        menu.addItem(flipVItem)

        menu.addItem(NSMenuItem.separator())

        // Z-Ordering options
        let frontItem = NSMenuItem(title: "Bring to Front", action: #selector(contextBringToFrontAction(_:)), keyEquivalent: "")
        frontItem.target = self
        frontItem.representedObject = idx
        menu.addItem(frontItem)

        let backItem = NSMenuItem(title: "Send to Back", action: #selector(contextSendToBackAction(_:)), keyEquivalent: "")
        backItem.target = self
        backItem.representedObject = idx
        menu.addItem(backItem)

        let upItem = NSMenuItem(title: "Move Object Up", action: #selector(contextMoveUpAction(_:)), keyEquivalent: "")
        upItem.target = self
        upItem.representedObject = idx
        upItem.isEnabled = (idx < objects.count - 1)
        menu.addItem(upItem)

        let downItem = NSMenuItem(title: "Move Object Down", action: #selector(contextMoveDownAction(_:)), keyEquivalent: "")
        downItem.target = self
        downItem.representedObject = idx
        downItem.isEnabled = (idx > 0)
        menu.addItem(downItem)

        menu.addItem(NSMenuItem.separator())

        let carveItem = NSMenuItem(title: "Carve Out Object…", action: #selector(contextCarveOutAction(_:)), keyEquivalent: "")
        carveItem.target = self
        carveItem.representedObject = idx
        menu.addItem(carveItem)

        let eraseItem = NSMenuItem(title: "Erase Part of Object…", action: #selector(contextErasePartAction(_:)), keyEquivalent: "")
        eraseItem.target = self
        eraseItem.representedObject = idx
        menu.addItem(eraseItem)

        let newObjectItem = NSMenuItem(title: "New Object from Region…", action: #selector(contextNewObjectFromRegionAction(_:)), keyEquivalent: "")
        newObjectItem.target = self
        newObjectItem.representedObject = idx
        menu.addItem(newObjectItem)

        let undoCarveItem = NSMenuItem(title: "Undo Carving", action: #selector(contextUndoCarvingAction(_:)), keyEquivalent: "")
        undoCarveItem.target = self
        undoCarveItem.representedObject = idx
        undoCarveItem.isEnabled = objects[idx].imageBeforeCarving != nil
        menu.addItem(undoCarveItem)

        menu.addItem(NSMenuItem.separator())

        let tuningItem = NSMenuItem(title: "Vision Detector Tuning", action: nil, keyEquivalent: "")
        let tuningMenu = NSMenu(title: "Vision Detector Tuning")
        let currentMode = objects[idx].detectionMode

        for mode in VisionDetectionMode.allCases {
            let modeItem = NSMenuItem(title: mode.rawValue, action: #selector(contextSelectDetectionModeAction(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = ["index": idx, "mode": mode] as [String : Any]
            if currentMode == mode {
                modeItem.state = .on
            }
            tuningMenu.addItem(modeItem)
        }

        tuningItem.submenu = tuningMenu
        menu.addItem(tuningItem)

        menu.addItem(NSMenuItem.separator())

        let removeItem = NSMenuItem(title: "Remove Object from Canvas", action: #selector(contextRemoveObjectAction(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = idx
        menu.addItem(removeItem)

        return menu
    }

    @objc private func contextCopyObjectAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        let fg = objects[idx]

        var copyOrientation = ImageOrientation()
        copyOrientation.isFlippedHorizontal = fg.isFlippedHorizontal
        copyOrientation.isFlippedVertical = fg.isFlippedVertical
        let flippedImage = fg.image.transformed(with: copyOrientation)

        NSPasteboard.general.copyImage(flippedImage)
    }

    @objc private func contextMatchColorsAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        matchColorsOfOtherObjects(to: idx)
    }

    @objc private func contextHarmonizeAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        harmonizeWithObjectsBelow(idx)
    }

    @objc private func contextToggleShadowAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        objects[idx].effects.shadow.toggle()
    }

    @objc private func contextToggleFeatherAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        objects[idx].effects.featherEdges.toggle()
    }

    @objc private func contextResetColorsAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        resetColors(at: idx)
    }

    @objc private func contextFlipHorizontalAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        objects[idx].isFlippedHorizontal.toggle()
        needsDisplay = true
    }

    @objc private func contextFlipVerticalAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        objects[idx].isFlippedVertical.toggle()
        needsDisplay = true
    }

    @objc private func contextBringToFrontAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        let obj = objects.remove(at: idx)
        objects.append(obj)
        selectedObjectIndex = objects.count - 1
    }

    @objc private func contextSendToBackAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        let obj = objects.remove(at: idx)
        objects.insert(obj, at: 0)
        selectedObjectIndex = 0
    }

    @objc private func contextMoveUpAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count - 1 else { return }
        objects.swapAt(idx, idx + 1)
        selectedObjectIndex = idx + 1
    }

    @objc private func contextMoveDownAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx > 0 else { return }
        objects.swapAt(idx, idx - 1)
        selectedObjectIndex = idx - 1
    }

    @objc private func contextRemoveObjectAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        selectedObjectIndex = idx
        removeSelectedObject()
    }

    @objc private func contextCarveOutAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        beginCarving(objectID: objects[idx].id, action: .carveOut)
    }

    @objc private func contextErasePartAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        beginCarving(objectID: objects[idx].id, action: .erase)
    }

    @objc private func contextNewObjectFromRegionAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        beginCarving(objectID: objects[idx].id, action: .newObject)
    }

    @objc private func contextUndoCarvingAction(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < objects.count else { return }
        let id = objects[idx].id
        ForegroundSource.undoCarves(of: objects[idx]) { [weak self] restored, rect in
            guard let self = self, let i = self.objects.firstIndex(where: { $0.id == id }) else { return }
            self.objects[i] = self.placed(restored, coveringRect: rect, of: self.objects[i])
        }
    }

    // MARK: - Carving

    private func beginCarving(objectID: UUID, action: CarveAction) {
        endCarving()
        carveObjectID = objectID
        carveAction = action
        NSCursor.crosshair.push()
        carveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.carveObjectID != nil, event.keyCode == 53 else { return event } // Escape
            self.endCarving()
            self.onStatusMessage?("Cancelled")
            return nil
        }
        switch action {
        case .carveOut: onStatusMessage?("Draw around the part of the object to keep; it snaps to edges (hold ⌥ on release to not snap); Esc cancels")
        case .erase: onStatusMessage?("Draw around the part of the object to erase; it snaps to edges (hold ⌥ on release to not snap); Esc cancels")
        case .newObject: onStatusMessage?("Draw around the part to add as a new object; it snaps to edges (hold ⌥ on release to not snap); Esc cancels")
        }
    }

    private func endCarving() {
        guard carveObjectID != nil else { return }
        carveObjectID = nil
        carvePath = []
        needsDisplay = true
        NSCursor.pop()
        if let monitor = carveKeyMonitor {
            NSEvent.removeMonitor(monitor)
            carveKeyMonitor = nil
        }
    }

    /// The point as fractions of the object's image (bottom-left origin), undoing its placement,
    /// rotation and flips; outside 0...1 when the point misses the object's frame.
    private func normalizedPoint(_ pt: CGPoint, in fg: ForegroundObject) -> CGPoint {
        let effectiveScale = defaultFitScale(for: fg)
        let w = fg.image.size.width * effectiveScale
        let h = fg.image.size.height * effectiveScale
        let dx = pt.x - fg.position.x
        let dy = pt.y - fg.position.y
        let rad = -fg.rotationDegrees * .pi / 180.0
        let localPt = CGPoint(
            x: dx * cos(rad) - dy * sin(rad),
            y: dx * sin(rad) + dy * cos(rad)
        )
        let xInRect = (fg.isFlippedHorizontal ? -localPt.x : localPt.x) + w / 2.0
        let yInRect = (fg.isFlippedVertical ? -localPt.y : localPt.y) + h / 2.0
        return CGPoint(x: xInRect / w, y: yInRect / h)
    }

    /// Applies the drawn outline, first snapped to the object's edges unless `snapsToEdges` is off.
    private func finishCarvePath(snapsToEdges: Bool) {
        guard let objectID = carveObjectID else { return }
        let path = carvePath
        let action = carveAction
        endCarving()
        guard path.count > 2, let idx = objects.firstIndex(where: { $0.id == objectID }) else { return }
        let source = objects[idx]
        let drawn = path.map { normalizedPoint($0, in: source) }
        // A new object starts as a copy of its source that belongs to no pane.
        var target = source
        if action == .newObject {
            target.id = UUID()
            target.sourcePane = nil
        }
        isApplyingCarve = true
        onStatusMessage?(action == .erase ? "Erasing…" : "Detecting the foreground in the outline…")
        // The snapped outline is what gets saved, so restoring does not snap again.
        let edgeImage = snapsToEdges ? (source.unadjustedImage ?? source.image).cgImage(forProposedRect: nil, context: nil, hints: nil) : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let points = edgeImage.map { ObjectCarver.snapToEdges(drawn, in: $0) } ?? drawn
            let carve = ObjectCarve(points: points, keepsInside: action.carve.keepsInside, detectsForeground: action.carve.detectsForeground)
            DispatchQueue.main.async { [weak self] in
                self?.applyCarve(carve, action: action, to: target, sourceID: objectID)
            }
        }
    }

    private func applyCarve(_ carve: ObjectCarve, action: CarveAction, to target: ForegroundObject, sourceID objectID: UUID) {
        ForegroundSource.applyCarves([carve], to: target) { [weak self] updated, rect in
            guard let self = self else { return }
            self.isApplyingCarve = false
            guard let rect = rect, let i = self.objects.firstIndex(where: { $0.id == objectID }) else {
                NSSound.beep()
                self.onStatusMessage?("Nothing of the object is inside the outline")
                return
            }
            let result = self.placed(updated, coveringRect: rect, of: self.objects[i])
            switch action {
            case .carveOut:
                self.objects[i] = result
                self.onStatusMessage?("Carved out the object")
            case .erase:
                self.objects[i] = result
                self.onStatusMessage?("Erased part of the object")
            case .newObject:
                self.objects.append(result)
                self.selectedObjectIndex = self.objects.count - 1
                self.onStatusMessage?("Added a new object on top; drag it where you want it")
            }
        }
    }

    /// `updated`, whose image covers `rect` of `old`'s image (fractions, bottom-left origin),
    /// with its scale and position set so its pixels sit where they are in `old` on the canvas.
    private func placed(_ updated: ForegroundObject, coveringRect rect: CGRect, of old: ForegroundObject) -> ForegroundObject {
        var new = updated
        let oldScale = defaultFitScale(for: old)
        var unit = new
        unit.scale = 1
        let newFit = defaultFitScale(for: unit)
        if newFit > 0 { new.scale = oldScale / newFit }

        var dx = (rect.midX - 0.5) * old.image.size.width * oldScale
        var dy = (rect.midY - 0.5) * old.image.size.height * oldScale
        if old.isFlippedHorizontal { dx = -dx }
        if old.isFlippedVertical { dy = -dy }
        let rad = old.rotationDegrees * .pi / 180.0
        new.position = CGPoint(x: old.position.x + dx * cos(rad) - dy * sin(rad),
                               y: old.position.y + dx * sin(rad) + dy * cos(rad))
        return new
    }

    @objc private func contextSelectDetectionModeAction(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let idx = dict["index"] as? Int,
              let mode = dict["mode"] as? VisionDetectionMode else { return }

        onRetuneDetector?(idx, mode)
    }

    // MARK: - Interactive Canvas Mouse Events
    override public func mouseDown(with event: NSEvent) {
        guard combiningMode == .foregroundCombine else {
            super.mouseDown(with: event)
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        if carveObjectID != nil {
            if !isApplyingCarve { carvePath = [pt] }
            return
        }
        dragStartPoint = pt
        let additive = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        let selected = selectedIndices

        // Phase 0: the handles of a multiple selection resize or rotate all its objects.
        if selected.count > 1 && !additive {
            let box = groupBounds(of: selected)
            let center = CGPoint(x: box.midX, y: box.midY)
            let rot = groupRotateHandle(box)
            if hypot(pt.x - rot.x, pt.y - rot.y) <= 12 {
                beginGroupTransform(around: center)
                isRotatingGroup = true
                return
            }
            if groupCornerHandles(box).contains(where: { hypot(pt.x - $0.x, pt.y - $0.y) <= 12 }) {
                beginGroupTransform(around: center)
                initialDistToCenter = max(1.0, hypot(pt.x - center.x, pt.y - center.y))
                isResizingGroup = true
                return
            }
        }

        // Phase 1: Check handles across ALL objects (reverse Z-order)
        for i in stride(from: objects.count - 1, through: 0, by: -1) where selected.count <= 1 && !additive {
            let fg = objects[i]
            let effectiveScale = defaultFitScale(for: fg)
            let w = fg.image.size.width * effectiveScale
            let h = fg.image.size.height * effectiveScale

            let dx = pt.x - fg.position.x
            let dy = pt.y - fg.position.y
            let rad = -fg.rotationDegrees * .pi / 180.0
            let localPt = CGPoint(
                x: dx * cos(rad) - dy * sin(rad),
                y: dx * sin(rad) + dy * cos(rad)
            )

            let topRotHandleLocal = CGPoint(x: 0, y: h/2 + 20)
            if hypot(localPt.x - topRotHandleLocal.x, localPt.y - topRotHandleLocal.y) <= 12 {
                setSelection([i], primary: i)
                isRotatingObject = true
                isBottomRotateHandle = false
                initialObjRotation = fg.rotationDegrees
                needsDisplay = true
                return
            }

            let bottomRotHandleLocal = CGPoint(x: 0, y: -h/2 - 20)
            if hypot(localPt.x - bottomRotHandleLocal.x, localPt.y - bottomRotHandleLocal.y) <= 12 {
                setSelection([i], primary: i)
                isRotatingObject = true
                isBottomRotateHandle = true
                initialObjRotation = fg.rotationDegrees
                needsDisplay = true
                return
            }

            // 4 Corner handles + 2 Vertical side midpoint handles
            let localHandles = [
                CGPoint(x: -w/2, y: -h/2),
                CGPoint(x: w/2, y: -h/2),
                CGPoint(x: -w/2, y: h/2),
                CGPoint(x: w/2, y: h/2),
                CGPoint(x: -w/2, y: 0),
                CGPoint(x: w/2, y: 0)
            ]
            for hPt in localHandles {
                if hypot(localPt.x - hPt.x, localPt.y - hPt.y) <= 12 {
                    setSelection([i], primary: i)
                    isResizingObject = true
                    initialObjScale = fg.scale
                    initialDistToCenter = max(1.0, hypot(pt.x - fg.position.x, pt.y - fg.position.y))
                    needsDisplay = true
                    return
                }
            }
        }

        // Phase 2: Check object body dragging in reverse Z-order with pixel opacity priority
        for i in stride(from: objects.count - 1, through: 0, by: -1) {
            let fg = objects[i]
            let effectiveScale = defaultFitScale(for: fg)
            let w = fg.image.size.width * effectiveScale
            let h = fg.image.size.height * effectiveScale

            let dx = pt.x - fg.position.x
            let dy = pt.y - fg.position.y
            let rad = -fg.rotationDegrees * .pi / 180.0
            let localPt = CGPoint(
                x: dx * cos(rad) - dy * sin(rad),
                y: dx * sin(rad) + dy * cos(rad)
            )

            let xInRect = (fg.isFlippedHorizontal ? -localPt.x : localPt.x) + w / 2.0
            let yInRect = (fg.isFlippedVertical ? -localPt.y : localPt.y) + h / 2.0
            let normPt = CGPoint(x: xInRect / w, y: yInRect / h)

            if normPt.x >= 0 && normPt.x <= 1 && normPt.y >= 0 && normPt.y <= 1 {
                if isPixelOpaque(in: fg.image, atNormalizedPoint: normPt) {
                    if additive {
                        // ⇧/⌘-click adds the object to the selection, or takes it out.
                        if isSelected(i) {
                            let rest = selected.filter { $0 != i }
                            setSelection(rest, primary: rest.last)
                            return
                        }
                        setSelection(selected + [i], primary: i)
                    } else if !(isSelected(i) && selected.count > 1) {
                        setSelection([i], primary: i)
                    }
                    isDraggingObject = true
                    beginGroupTransform(around: .zero)
                    needsDisplay = true
                    return
                }
            }
        }

        // Empty canvas: a drag selects the objects it touches.
        if !additive { selectedObjectIndex = nil }
        selectionBase = additive ? selected : []
        selectionRect = CGRect(origin: pt, size: .zero)
        isDraggingObject = false
        isResizingObject = false
        isRotatingObject = false
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        if carveObjectID != nil {
            if !carvePath.isEmpty {
                carvePath.append(convert(event.locationInWindow, from: nil))
                needsDisplay = true
            }
            return
        }
        let currentPt = convert(event.locationInWindow, from: nil)
        if combiningMode == .foregroundCombine, selectionRect != nil {
            let band = CGRect(x: min(dragStartPoint.x, currentPt.x), y: min(dragStartPoint.y, currentPt.y),
                              width: abs(currentPt.x - dragStartPoint.x), height: abs(currentPt.y - dragStartPoint.y))
            selectionRect = band
            let touched = objects.indices.filter { canvasBounds(of: objects[$0]).intersects(band) }
            let all = objects.indices.filter { selectionBase.contains($0) || touched.contains($0) }
            setSelection(all, primary: all.isEmpty ? nil : (selectedObjectIndex.flatMap { all.contains($0) ? $0 : nil } ?? all.last))
            return
        }
        if combiningMode == .foregroundCombine, isResizingGroup || isRotatingGroup || (isDraggingObject && selectedIndices.count > 1) {
            transformGroup(to: currentPt)
            needsDisplay = true
            return
        }
        guard combiningMode == .foregroundCombine, let idx = selectedObjectIndex, idx < objects.count else {
            super.mouseDragged(with: event)
            return
        }

        if isRotatingObject {
            let fgObj = objects[idx]
            let rawAngle = atan2(currentPt.y - fgObj.position.y, currentPt.x - fgObj.position.x) * 180.0 / .pi
            let angle = isBottomRotateHandle ? (rawAngle + 90.0) : (rawAngle - 90.0)
            objects[idx].rotationDegrees = angle
        } else if isResizingObject {
            let fgObj = objects[idx]
            let currentDist = hypot(currentPt.x - fgObj.position.x, currentPt.y - fgObj.position.y)
            let factor = max(0.1, currentDist / initialDistToCenter)
            objects[idx].scale = initialObjScale * factor
        } else if isDraggingObject {
            let deltaX = currentPt.x - dragStartPoint.x
            let deltaY = currentPt.y - dragStartPoint.y
            if let start = groupStart[objects[idx].id] {
                objects[idx].position = CGPoint(x: start.position.x + deltaX, y: start.position.y + deltaY)
            }
        }

        needsDisplay = true
    }

    /// Moves, scales or rotates every selected object from where it started, about the selection's centre.
    private func transformGroup(to pt: CGPoint) {
        let c = groupCenter
        var factor: CGFloat = 1, angle: CGFloat = 0, shift = CGPoint.zero
        if isResizingGroup {
            factor = max(0.05, hypot(pt.x - c.x, pt.y - c.y) / initialDistToCenter)
        } else if isRotatingGroup {
            let start = atan2(dragStartPoint.y - c.y, dragStartPoint.x - c.x)
            angle = atan2(pt.y - c.y, pt.x - c.x) - start
        } else {
            shift = CGPoint(x: pt.x - dragStartPoint.x, y: pt.y - dragStartPoint.y)
        }
        let cosA = cos(angle), sinA = sin(angle)
        var updated = objects
        for i in updated.indices {
            guard let start = groupStart[updated[i].id] else { continue }
            let dx = (start.position.x - c.x) * factor, dy = (start.position.y - c.y) * factor
            updated[i].position = CGPoint(x: c.x + dx * cosA - dy * sinA + shift.x,
                                          y: c.y + dx * sinA + dy * cosA + shift.y)
            updated[i].scale = start.scale * factor
            updated[i].rotationDegrees = start.rotation + angle * 180.0 / .pi
        }
        objects = updated
    }

    override public func mouseUp(with event: NSEvent) {
        if carveObjectID != nil && !carvePath.isEmpty {
            finishCarvePath(snapsToEdges: !event.modifierFlags.contains(.option))
            return
        }
        isDraggingObject = false
        isResizingObject = false
        isRotatingObject = false
        isResizingGroup = false
        isRotatingGroup = false
        groupStart = [:]
        if selectionRect != nil {
            selectionRect = nil
            needsDisplay = true
        }
        super.mouseUp(with: event)
    }
}
