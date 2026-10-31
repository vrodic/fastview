import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    public let sidebarContainerVC = SidebarContainerViewController()
    public let dualCanvasVC = DualCanvasViewController()
    private let mainContentVC = NSViewController()
    private let statusBarView = StatusBarView()

    private var navigationManager1: NavigationManager?
    private var navigationManager2: NavigationManager?
    private let loadQueue = DispatchQueue(label: "com.fastview.directoryload", qos: .userInitiated)
    private let viewedCountQueue = DispatchQueue(label: "com.fastview.viewedcount", qos: .userInitiated)
    // Sibling navigations waiting for their parent listing, by pane: the
    // accumulated step (left/right presses made meanwhile).
    private var pendingSiblingSteps: [Int: Int] = [:]
    // Listings as last shown, by pane and location cache key, so sibling
    // steps follow the order on screen even when the sort key (viewed,
    // favorites) has changed since.  Main thread only.
    private var shownOrders: [Int: [String: (options: ListSortOptions, items: [FileItem])]] = [:]
    private var shownOrderKeys: [Int: [String]] = [:]
    private static let shownOrdersLimit = 16
    /// Watches the folders the panes list, so the lists follow changes on disk.
    private let directoryWatcher = DirectoryWatcher()
    /// Panes whose listing is being refreshed, and the modified paths a further refresh waits to pick up.
    private var refreshingPanes: Set<Int> = []
    private var pendingRefreshes: [Int: Set<String>] = [:]
    private var currentDirectoryLoadItem1: DispatchWorkItem?
    private var currentDirectoryLoadItem2: DispatchWorkItem?
    /// The random-image walk in flight for each pane (guarded by `lock`).
    private var randomImageWalks: [Int: DispatchWorkItem] = [:]
    private let lock = NSLock()
    // The old "FastViewSidebarWidth" key could hold the image area's width
    // (it measured splitView.subviews[0], which is not the sidebar).
    private static let sidebarWidthKey = "FastViewSidebarWidthV2"
    private static let splitAutosaveFramesKey = "NSSplitView Subview Frames FastMainSplitView"
    // Widths reported during the first layout are defaults, not the user's.
    private var hasRestoredSidebarWidth = false

    public var activePane: Int = 1 {
        didSet {
            sidebarContainerVC.sidebarVC1.isActivePane = (activePane == 1)
            sidebarContainerVC.sidebarVC2.isActivePane = (activePane == 2)
        }
    }

    public var activeSidebar: SidebarViewController {
        return (sidebarContainerVC.isDualView && activePane == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
    }

    public var sidebarVC: SidebarViewController {
        return activeSidebar
    }

    private var isRestoringState: Bool = false
    private var restoreGeneration = 0
    private var restoreProgress: RestoreProgress?

    /// What a combination restore is still waiting for, shown in `RestoreProgressView`.
    private struct RestoreProgress {
        let generation: Int
        let name: String
        /// Panes still waiting for their image, with the item each showed when the restore began.
        var panesPending: [Int: String?]
        let expectedItems: [Int: String?]
        let objectCount: Int
        var objectsLoaded = 0
        var objectsMissing = 0
        var objectsPlaced = false
        /// Set once the restore has started loading both panes; until then they are not judged idle.
        var loadsStarted = false

        var total: Int { 2 + objectCount }
        var done: Int { (2 - panesPending.count) + objectsLoaded }
        var isComplete: Bool { panesPending.isEmpty && objectsPlaced }

        var detail: String {
            var parts = ["Images \(2 - panesPending.count) of 2"]
            if objectCount > 0 {
                parts.append("Objects \(objectsLoaded) of \(objectCount)")
            }
            return parts.joined(separator: "  ·  ")
        }
    }

    private static let restoreTimeout: TimeInterval = 30
    private var restoreProgressTimer: Timer?
    private var fileInfoController: FileInfoWindowController?

    private var wasPreviewHiddenBeforeFullScreen: Bool = false
    private var wasStatusBarHiddenBeforeFullScreen: Bool = false

    public func setFullScreenMode(_ fullScreen: Bool) {
        if fullScreen {
            wasPreviewHiddenBeforeFullScreen = isPreviewPaneHidden
            wasStatusBarHiddenBeforeFullScreen = statusBarView.isHidden
            isPreviewPaneHidden = true
            statusBarView.isHidden = true
        } else {
            isPreviewPaneHidden = wasPreviewHiddenBeforeFullScreen
            statusBarView.isHidden = wasStatusBarHiddenBeforeFullScreen
        }
    }

    public var currentLocationPath: String? {
        return navigationManager1?.currentLocation.physicalPath
    }

    public var selectedItemPath: String? {
        return activeSidebar.selectedItem?.path
    }

    public var selectedItemId: String? {
        return activeSidebar.selectedItem?.id
    }

    public var isPreviewPaneHidden: Bool {
        get {
            guard splitViewItems.count > 0 else { return false }
            return splitViewItems[0].isCollapsed
        }
        set {
            guard splitViewItems.count > 0 else { return }
            splitViewItems[0].isCollapsed = newValue
        }
    }

    @objc public func togglePreviewPane() {
        isPreviewPaneHidden = !isPreviewPaneHidden
    }

    public func setSidebarWidthRatio(_ ratio: CGFloat) {
        let windowWidth = view.window?.frame.width ?? view.bounds.width
        let targetWidth = max(120, windowWidth * ratio)
        splitViewItems[0].preferredThicknessFraction = ratio
        splitView.setPosition(targetWidth, ofDividerAt: 0)
        UserDefaults.standard.set(Double(targetWidth), forKey: MainSplitViewController.sidebarWidthKey)
    }

    public var showFavoritesOnly: Bool = false {
        didSet {
            UserDefaults.standard.set(showFavoritesOnly, forKey: "FastViewIsFavoritesMode")
            if showFavoritesOnly != oldValue {
                reloadDirectoryContentsAsync()
            }
        }
    }

    public var showFavoritesOnlyPane2: Bool = false {
        didSet {
            if sidebarContainerVC.isDualView {
                reloadDirectoryContentsAsync(pane: 2)
            }
        }
    }

    @objc public func toggleFavoritesOnlyPane2() {
        if !sidebarContainerVC.isDualView {
            sidebarContainerVC.updateViewMode(isDual: true)
            dualCanvasVC.setDualViewEnabled(true)
        }
        showFavoritesOnlyPane2 = !showFavoritesOnlyPane2
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        directoryWatcher.onChange = { [weak self] folder, modifiedPaths in
            self?.folderChanged(folder, modifiedPaths: modifiedPaths)
        }
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        splitView.delegate = self
        restoreSidebarWidth()
    }

    private func restoreSidebarWidth() {
        defer { hasRestoredSidebarWidth = true }
        guard let savedWidth = savedSidebarWidth() else { return }
        // Leave the image area its minimum width in a smaller window.
        let maxWidth = splitView.bounds.width - splitView.dividerThickness - splitViewItems[1].minimumThickness
        splitViewItems[0].preferredThicknessFraction = 0
        splitView.setPosition(max(120, min(savedWidth, maxWidth)), ofDividerAt: 0)
    }

    /// The saved sidebar width; before it was first saved, the width the
    /// split view's own autosave recorded for the sidebar.
    private func savedSidebarWidth() -> CGFloat? {
        let defaults = UserDefaults.standard
        let saved = defaults.double(forKey: MainSplitViewController.sidebarWidthKey)
        if saved >= 120 { return CGFloat(saved) }
        guard let frames = defaults.array(forKey: MainSplitViewController.splitAutosaveFramesKey) as? [String],
              let sidebarFrame = frames.first else { return nil }
        let parts = sidebarFrame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let width = Double(parts[2]), width >= 120 else { return nil }
        return CGFloat(width)
    }

    override public func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // splitView.subviews also holds AppKit's own views, so measure the
        // sidebar itself.  A collapsed sidebar (also in full screen) keeps
        // the width it had.
        guard hasRestoredSidebarWidth, !splitViewItems[0].isCollapsed,
              view.window?.styleMask.contains(.fullScreen) != true else { return }
        let currentWidth = sidebarContainerVC.view.frame.width
        if currentWidth >= 120 {
            UserDefaults.standard.set(Double(currentWidth), forKey: MainSplitViewController.sidebarWidthKey)
        }
    }

    private func setupUI() {
        sidebarContainerVC.sidebarVC1.delegate = self
        sidebarContainerVC.sidebarVC2.delegate = self
        activePane = 1

        dualCanvasVC.combiningCanvasView.onSelectedObjectChanged = { [weak self] pane, fgObj in
            self?.statusBarView.updateForegroundObjectInfo(pane: pane, object: fgObj)
        }

        sidebarContainerVC.sidebarVC2.onClosePane = { [weak self] in
            self?.closeSecondView()
        }
        dualCanvasVC.onCloseSecondPane = { [weak self] in
            self?.closeSecondView()
        }

        dualCanvasVC.onPaneImageSet = { [weak self] pane, hasImage, itemPath in
            self?.restorePaneImageSet(pane: pane, hasImage: hasImage, itemPath: itemPath)
        }

        dualCanvasVC.combiningCanvasView.onEffectMessage = { [weak self] message in
            self?.statusBarView.showMessage(message)
        }
        dualCanvasVC.combiningCanvasView.onColorMatchFinished = { [weak self] bySkin, total, referenceHasSkin in
            let message: String
            if !referenceHasSkin {
                message = "No skin found on the reference object: matched overall colours of \(total) object(s)"
            } else if bySkin == total {
                message = "Matched skin tones of \(total) object(s)"
            } else {
                message = "Matched skin tones of \(bySkin) of \(total) object(s); the others showed too little skin and were matched by overall colours"
            }
            self?.statusBarView.showMessage(message)
        }

        dualCanvasVC.combiningCanvasView.onStatusMessage = { [weak self] message in
            self?.statusBarView.showMessage(message)
        }

        dualCanvasVC.imageView1.onRegionSelectedForDetection = { [weak self] croppedImg, crop, orientation in
            guard let self = self else { return }
            if !self.sidebarContainerVC.isDualView {
                self.sidebarContainerVC.updateViewMode(isDual: true)
                self.dualCanvasVC.setDualViewEnabled(true)
                self.showFavoritesOnlyPane2 = true
            }
            self.dualCanvasVC.combiningMode = .foregroundCombine
            ForegroundDetector.detectForegroundObject(in: croppedImg) { [weak self] fgObj in
                guard let self = self, var fg = fgObj else { return }
                fg.itemPath = self.sidebarContainerVC.sidebarVC1.selectedItem?.id ?? self.sidebarContainerVC.sidebarVC1.selectedItem?.path
                fg.archivePath = self.sidebarContainerVC.sidebarVC1.selectedItem?.archivePath
                fg.sourceCrop = crop
                fg.sourceOrientation = orientation
                DispatchQueue.main.async {
                    self.dualCanvasVC.combiningCanvasView.addObject(fg)
                }
            }
        }

        dualCanvasVC.imageView2.onRegionSelectedForDetection = { [weak self] croppedImg, crop, orientation in
            guard let self = self else { return }
            self.dualCanvasVC.combiningMode = .foregroundCombine
            ForegroundDetector.detectForegroundObject(in: croppedImg) { [weak self] fgObj in
                guard let self = self, var fg = fgObj else { return }
                fg.itemPath = self.sidebarContainerVC.sidebarVC2.selectedItem?.id ?? self.sidebarContainerVC.sidebarVC2.selectedItem?.path
                fg.archivePath = self.sidebarContainerVC.sidebarVC2.selectedItem?.archivePath
                fg.sourceCrop = crop
                fg.sourceOrientation = orientation
                DispatchQueue.main.async {
                    self.dualCanvasVC.combiningCanvasView.addObject(fg)
                }
            }
        }

        let mainStackView = NSStackView()
        mainStackView.orientation = .vertical
        mainStackView.spacing = 0
        mainStackView.distribution = .fill

        dualCanvasVC.view.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        mainStackView.addArrangedSubview(dualCanvasVC.view)
        mainStackView.addArrangedSubview(statusBarView)

        mainContentVC.view = mainStackView

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarContainerVC)
        sidebarItem.minimumThickness = 120
        sidebarItem.maximumThickness = 1200
        sidebarItem.preferredThicknessFraction = 0.25
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)

        let mainItem = NSSplitViewItem(viewController: mainContentVC)
        mainItem.minimumThickness = 300
        mainItem.holdingPriority = NSLayoutConstraint.Priority(200)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
    }

    /// Opens a folder or archive the user picked (File > Open, Open Recent)
    /// in pane 1, leaving favorites mode: its list would replace the folder.
    public func openLocation(_ location: NavigationLocation, targetSelectedItemPath: String? = nil) {
        // The reload this starts is superseded by the load below.
        if showFavoritesOnly { showFavoritesOnly = false }
        loadLocation(location, pane: 1, targetSelectedItemPath: targetSelectedItemPath)
    }

    /// `keepOtherPane` stops an archive location from cancelling the other pane's loading,
    /// for when both panes are being opened together.
    public func loadLocation(_ location: NavigationLocation, pane: Int = 1, targetSelectedItemPath: String? = nil, keepOtherPane: Bool = false) {
        if location.isArchive && !keepOtherPane {
            cancelAllIOOperations()
        } else {
            cancelIOOperations(forPane: pane)
        }
        if pane == 1 {
            navigationManager1 = NavigationManager(initialLocation: location)
            reloadDirectoryContentsAsync(pane: 1, targetSelectedItemPath: targetSelectedItemPath, keepOtherPane: keepOtherPane)
        } else {
            navigationManager2 = NavigationManager(initialLocation: location)
            sidebarContainerVC.updateViewMode(isDual: true)
            dualCanvasVC.setDualViewEnabled(true)
            activePane = 2
            reloadDirectoryContentsAsync(pane: 2, targetSelectedItemPath: targetSelectedItemPath, keepOtherPane: keepOtherPane)
        }
    }

    @objc public func openSecondFolder() {
        showFavoritesOnlyPane2 = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Folder, Archive, or Image for 2nd View"

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let path = url.path
            let fileType = ArchiveReader.fileType(for: url)

            if fileType == .image {
                let parentPath = url.deletingLastPathComponent().path
                let loc = NavigationManager.locationForPath(parentPath)
                self.loadLocation(loc, pane: 2, targetSelectedItemPath: path)
            } else {
                let loc = NavigationManager.locationForPath(path)
                self.loadLocation(loc, pane: 2)
            }
        }
    }

    @objc public func closeSecondView() {
        cancelAllIOOperations()
        activePane = 1
        dualCanvasVC.setDualViewEnabled(false)
        sidebarContainerVC.updateViewMode(isDual: false)
        navigationManager2 = nil
        updateWatchedFolders()
        UserDefaults.standard.set(false, forKey: "FastViewIsDualViewEnabled")
    }

    /// The image view of the active pane.
    private var activeImageView: MainImageView {
        activePane == 2 && sidebarContainerVC.isDualView ? dualCanvasVC.imageView2 : dualCanvasVC.imageView1
    }

    /// The image view in censor mode, if any.
    public var censoringImageView: MainImageView? {
        [dualCanvasVC.imageView1, dualCanvasVC.imageView2].first { $0.isCensoring }
    }

    public func toggleCensoringForActivePane() {
        if let censoring = censoringImageView {
            censoring.endCensoring()
        } else {
            activeImageView.beginCensoring()
        }
    }

    public func rotateRightForActivePane() {
        dualCanvasVC.rotateRight(pane: activePane)
    }

    public func rotateLeftForActivePane() {
        dualCanvasVC.rotateLeft(pane: activePane)
    }

    public func flipHorizontalForActivePane() {
        dualCanvasVC.flipHorizontal(pane: activePane)
    }

    public func flipVerticalForActivePane() {
        dualCanvasVC.flipVertical(pane: activePane)
    }

    public func resetOrientationForActivePane() {
        dualCanvasVC.resetOrientation(pane: activePane)
    }

    public func toggleCombiningControls() {
        guard sidebarContainerVC.isDualView else { return }
        dualCanvasVC.toggleToolbar()
    }

    public func addObjectToCanvas(from item: FileItem) {
        if !sidebarContainerVC.isDualView {
            sidebarContainerVC.updateViewMode(isDual: true)
            dualCanvasVC.setDualViewEnabled(true)
            showFavoritesOnlyPane2 = true
        }

        dualCanvasVC.combiningMode = .foregroundCombine

        let itemPath = item.id.isEmpty ? item.path : item.id
        ForegroundSource.detect(itemPath: itemPath, archiveCandidates: item.archivePath.map { [$0] } ?? [], crop: nil, orientation: nil, mode: .instanceMask) { [weak self] fg in
            guard let self = self, let fg = fg else { return }
            self.dualCanvasVC.combiningCanvasView.addObject(fg)
        }
    }

    @objc public func saveCombinationStatePrompt() {
        guard sidebarContainerVC.isDualView else {
            let alert = NSAlert()
            alert.messageText = "Dual View Not Active"
            alert.informativeText = "Open a 2nd view folder before saving a combination state."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let name1 = ((sidebarContainerVC.sidebarVC1.selectedItem?.name ?? "Image1") as NSString).deletingPathExtension
        let name2 = ((sidebarContainerVC.sidebarVC2.selectedItem?.name ?? "Image2") as NSString).deletingPathExtension
        let defaultComboName = "\(name1) + \(name2)"

        let alert = NSAlert()
        alert.messageText = "Save Combination State"
        alert.informativeText = "Enter a name for this combination state:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let inputTF = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputTF.stringValue = defaultComboName
        alert.accessoryView = inputTF

        if alert.runModal() == .alertFirstButtonReturn {
            let comboName = inputTF.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comboName.isEmpty else { return }

            // A favorites list is not a folder: save the folder the selected image is in.
            let selected1 = sidebarContainerVC.sidebarVC1.selectedItem
            let selected2 = sidebarContainerVC.sidebarVC2.selectedItem
            let favoritesFolder: (FileItem?) -> String? = { item in
                guard let item = item, item.archivePath == nil, !item.isDirectory else { return nil }
                return (item.path as NSString).deletingLastPathComponent
            }
            let path1 = (showFavoritesOnly ? favoritesFolder(selected1) : nil) ?? currentLocationPath ?? NSHomeDirectory()
            let itemPath1 = selected1?.id ?? selected1?.path
            let path2 = (showFavoritesOnlyPane2 ? favoritesFolder(selected2) : nil) ?? navigationManager2?.currentLocation.physicalPath ?? path1
            let itemPath2 = selected2?.id ?? selected2?.path

            let o1 = dualCanvasVC.imageView1.orientation
            let o2 = dualCanvasVC.imageView2.orientation
            let canvas = dualCanvasVC.combiningCanvasView

            var colorR: Double? = nil
            var colorG: Double? = nil
            var colorB: Double? = nil
            var colorA: Double? = nil

            if let cgColor = canvas.canvasBackgroundColor.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
               let components = cgColor.components, components.count >= 4 {
                colorR = Double(components[0])
                colorG = Double(components[1])
                colorB = Double(components[2])
                colorA = Double(components[3])
            } else if canvas.canvasBackgroundColor == .white {
                colorR = 1.0; colorG = 1.0; colorB = 1.0; colorA = 1.0
            } else {
                colorR = 0.0; colorG = 0.0; colorB = 0.0; colorA = 1.0
            }

            // Array order is z order (first is bottom).
            let savedObjects = canvas.objects.map { fg -> SavedForegroundObjectState in
                let norm = canvas.normalizedPosition(of: fg)
                return SavedForegroundObjectState(
                    itemPath: fg.itemPath,
                    archivePath: fg.archivePath,
                    sourcePane: fg.sourcePane,
                    posX: Double(fg.position.x),
                    posY: Double(fg.position.y),
                    normX: norm.map { Double($0.x) },
                    normY: norm.map { Double($0.y) },
                    scale: Double(fg.scale),
                    rot: Double(fg.rotationDegrees),
                    flipH: fg.isFlippedHorizontal,
                    flipV: fg.isFlippedVertical,
                    detectionMode: fg.detectionMode.rawValue,
                    crop: fg.sourceCrop,
                    cropOrientation: fg.sourceOrientation,
                    colorAdjustment: fg.colorAdjustment,
                    carves: fg.carves,
                    effects: fg.effects
                )
            }
            // Large enough to stand in for the canvas while the combination restores.
            let preview = canvas.renderPreview(maxDimension: 1600)

            let state = SavedCombinationState(
                name: comboName,
                path1: path1,
                itemPath1: itemPath1,
                path2: path2,
                itemPath2: itemPath2,
                rot1: Double(o1.rotationDegrees),
                flipH1: o1.isFlippedHorizontal,
                flipV1: o1.isFlippedVertical,
                rot2: Double(o2.rotationDegrees),
                flipH2: o2.isFlippedHorizontal,
                flipV2: o2.isFlippedVertical,
                combiningMode: dualCanvasVC.combiningMode.rawValue,
                mergeLeftPercent: Double(canvas.mergeLeftPercent),
                mergeRightPercent: Double(canvas.mergeRightPercent),
                alphaGradientPercent: Double(canvas.alphaGradientPercent),
                fgOffset1Percent: Double(canvas.fgOffset1Percent),
                fgOffset2Percent: Double(canvas.fgOffset2Percent),
                showBackground1: canvas.showBackground1,
                showBackground2: canvas.showBackground2,
                canvasRed: colorR,
                canvasGreen: colorG,
                canvasBlue: colorB,
                canvasAlpha: colorA,
                objects: savedObjects
            )

            CombinationStateManager.save(state, preview: preview) { result in
                if case .failure(let error) = result {
                    let failAlert = NSAlert()
                    failAlert.messageText = "Could Not Save Combination"
                    failAlert.informativeText = error.localizedDescription
                    failAlert.alertStyle = .warning
                    failAlert.runModal()
                }
            }
        }
    }

    public func restoreCombinationState(from url: URL) {
        CombinationStateManager.load(url) { [weak self] state, preview in
            guard let self = self else { return }
            guard let state = state else {
                let alert = NSAlert()
                alert.messageText = "Could Not Open Combination"
                alert.informativeText = "\(url.lastPathComponent) is missing or is not a FastView combination file."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            self.restoreCombinationState(state, preview: preview)
        }
    }

    /// `preview`, the canvas as saved, covers the canvas until everything is loaded,
    /// so the panes and objects arriving one by one are not seen.
    public func restoreCombinationState(_ state: SavedCombinationState, preview: NSImage? = nil) {
        restoreGeneration += 1
        let generation = restoreGeneration
        let canvas = dualCanvasVC.combiningCanvasView
        let savedObjects = state.objects ?? Self.legacyObjects(from: state)

        restoreProgress = RestoreProgress(
            generation: generation,
            name: state.name,
            panesPending: [1: sidebarContainerVC.sidebarVC1.selectedItem?.id, 2: sidebarContainerVC.sidebarVC2.selectedItem?.id],
            expectedItems: [1: state.itemPath1, 2: state.itemPath2],
            objectCount: savedObjects.count
        )
        if let preview = preview {
            var background = NSColor.black
            if let r = state.canvasRed, let g = state.canvasGreen, let b = state.canvasBlue, let a = state.canvasAlpha {
                background = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
            }
            dualCanvasVC.showRestorePreview(preview, background: background)
        } else {
            dualCanvasVC.hideRestorePreview()
        }
        updateRestoreProgress()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreTimeout) { [weak self] in
            guard let self = self, let progress = self.restoreProgress, progress.generation == generation else { return }
            self.finishRestoreProgress(timedOut: true)
        }

        // The saved objects replace whatever the panes would auto-detect.
        dualCanvasVC.beginRestoringObjects(itemPath1: state.itemPath1, itemPath2: state.itemPath2)
        canvas.objects = []

        // The saved folders are shown, not the favorites lists.
        if showFavoritesOnly { showFavoritesOnly = false }
        if showFavoritesOnlyPane2 { showFavoritesOnlyPane2 = false }

        // Both panes load together; neither may cancel the other's loading.
        let loc1 = NavigationManager.locationForPath(state.path1)
        loadLocation(loc1, pane: 1, targetSelectedItemPath: state.itemPath1, keepOtherPane: true)

        let loc2 = NavigationManager.locationForPath(state.path2)
        loadLocation(loc2, pane: 2, targetSelectedItemPath: state.itemPath2, keepOtherPane: true)
        restoreProgress?.loadsStarted = true
        startRestoreProgressTimer()

        let o1 = ImageOrientation(rotationDegrees: CGFloat(state.rot1), isFlippedHorizontal: state.flipH1, isFlippedVertical: state.flipV1)
        dualCanvasVC.imageView1.orientation = o1
        canvas.orientation1 = o1

        let o2 = ImageOrientation(rotationDegrees: CGFloat(state.rot2), isFlippedHorizontal: state.flipH2, isFlippedVertical: state.flipV2)
        dualCanvasVC.imageView2.orientation = o2
        canvas.orientation2 = o2

        if let mode = CanvasCombiningMode(rawValue: state.combiningMode) {
            dualCanvasVC.combiningMode = mode
        }

        canvas.mergeLeftPercent = CGFloat(state.mergeLeftPercent)
        canvas.mergeRightPercent = CGFloat(state.mergeRightPercent)
        canvas.alphaGradientPercent = CGFloat(state.alphaGradientPercent)
        canvas.fgOffset1Percent = CGFloat(state.fgOffset1Percent)
        canvas.fgOffset2Percent = CGFloat(state.fgOffset2Percent)
        canvas.showBackground1 = state.showBackground1
        canvas.showBackground2 = state.showBackground2

        if let r = state.canvasRed, let g = state.canvasGreen, let b = state.canvasBlue, let a = state.canvasAlpha {
            canvas.canvasBackgroundColor = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }

        dualCanvasVC.setDualViewEnabled(true)
        dualCanvasVC.toolbarView.syncValues(from: canvas)

        // Objects load in parallel; they are placed together, in saved z order, once all are back.
        var loaded = [ForegroundObject?](repeating: nil, count: savedObjects.count)
        let group = DispatchGroup()
        for (i, savedObj) in savedObjects.enumerated() {
            group.enter()
            Self.loadObject(savedObj, archiveCandidates: Self.archiveCandidates(of: savedObj, in: state)) { [weak self] fg in
                loaded[i] = fg
                if let self = self, self.restoreProgress?.generation == generation {
                    self.restoreProgress?.objectsLoaded += 1
                    if fg == nil { self.restoreProgress?.objectsMissing += 1 }
                    self.updateRestoreProgress()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self, generation == self.restoreGeneration else { return }
            let restored = zip(savedObjects, loaded).compactMap { savedObj, loadedObj -> (ForegroundObject, CGPoint?)? in
                guard var fg = loadedObj else { return nil }
                fg.sourcePane = savedObj.sourcePane
                fg.position = CGPoint(x: savedObj.posX, y: savedObj.posY)
                fg.scale = CGFloat(savedObj.scale)
                fg.rotationDegrees = CGFloat(savedObj.rot)
                fg.isFlippedHorizontal = savedObj.flipH
                fg.isFlippedVertical = savedObj.flipV
                fg.effects = savedObj.effects ?? ObjectEffects()
                var norm: CGPoint? = nil
                if let nx = savedObj.normX, let ny = savedObj.normY {
                    norm = CGPoint(x: nx, y: ny)
                }
                return (fg, norm)
            }
            canvas.setRestoredObjects(restored)
            self.restoreProgress?.objectsPlaced = true
            self.updateRestoreProgress()
        }
    }

    /// A pane got its image: the restore's step for it is done when the image is the
    /// saved item, the pane has none to show, or it shows something other than before
    /// the restore (the saved item is gone). A late image for the earlier selection does not count.
    private func restorePaneImageSet(pane: Int, hasImage: Bool, itemPath: String?) {
        guard let progress = restoreProgress, let shownBefore = progress.panesPending[pane] else { return }
        let expected = progress.expectedItems[pane] ?? nil
        guard !hasImage || itemPath == expected || itemPath != shownBefore else { return }
        restoreProgress?.panesPending[pane] = nil
        updateRestoreProgress()
    }

    /// Image events can be missed (a cancelled load never reports back, a folder selection
    /// shows no image), so the panes are also checked for having gone idle.
    private func startRestoreProgressTimer() {
        restoreProgressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkRestorePanesIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        restoreProgressTimer = timer
    }

    /// A pane whose listing is applied and that has no full-image load pending has
    /// shown whatever it is going to show.
    private func checkRestorePanesIdle() {
        guard let progress = restoreProgress, progress.loadsStarted else { return }
        var changed = false
        for pane in progress.panesPending.keys {
            let group = pane == 2 ? "pane2" : "main"
            if !isDirectoryLoadInFlight(pane: pane) && !ThumbnailGenerator.shared.hasPendingFullImageLoad(inGroup: group) {
                restoreProgress?.panesPending[pane] = nil
                changed = true
            }
        }
        if changed { updateRestoreProgress() }
    }

    /// The pane's location has no item to show, so a restore stops waiting for its image.
    private func restorePaneHasNoImage(pane: Int) {
        guard restoreProgress?.panesPending[pane] != nil else { return }
        restoreProgress?.panesPending[pane] = nil
        updateRestoreProgress()
    }

    private func updateRestoreProgress() {
        guard let progress = restoreProgress else { return }
        if progress.isComplete {
            finishRestoreProgress(timedOut: false)
            return
        }
        let overlay = dualCanvasVC.restoreProgressView
        overlay.update(title: "Restoring “\(progress.name)”…", done: progress.done, total: progress.total, detail: progress.detail)
        overlay.isHidden = false
    }

    private func finishRestoreProgress(timedOut: Bool) {
        guard let progress = restoreProgress else { return }
        restoreProgress = nil
        restoreProgressTimer?.invalidate()
        restoreProgressTimer = nil
        let overlay = dualCanvasVC.restoreProgressView
        overlay.update(title: "Restoring “\(progress.name)”…", done: progress.total, total: progress.total, detail: progress.detail)
        // Leave the full bar up for a moment so the end is visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.restoreProgress == nil else { return }
            overlay.isHidden = true
            self.dualCanvasVC.hideRestorePreview()
        }

        var problems: [String] = []
        if progress.objectsMissing > 0 {
            problems.append(progress.objectsMissing == 1 ? "1 object could not be loaded" : "\(progress.objectsMissing) objects could not be loaded")
        }
        if timedOut {
            if !progress.panesPending.isEmpty { problems.append("a pane image did not load") }
            if !progress.objectsPlaced { problems.append("objects are still loading") }
        }
        statusBarView.showMessage(problems.isEmpty
            ? "Restored “\(progress.name)”"
            : "Restored “\(progress.name)”: " + problems.joined(separator: ", "))
    }

    /// Re-detects the object from its source item, with its saved crop, carves and
    /// colour adjustment. Completes on the main thread.
    private static func loadObject(_ savedObj: SavedForegroundObjectState, archiveCandidates: [String], completion: @escaping (ForegroundObject?) -> Void) {
        guard let itemPath = savedObj.itemPath else {
            completion(nil)
            return
        }
        let mode = VisionDetectionMode(rawValue: savedObj.detectionMode) ?? .instanceMask
        ForegroundSource.detect(itemPath: itemPath, archiveCandidates: archiveCandidates, crop: savedObj.crop, orientation: savedObj.cropOrientation, mode: mode) { fg in
            guard let fg = fg else { return completion(nil) }
            ForegroundSource.applyCarves(savedObj.carves ?? [], to: fg) { fg, _ in
                ForegroundSource.applyColorAdjustment(savedObj.colorAdjustment, to: fg, completion: completion)
            }
        }
    }

    /// Archives an object's item may be in, most likely first. Files saved before
    /// objects recorded their archive fall back to pane locations that are archives.
    private static func archiveCandidates(of savedObj: SavedForegroundObjectState, in state: SavedCombinationState) -> [String] {
        if let archivePath = savedObj.archivePath { return [archivePath] }
        let isArchive: (String) -> Bool = { ["zip", "rar"].contains(($0 as NSString).pathExtension.lowercased()) }
        let panes = savedObj.sourcePane == 2 ? [state.path2, state.path1] : [state.path1, state.path2]
        var seen = Set<String>()
        return panes.filter { isArchive($0) && seen.insert($0).inserted }
    }

    /// Objects of states saved before the object list existed: one per pane.
    private static func legacyObjects(from state: SavedCombinationState) -> [SavedForegroundObjectState] {
        var result: [SavedForegroundObjectState] = []
        if let x = state.fgPos1X, let y = state.fgPos1Y {
            result.append(SavedForegroundObjectState(
                itemPath: state.itemPath1, sourcePane: 1, posX: x, posY: y,
                scale: state.fgScale1 ?? 1, rot: state.fgRot1 ?? 0,
                flipH: state.fgFlipH1 ?? false, flipV: state.fgFlipV1 ?? false
            ))
        }
        if let x = state.fgPos2X, let y = state.fgPos2Y {
            result.append(SavedForegroundObjectState(
                itemPath: state.itemPath2, sourcePane: 2, posX: x, posY: y,
                scale: state.fgScale2 ?? 1, rot: state.fgRot2 ?? 0,
                flipH: state.fgFlipH2 ?? false, flipV: state.fgFlipV2 ?? false
            ))
        }
        return result
    }

    public func saveSelectionAndDualState() {
        guard !isRestoringState else { return }

        if let locPath1 = currentLocationPath {
            UserDefaults.standard.set(locPath1, forKey: "FastViewLastOpenedPath")
        }
        if let selPath1 = sidebarContainerVC.sidebarVC1.selectedItem?.path {
            UserDefaults.standard.set(selPath1, forKey: "FastViewLastSelectedItemPath")
        }
        if let selId1 = sidebarContainerVC.sidebarVC1.selectedItem?.id {
            UserDefaults.standard.set(selId1, forKey: "FastViewLastSelectedItemId")
        }

        let isDual = sidebarContainerVC.isDualView
        UserDefaults.standard.set(isDual, forKey: "FastViewIsDualViewEnabled")

        if isDual {
            if let locPath2 = navigationManager2?.currentLocation.physicalPath {
                UserDefaults.standard.set(locPath2, forKey: "FastViewLastOpenedPath2")
            }
            if let selPath2 = sidebarContainerVC.sidebarVC2.selectedItem?.path {
                UserDefaults.standard.set(selPath2, forKey: "FastViewLastSelectedItemPath2")
            }
            if let selId2 = sidebarContainerVC.sidebarVC2.selectedItem?.id {
                UserDefaults.standard.set(selId2, forKey: "FastViewLastSelectedItemId2")
            }
        }

        let o1 = dualCanvasVC.imageView1.orientation
        UserDefaults.standard.set([
            "rot": Double(o1.rotationDegrees),
            "flipH": o1.isFlippedHorizontal,
            "flipV": o1.isFlippedVertical
        ], forKey: "FastViewOrientation1")

        let o2 = dualCanvasVC.imageView2.orientation
        UserDefaults.standard.set([
            "rot": Double(o2.rotationDegrees),
            "flipH": o2.isFlippedHorizontal,
            "flipV": o2.isFlippedVertical
        ], forKey: "FastViewOrientation2")

        let canvas = dualCanvasVC.combiningCanvasView
        UserDefaults.standard.set(dualCanvasVC.combiningMode.rawValue, forKey: "FastViewCombiningMode")
        UserDefaults.standard.set(Double(canvas.mergeLeftPercent), forKey: "FastViewMergeLeftPercent")
        UserDefaults.standard.set(Double(canvas.mergeRightPercent), forKey: "FastViewMergeRightPercent")
        UserDefaults.standard.set(Double(canvas.alphaGradientPercent), forKey: "FastViewAlphaGradientPercent")
        UserDefaults.standard.set(canvas.showBackground1, forKey: "FastViewShowBackground1")
        UserDefaults.standard.set(canvas.showBackground2, forKey: "FastViewShowBackground2")
    }

    public func restoreSelectionAndDualState() {
        guard !isRestoringState else { return }
        isRestoringState = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.isRestoringState = false
                }
            }

            if let dict1 = UserDefaults.standard.dictionary(forKey: "FastViewOrientation1"),
               let rot = dict1["rot"] as? Double,
               let flipH = dict1["flipH"] as? Bool,
               let flipV = dict1["flipV"] as? Bool {
                let o1 = ImageOrientation(rotationDegrees: CGFloat(rot), isFlippedHorizontal: flipH, isFlippedVertical: flipV)
                self.dualCanvasVC.imageView1.orientation = o1
                self.dualCanvasVC.combiningCanvasView.orientation1 = o1
            }

            if let dict2 = UserDefaults.standard.dictionary(forKey: "FastViewOrientation2"),
               let rot = dict2["rot"] as? Double,
               let flipH = dict2["flipH"] as? Bool,
               let flipV = dict2["flipV"] as? Bool {
                let o2 = ImageOrientation(rotationDegrees: CGFloat(rot), isFlippedHorizontal: flipH, isFlippedVertical: flipV)
                self.dualCanvasVC.imageView2.orientation = o2
                self.dualCanvasVC.combiningCanvasView.orientation2 = o2
            }

            if let modeStr = UserDefaults.standard.string(forKey: "FastViewCombiningMode"),
               let mode = CanvasCombiningMode(rawValue: modeStr) {
                self.dualCanvasVC.combiningMode = mode
            }

            if UserDefaults.standard.object(forKey: "FastViewMergeLeftPercent") != nil {
                let left = CGFloat(UserDefaults.standard.double(forKey: "FastViewMergeLeftPercent"))
                self.dualCanvasVC.combiningCanvasView.mergeLeftPercent = left
            }
            if UserDefaults.standard.object(forKey: "FastViewMergeRightPercent") != nil {
                let right = CGFloat(UserDefaults.standard.double(forKey: "FastViewMergeRightPercent"))
                self.dualCanvasVC.combiningCanvasView.mergeRightPercent = right
            }
            if UserDefaults.standard.object(forKey: "FastViewAlphaGradientPercent") != nil {
                let alpha = CGFloat(UserDefaults.standard.double(forKey: "FastViewAlphaGradientPercent"))
                self.dualCanvasVC.combiningCanvasView.alphaGradientPercent = alpha
            }
            if UserDefaults.standard.object(forKey: "FastViewShowBackground1") != nil {
                self.dualCanvasVC.combiningCanvasView.showBackground1 = UserDefaults.standard.bool(forKey: "FastViewShowBackground1")
            }
            if UserDefaults.standard.object(forKey: "FastViewShowBackground2") != nil {
                self.dualCanvasVC.combiningCanvasView.showBackground2 = UserDefaults.standard.bool(forKey: "FastViewShowBackground2")
            }

            let isDual = UserDefaults.standard.bool(forKey: "FastViewIsDualViewEnabled")
            if isDual,
               let path2 = UserDefaults.standard.string(forKey: "FastViewLastOpenedPath2"),
               FileManager.default.fileExists(atPath: path2) {
                let item2 = UserDefaults.standard.string(forKey: "FastViewLastSelectedItemId2") ?? UserDefaults.standard.string(forKey: "FastViewLastSelectedItemPath2")
                let loc2 = NavigationManager.locationForPath(path2)
                self.loadLocation(loc2, pane: 2, targetSelectedItemPath: item2)
            }
        }
    }

    public func cancelIOOperations(forPane pane: Int) {
        lock.lock()
        if pane == 1 {
            currentDirectoryLoadItem1?.cancel()
            currentDirectoryLoadItem1 = nil
        } else {
            currentDirectoryLoadItem2?.cancel()
            currentDirectoryLoadItem2 = nil
        }
        randomImageWalks.removeValue(forKey: pane)?.cancel()
        lock.unlock()
    }

    /// Forgets the pane's listing once it is applied, so `isDirectoryLoadInFlight` turns false.
    private func directoryLoadFinished(_ workItem: DispatchWorkItem, pane: Int) {
        lock.lock()
        if pane == 1, currentDirectoryLoadItem1 === workItem {
            currentDirectoryLoadItem1 = nil
        } else if pane == 2, currentDirectoryLoadItem2 === workItem {
            currentDirectoryLoadItem2 = nil
        }
        lock.unlock()
    }

    private func isDirectoryLoadInFlight(pane: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let item = pane == 1 ? currentDirectoryLoadItem1 : currentDirectoryLoadItem2
        return item.map { !$0.isCancelled } ?? false
    }

    public func cancelAllIOOperations() {
        cancelIOOperations(forPane: 1)
        cancelIOOperations(forPane: 2)
        ThumbnailGenerator.shared.cancelAllPendingTasks()
    }

    public func reloadDirectoryContentsPublic() {
        reloadDirectoryContentsAsync(pane: activePane)
    }

    private func reloadDirectoryContentsAsync(pane: Int = 1, targetSelectedItemPath: String? = nil, isNavigatingUp: Bool = false, keepOtherPane: Bool = false) {
        let navMgrCheck = (pane == 2) ? navigationManager2 : navigationManager1
        if navMgrCheck?.currentLocation.isArchive == true && !keepOtherPane {
            cancelAllIOOperations()
        } else {
            cancelIOOperations(forPane: pane)
            // Opening a location must not wait behind thumbnail I/O for the
            // previous listing; visible cells re-request their thumbnails.
            ThumbnailGenerator.shared.cancelAllThumbnailTasks()
        }

        let targetSidebar = (pane == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        let navMgr = (pane == 2) ? navigationManager2 : navigationManager1

        let startTime = CFAbsoluteTimeGetCurrent()

        let sortOptions = targetSidebar.sortOptions

        if (showFavoritesOnly && pane == 1) || (pane == 2 && showFavoritesOnlyPane2) {
            // Sorting may stat files, so it runs on the load queue.
            var workItem: DispatchWorkItem!
            workItem = DispatchWorkItem { [weak self] in
                guard self != nil, !workItem.isCancelled else { return }
                let favorites = ListSorter.sortFavorites(SQLiteCache.shared.getAllFavorites(), options: sortOptions)
                DispatchQueue.main.async {
                    guard let self = self, !workItem.isCancelled else { return }
                    self.directoryLoadFinished(workItem, pane: pane)
                    self.showFavorites(favorites, pane: pane, targetSelectedItemPath: targetSelectedItemPath)
                }
            }
            lock.lock()
            if pane == 1 {
                currentDirectoryLoadItem1 = workItem
            } else {
                currentDirectoryLoadItem2 = workItem
            }
            lock.unlock()
            loadQueue.async(execute: workItem)
            return
        }

        guard let navMgr = navMgr else { return }

        let path = navMgr.currentLocation.physicalPath
        let isArchive = navMgr.currentLocation.isArchive

        let archiveURL = URL(fileURLWithPath: path)
        let archiveName = archiveURL.lastPathComponent
        let folderName = archiveURL.deletingLastPathComponent().lastPathComponent

        let locationTitle: String
        if isArchive {
            if let targetPath = targetSelectedItemPath {
                let targetName = (targetPath as NSString).lastPathComponent
                if !folderName.isEmpty {
                    locationTitle = "\(folderName) / \(archiveName) / \(targetName)"
                } else {
                    locationTitle = "\(archiveName) / \(targetName)"
                }
            } else {
                if !folderName.isEmpty {
                    locationTitle = "\(folderName) / \(archiveName) / Loading..."
                } else {
                    locationTitle = "\(archiveName) / Loading..."
                }
            }
        } else {
            locationTitle = (path as NSString).lastPathComponent
        }

        targetSidebar.setHeaderTitle(locationTitle)

        // Draw status bar information immediately
        if pane == 1 {
            statusBarView.updateDirectoryStats(imageCount: 0, totalSizeBytes: 0, locationName: locationTitle)
        }

        if isArchive && pane == 1 {
            let loadingMessage = String(format: "Opening archive %@...", archiveName)
            dualCanvasVC.imageView1.beginLoading(statusText: loadingMessage)
        }

        FileLogger.shared.log("DIR_OPEN_START", path: path)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !workItem.isCancelled else { return }

            // stat() off the main thread: on a network volume it can stall
            // behind in-flight archive reads.
            let archiveSize = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0

            let listingProgress: LoadProgressHandler? = (isArchive && pane == 1) ? { [weak self] update in
                DispatchQueue.main.async {
                    guard let self = self, !workItem.isCancelled else { return }
                    self.dualCanvasVC.imageView1.updateLoadingProgress(update)
                }
            } : nil

            let listed = DiskIOGate.shared.perform(.interactive, label: path) {
                navMgr.contents(progress: listingProgress, isCancelled: { workItem.isCancelled })
            }
            if workItem.isCancelled { return }
            // Dates read since this load began (by the listing itself) are current.
            let items = ListSorter.sort(listed, options: sortOptions, datesReadSince: startTime)
            if workItem.isCancelled { return }

            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
                if workItem.isCancelled { return }
                self.directoryLoadFinished(workItem, pane: pane)
                targetSidebar.setItems(items, selectFirst: targetSelectedItemPath == nil)
                self.updateWatchedFolders()
                // A cached listing may predate changes made while the folder was not watched.
                if navMgr.lastContentsWereCached && !isArchive {
                    self.refreshListing(pane: pane, modifiedPaths: [])
                }
                self.rememberShownOrder(items, options: sortOptions, location: navMgr.currentLocation, pane: pane)

                if let targetPath = targetSelectedItemPath,
                   let idx = items.firstIndex(where: {
                       $0.id == targetPath ||
                       $0.path == targetPath ||
                       $0.name == targetPath ||
                       (targetPath as NSString).lastPathComponent == $0.name ||
                       $0.path.hasSuffix(targetPath) ||
                       targetPath.hasSuffix($0.path) ||
                       (targetPath.contains("#") && targetPath.hasSuffix("#" + $0.id))
                   }) {
                    print("[MainSplitVC] Pane \(pane) selected target item '\(items[idx].name)' at index \(idx)")
                    targetSidebar.selectRow(idx)
                    self.displayItem(items[idx], pane: pane)
                } else if targetSelectedItemPath == nil,
                          let firstItem = items.first(where: { $0.type == .image || $0.type == .archiveZip || $0.type == .archiveRar }) {
                    self.displayItem(firstItem, pane: pane)
                } else {
                    // The item asked for is not here: nothing will be shown in this pane.
                    self.restorePaneHasNoImage(pane: pane)
                    if pane == 1 {
                        self.statusBarView.updateDirectoryStats(imageCount: imageItems.count, totalSizeBytes: archiveSize, locationName: locationTitle)
                        if imageItems.isEmpty {
                            self.dualCanvasVC.imageView1.hideLoading()
                            self.dualCanvasVC.setImage(nil, pane: 1)
                        }
                    }
                }

                targetSidebar.loadVisibleThumbnailsIfIdle()
            }
        }

        lock.lock()
        if pane == 1 {
            currentDirectoryLoadItem1 = workItem
        } else {
            currentDirectoryLoadItem2 = workItem
        }
        lock.unlock()

        loadQueue.async(execute: workItem)
    }

    // MARK: - Folder Watching

    /// The folder pane `pane` lists, or nil for favorites, archives and a closed pane.
    private func listedFolder(pane: Int) -> String? {
        let isFavorites = pane == 1 ? showFavoritesOnly : showFavoritesOnlyPane2
        guard !isFavorites, let nav = pane == 2 ? navigationManager2 : navigationManager1,
              !nav.currentLocation.isArchive else { return nil }
        return nav.currentLocation.physicalPath
    }

    private func updateWatchedFolders() {
        directoryWatcher.watch(Set([1, 2].compactMap { listedFolder(pane: $0) }))
    }

    private func folderChanged(_ folder: String, modifiedPaths: Set<String>) {
        for pane in [1, 2] where listedFolder(pane: pane) == folder {
            refreshListing(pane: pane, modifiedPaths: modifiedPaths)
        }
    }

    /// Lists the pane's folder again and shows the result in place, keeping the selection
    /// (see `SidebarViewController.setRefreshedItems`). Thumbnails of `modifiedPaths` are read again.
    private func refreshListing(pane: Int, modifiedPaths: Set<String>) {
        // A refresh or a load still running would miss this change: refresh after it.
        if refreshingPanes.contains(pane) || isDirectoryLoadInFlight(pane: pane) {
            pendingRefreshes[pane, default: []].formUnion(modifiedPaths)
            if !refreshingPanes.contains(pane) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.runPendingRefresh(pane: pane) }
            }
            return
        }
        guard let nav = pane == 2 ? navigationManager2 : navigationManager1 else { return }
        let sidebar = pane == 2 ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        let location = nav.currentLocation
        let listingNav = NavigationManager(initialLocation: location)
        let sortOptions = sidebar.sortOptions
        refreshingPanes.insert(pane)

        loadQueue.async { [weak self] in
            let startTime = CFAbsoluteTimeGetCurrent()
            let listed = DiskIOGate.shared.perform(.background, label: location.physicalPath) {
                listingNav.contents(useCache: false)
            }
            let items = ListSorter.sort(listed, options: sortOptions, datesReadSince: startTime)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshingPanes.remove(pane)
                defer { self.runPendingRefresh(pane: pane) }
                // Drop the result if the pane moved on or was re-sorted meanwhile.
                guard let current = pane == 2 ? self.navigationManager2 : self.navigationManager1,
                      current.currentLocation.cacheKey == location.cacheKey,
                      sidebar.sortOptions == sortOptions else { return }

                let changedIDs = Set(items.map { $0.id }).intersection(modifiedPaths)
                for id in changedIDs {
                    MemoryLRUCache.shared.removeObject(forKey: "thumb_\(id)_256.0x256.0")
                    MemoryLRUCache.shared.removeObject(forKey: "full_\(id)")
                }
                guard items.map({ $0.id }) != sidebar.items.map({ $0.id }) || !changedIDs.isEmpty else { return }
                FileLogger.shared.log("DIR_REFRESH \(sidebar.items.count) -> \(items.count) items", path: location.physicalPath)

                let selectedID = sidebar.selectedItem?.id
                sidebar.setRefreshedItems(items, changedIDs: changedIDs)
                self.rememberShownOrder(items, options: sortOptions, location: location, pane: pane)
                // The same item still selected: only its position in the list may have changed.
                if pane == 1, let item = sidebar.selectedItem, item.id == selectedID {
                    self.refreshStatusBarPosition(of: item, in: sidebar.items, folder: location.physicalPath)
                }
            }
        }
    }

    private func runPendingRefresh(pane: Int) {
        guard !refreshingPanes.contains(pane), let modified = pendingRefreshes.removeValue(forKey: pane) else { return }
        refreshListing(pane: pane, modifiedPaths: modified)
    }

    private func refreshStatusBarPosition(of item: FileItem, in items: [FileItem], folder: String) {
        let parentName = (folder as NSString).lastPathComponent
        if item.type == .image {
            let imageItems = items.filter { $0.type == .image }
            let index = imageItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
            statusBarView.updateImageInfo(item: item, image: dualCanvasVC.imageView1.currentImage,
                                          currentIndex: index, totalImages: imageItems.count,
                                          viewedPercent: viewedPercent(of: imageItems), parentName: parentName)
        } else {
            let position = containerPosition(of: item, in: items) { [weak self] counted in
                guard let self = self, self.sidebarContainerVC.sidebarVC1.selectedItem?.id == item.id else { return }
                self.statusBarView.updateSelectedItemStats(item: item, position: counted, parentName: parentName)
            }
            statusBarView.updateSelectedItemStats(item: item, position: position, parentName: parentName)
        }
    }

    /// Share of the list's images marked viewed, nil when viewed images are
    /// not tracked.  The sidebar loaded the list's viewed flags into memory
    /// when it was shown, so this reads no database.
    private func viewedPercent(of imageItems: [FileItem]) -> Int? {
        guard SQLiteCache.shared.isTrackingViewedImagesEnabled, !imageItems.isEmpty else { return nil }
        let viewed = SQLiteCache.shared.getViewedCount(keys: imageItems.map(SidebarTableCellView.viewedKey))
        return Self.percent(viewed, of: imageItems.count)
    }

    private static func percent(_ count: Int, of total: Int) -> Int {
        Int(round(Double(count) / Double(total) * 100.0))
    }

    /// Where `item` sits among the list's folders and archives, with the
    /// share of them holding any viewed image when SQLiteCache already knows
    /// it.  Otherwise that is counted in the background (an indexed lookup
    /// per folder or archive, remembered after) and `onCounted` gets the
    /// position with it, on the main queue.
    private func containerPosition(of item: FileItem, in items: [FileItem],
                                   onCounted: @escaping (StatusBarView.ContainerPosition) -> Void) -> StatusBarView.ContainerPosition? {
        guard var position = StatusBarView.ContainerPosition(item: item, in: items) else { return nil }
        guard SQLiteCache.shared.isTrackingViewedImagesEnabled else { return position }
        let prefixes = position.containers.map(FolderStatsCalculator.viewedKeyPrefix)
        if let count = SQLiteCache.shared.cachedCountOfPrefixesWithViewed(prefixes) {
            position.viewedPercent = Self.percent(count, of: prefixes.count)
            return position
        }
        let uncounted = position
        viewedCountQueue.async {
            let count = SQLiteCache.shared.countPrefixesWithViewed(prefixes)
            DispatchQueue.main.async {
                var counted = uncounted
                counted.viewedPercent = Self.percent(count, of: prefixes.count)
                onCounted(counted)
            }
        }
        return position
    }

    private func showFavorites(_ favorites: [FileItem], pane: Int, targetSelectedItemPath: String?) {
        let targetSidebar = (pane == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        targetSidebar.setHeaderTitle(pane == 2 ? "Pane 2: Favorites" : "Favorites")
        targetSidebar.setItems(favorites, selectFirst: targetSelectedItemPath == nil)
        updateWatchedFolders()
        if pane == 1 {
            statusBarView.updateDirectoryStats(imageCount: favorites.count, totalSizeBytes: 0, locationName: "Favorites")
        }

        if let targetPath = targetSelectedItemPath,
           let idx = favorites.firstIndex(where: {
               $0.id == targetPath ||
               $0.path == targetPath ||
               $0.name == targetPath ||
               (targetPath as NSString).lastPathComponent == $0.name ||
               $0.path.hasSuffix(targetPath) ||
               targetPath.hasSuffix($0.path)
           }) {
            targetSidebar.selectRow(idx)
            displayItem(favorites[idx], pane: pane)
        } else if targetSelectedItemPath == nil, let first = favorites.first {
            displayItem(first, pane: pane)
        }
    }

    public func sidebar(_ sidebar: SidebarViewController, didChangeSort options: ListSortOptions) {
        let items = sidebar.items
        let pane = sidebar.paneIndex
        let isFavoritesList = (pane == 1 && showFavoritesOnly) || (pane == 2 && showFavoritesOnlyPane2)
        loadQueue.async { [weak self] in
            let sorted = isFavoritesList
                ? ListSorter.sortFavorites(items, options: options)
                : ListSorter.sort(items, options: options)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Drop the result if the list was replaced or re-sorted meanwhile.
                guard sidebar.items.map({ $0.id }) == items.map({ $0.id }),
                      sidebar.sortOptions == options else { return }
                sidebar.setReorderedItems(sorted)
                if !isFavoritesList, let navMgr = (pane == 2) ? self.navigationManager2 : self.navigationManager1 {
                    self.rememberShownOrder(sorted, options: options, location: navMgr.currentLocation, pane: pane)
                }
            }
        }
    }

    private func rememberShownOrder(_ items: [FileItem], options: ListSortOptions, location: NavigationLocation, pane: Int) {
        let key = location.cacheKey
        var keys = shownOrderKeys[pane, default: []].filter { $0 != key }
        keys.append(key)
        var orders = shownOrders[pane, default: [:]]
        orders[key] = (options, items)
        while keys.count > MainSplitViewController.shownOrdersLimit {
            orders.removeValue(forKey: keys.removeFirst())
        }
        shownOrderKeys[pane] = keys
        shownOrders[pane] = orders
    }

    public func switchToCurrentItemLocationMode() {
        guard let item = sidebarContainerVC.sidebarVC1.selectedItem else {
            showFavoritesOnly = false
            return
        }
        showFavoritesOnly = false

        let targetPath = item.id.isEmpty ? item.path : item.id

        let loc: NavigationLocation
        if let archivePath = item.archivePath, !archivePath.isEmpty {
            let archiveType = ArchiveReader.fileType(for: URL(fileURLWithPath: archivePath))
            let subfolder = ArchiveReader.flattenArchiveDirectories ? "" : (item.entryParentDir ?? "")
            loc = NavigationLocation(
                physicalPath: archivePath,
                archiveSubfolder: subfolder,
                isArchive: true,
                archiveType: archiveType
            )
        } else {
            loc = NavigationManager.locationForPath(item.path)
        }

        print("[MainSplitVC] switchToCurrentItemLocationMode for item '\(item.name)', targetPath: '\(targetPath)', locPath: '\(loc.physicalPath)' (archiveSubfolder: '\(loc.archiveSubfolder ?? "")')")
        loadLocation(loc, pane: 1, targetSelectedItemPath: targetPath)
    }

    public func switchToCurrentItemLocationModePane2() {
        guard let item = sidebarContainerVC.sidebarVC2.selectedItem else {
            showFavoritesOnlyPane2 = false
            return
        }
        showFavoritesOnlyPane2 = false

        let targetPath = item.id.isEmpty ? item.path : item.id

        let loc: NavigationLocation
        if let archivePath = item.archivePath, !archivePath.isEmpty {
            let archiveType = ArchiveReader.fileType(for: URL(fileURLWithPath: archivePath))
            let subfolder = ArchiveReader.flattenArchiveDirectories ? "" : (item.entryParentDir ?? "")
            loc = NavigationLocation(
                physicalPath: archivePath,
                archiveSubfolder: subfolder,
                isArchive: true,
                archiveType: archiveType
            )
        } else {
            loc = NavigationManager.locationForPath(item.path)
        }

        print("[MainSplitVC] switchToCurrentItemLocationModePane2 for item '\(item.name)', targetPath: '\(targetPath)', locPath: '\(loc.physicalPath)' (archiveSubfolder: '\(loc.archiveSubfolder ?? "")')")
        loadLocation(loc, pane: 2, targetSelectedItemPath: targetPath)
    }

    public func displayItem(_ item: FileItem, pane: Int = 1) {
        let targetSidebar = (pane == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        if let currentSelected = targetSidebar.selectedItem, currentSelected.id != item.id {
            return
        }

        saveSelectionAndDualState()

        let nav = (pane == 2) ? navigationManager2 : navigationManager1
        let parentName: String
        if showFavoritesOnly && pane == 1 {
            parentName = "Favorites"
        } else if let nav = nav {
            parentName = (nav.currentLocation.physicalPath as NSString).lastPathComponent
        } else {
            parentName = ""
        }

        let imageItems = targetSidebar.items.filter { $0.type == .image }
        let currentIndex = imageItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        let totalImages = imageItems.count
        var containerStats: StatusBarView.ContainerPosition?
        if pane == 1 {
            containerStats = containerPosition(of: item, in: targetSidebar.items) { [weak self] counted in
                // Kept for the status bar updates below that run later.
                containerStats = counted
                guard let self = self, targetSidebar.selectedItem?.id == item.id else { return }
                self.statusBarView.updateSelectedItemStats(item: item, position: counted, parentName: parentName)
            }
        }

        if pane == activePane {
            fileInfoController?.refreshIfVisible(item: item)
        }

        if pane == 1 {
            if item.type == .image {
                statusBarView.updateImageInfo(item: item, image: nil, currentIndex: currentIndex, totalImages: totalImages,
                                              viewedPercent: viewedPercent(of: imageItems), parentName: parentName)
                if let archivePath = item.archivePath {
                    // The first image of an archive not read yet (e.g. opened
                    // at launch, its listing cached) waits for the archive read.
                    let archiveName = (archivePath as NSString).lastPathComponent
                    dualCanvasVC.imageView1.beginLoading(statusText: "Opening \(archiveName)...")
                }
            } else if item.type == .archiveZip || item.type == .archiveRar {
                statusBarView.updateSelectedItemStats(item: item, position: containerStats, parentName: parentName)
                // Indexing an archive for the first time can be slow; the
                // overlay appears only if the scan reports that it is.
                dualCanvasVC.imageView1.beginLoading(statusText: "Indexing \(item.name)...")
            }
        }

        if item.isDirectory || item.type == .parentDirectory {
            if pane == 1 {
                statusBarView.updateSelectedItemStats(item: item, position: containerStats, parentName: parentName)
                dualCanvasVC.setImage(nil, pane: 1)
            }
            return
        }

        let isArchive = item.type == .archiveZip || item.type == .archiveRar
        let loadProgress: LoadProgressHandler? = (pane == 1 && (isArchive || item.archivePath != nil)) ? { [weak self] update in
            guard let self = self, targetSidebar.selectedItem?.id == item.id else { return }
            self.dualCanvasVC.imageView1.updateLoadingProgress(update)
        } : nil

        ThumbnailGenerator.shared.loadFullImage(for: item, group: pane == 2 ? "pane2" : "main", progress: loadProgress) { [weak self] image in
            guard let self = self else { return }
            guard targetSidebar.selectedItem?.id == item.id else { return }

            if let image = image {
                if item.type == .image {
                    let key = item.archivePath != nil ? "\(item.archivePath!)#\(item.id)" : item.id
                    SQLiteCache.shared.markImageAsViewed(key: key)
                }

                self.dualCanvasVC.setImage(image, pane: pane, itemPath: item.id, archivePath: item.archivePath)
                if pane == 1 {
                    // Recounted: this image was just marked viewed.
                    self.statusBarView.updateImageInfo(item: item, image: image, currentIndex: currentIndex, totalImages: totalImages,
                                                       viewedPercent: self.viewedPercent(of: imageItems), parentName: parentName)
                }

                let cacheKey = "thumb_\(item.id)_256.0x256.0"
                let cost = Int(image.size.width * image.size.height * 4)
                MemoryLRUCache.shared.setObject(image, forKey: cacheKey, cost: cost)
                targetSidebar.updateThumbnailForSelectedItem(image: image)
            } else {
                self.dualCanvasVC.setImage(nil, pane: pane)
                if pane == 1 {
                    self.dualCanvasVC.imageView1.hideLoading()
                }
            }

            if isArchive {
                // The preview pass also computed the image count.
                targetSidebar.refreshStatsForSelectedItem()
                if pane == 1 {
                    self.statusBarView.updateSelectedItemStats(item: item, position: containerStats, parentName: parentName)
                }
            }

            targetSidebar.loadVisibleThumbnailsIfIdle()
            if image != nil, pane == 1 {
                // Browsing on in the archive should not wait for the disk.
                ThumbnailGenerator.shared.prefetchFollowingImages(after: item)
            }
        }
    }

    public func toggleFavoriteOnSelectedItem() {
        if let item = activeSidebar.selectedItem {
            let newState = SQLiteCache.shared.toggleFavorite(item: item)
            print("[MainSplitVC] Toggled favorite for item: \(item.name) (id: \(item.id), path: \(item.path)), newState isFavorite: \(newState)")
            activeSidebar.reloadSelectedRow()
            if showFavoritesOnly {
                reloadDirectoryContentsAsync(pane: activePane)
            }
        } else {
            print("[MainSplitVC] toggleFavoriteOnSelectedItem called but no item selected in active sidebar")
        }
    }

    // SidebarDelegate
    public func sidebar(_ sidebar: SidebarViewController, didSelectItem item: FileItem) {
        displayItem(item, pane: sidebar.paneIndex)
    }

    public func sidebar(_ sidebar: SidebarViewController, didActivateItem item: FileItem) {
        handleActivation(of: item, pane: sidebar.paneIndex)
    }

    public func sidebarDidBecomeActive(_ sidebar: SidebarViewController) {
        self.activePane = sidebar.paneIndex
    }

    public func handleActivation(of item: FileItem, pane: Int = 1) {
        if pane == 1 && showFavoritesOnly {
            switchToCurrentItemLocationMode()
            return
        }
        if pane == 2 && showFavoritesOnlyPane2 {
            switchToCurrentItemLocationModePane2()
            return
        }
        let navMgr = (pane == 2) ? navigationManager2 : navigationManager1
        guard let navMgr = navMgr else { return }
        if item.type == .image {
            if pane == 2 {
                selectNextImagePane2()
            } else {
                selectNextImage()
            }
        } else if item.type == .parentDirectory {
            navigateUp(pane: pane)
        } else if item.isDirectory || item.type == .archiveZip || item.type == .archiveRar {
            cancelAllIOOperations()
            if let _ = navMgr.navigateTo(item) {
                reloadDirectoryContentsAsync(pane: pane)
            }
        }
    }

    public func selectNextImage() {
        activeSidebar.selectNext()
    }

    public func selectPreviousImage() {
        activeSidebar.selectPrevious()
    }

    public func selectNextImagePane2() {
        if sidebarContainerVC.isDualView {
            sidebarContainerVC.sidebarVC2.selectNext()
        }
    }

    public func selectPreviousImagePane2() {
        if sidebarContainerVC.isDualView {
            sidebarContainerVC.sidebarVC2.selectPrevious()
        }
    }

    public func selectNextArchiveOrFolderFirstImage() {
        let currentSidebar = activeSidebar
        let items = currentSidebar.items
        guard let current = currentSidebar.selectedItem,
              let currentIdx = items.firstIndex(where: { $0.id == current.id }) else { return }

        let currentGroup = current.entryParentDir ?? ""
        for i in (currentIdx + 1)..<items.count {
            let item = items[i]
            let group = item.entryParentDir ?? ""
            if group != currentGroup && (item.type == .image || item.isDirectory || item.type == .archiveZip || item.type == .archiveRar) {
                currentSidebar.selectRow(i)
                return
            }
        }
    }

    public func selectPreviousArchiveOrFolderFirstImage() {
        let currentSidebar = activeSidebar
        let items = currentSidebar.items
        guard let current = currentSidebar.selectedItem,
              let currentIdx = items.firstIndex(where: { $0.id == current.id }) else { return }

        let currentGroup = current.entryParentDir ?? ""
        var prevGroup: String? = nil

        for i in stride(from: currentIdx - 1, through: 0, by: -1) {
            let group = items[i].entryParentDir ?? ""
            if group != currentGroup {
                prevGroup = group
                break
            }
        }

        if let prevGroup = prevGroup {
            for i in 0..<currentIdx {
                let item = items[i]
                if (item.entryParentDir ?? "") == prevGroup && (item.type == .image || item.isDirectory || item.type == .archiveZip || item.type == .archiveRar) {
                    currentSidebar.selectRow(i)
                    return
                }
            }
        }
    }

    public func selectPreviousHierarchyItem(pane: Int? = nil) {
        selectSiblingHierarchyItem(pane: pane, step: -1)
    }

    public func selectNextHierarchyItem(pane: Int? = nil) {
        selectSiblingHierarchyItem(pane: pane, step: 1)
    }

    /// Moves to the sibling `step` places away from the current location in
    /// its parent: an archive or folder is opened, a file is selected.
    ///
    /// Finding the sibling means listing the parent, possibly a directory
    /// read on a network volume, so it runs on `loadQueue` (behind the I/O
    /// gate) with the loading overlay armed.  Presses arriving meanwhile add
    /// to the step instead of walking further up.
    private func selectSiblingHierarchyItem(pane: Int?, step: Int) {
        let p = pane ?? activePane
        guard let navMgr = (p == 2) ? navigationManager2 : navigationManager1 else { return }

        if let pending = pendingSiblingSteps[p] {
            pendingSiblingSteps[p] = pending + step
            return
        }

        cancelAllIOOperations()
        let result = navMgr.navigateUp()
        let parentLocation = navMgr.currentLocation
        let sortOptions = ((p == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1).sortOptions
        let shownOrder = shownOrders[p]?[parentLocation.cacheKey]
        pendingSiblingSteps[p] = step
        if p == 1 {
            dualCanvasVC.imageView1.beginLoading(statusText: step > 0 ? "Opening next..." : "Opening previous...")
        }

        loadQueue.async { [weak self] in
            // Step through the parent as it was last shown in this sort mode;
            // otherwise list and sort it now.
            let parentItems: [FileItem]
            if let shown = shownOrder, shown.options == sortOptions {
                parentItems = shown.items
            } else {
                let listed = DiskIOGate.shared.perform(.interactive, label: parentLocation.physicalPath) {
                    NavigationManager(initialLocation: parentLocation).contents()
                }
                parentItems = ListSorter.sort(listed, options: sortOptions)
            }
            DispatchQueue.main.async {
                guard let self = self, let steps = self.pendingSiblingSteps.removeValue(forKey: p) else { return }
                guard navMgr.currentLocation == parentLocation else {
                    // Another navigation happened meanwhile and arms its own overlay.
                    if p == 1 { self.dualCanvasVC.imageView1.hideLoading() }
                    return
                }

                if let exitedIdx = parentItems.firstIndex(where: { $0.path == result.exitedItemPath || $0.id == result.exitedItemPath }),
                   parentItems.indices.contains(exitedIdx + steps) {
                    let sibling = parentItems[exitedIdx + steps]
                    if sibling.isDirectory || sibling.type == .archiveZip || sibling.type == .archiveRar {
                        _ = navMgr.navigateTo(sibling)
                        self.reloadDirectoryContentsAsync(pane: p)
                    } else {
                        self.reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: sibling.path)
                    }
                } else {
                    self.reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
                }
            }
        }
    }

    public enum RandomImageScope {
        /// Anywhere under the pane's location: its images, folders and archives.
        case currentLocation
        /// Anywhere in the selected folder or archive (the location when an image is selected).
        case selectedItem
    }

    /// Shows a random image in the pane (the active one by default).
    ///
    /// The image is found by a walk down from the start: each step picks
    /// one entry of a listing at random, an image ending the walk and a
    /// folder or archive being listed in turn, so no tree is ever listed
    /// whole (listings come from the cache when they can).  A walk that ends
    /// in an empty folder starts again.  It runs on `loadQueue` behind the
    /// I/O gate, and any navigation in the pane cancels it.
    public func showRandomImage(scope: RandomImageScope, pane: Int? = nil) {
        let p = pane ?? activePane
        guard p == 1 || sidebarContainerVC.isDualView else { return }
        let sidebar = (p == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        let inFavorites = (p == 2) ? showFavoritesOnlyPane2 : showFavoritesOnly
        let navMgr = (p == 2) ? navigationManager2 : navigationManager1
        let selected = sidebar.selectedItem
        let isContainer: (FileItem) -> Bool = {
            $0.type == .directory || $0.type == .archiveZip || $0.type == .archiveRar || ($0.isDirectory && $0.type != .parentDirectory)
        }

        let start: NavigationLocation
        if scope == .selectedItem, let selected = selected, isContainer(selected) {
            if inFavorites || navMgr == nil {
                guard selected.archivePath == nil else { return }
                start = NavigationManager.locationForPath(selected.path)
            } else if let navMgr = navMgr, let loc = NavigationManager(initialLocation: navMgr.currentLocation).navigateTo(selected) {
                start = loc
            } else {
                return
            }
        } else if inFavorites {
            // The favorites list is not a location to walk: pick among its images.
            let images = sidebar.items.indices.filter { sidebar.items[$0].type == .image && sidebar.items[$0].id != selected?.id }
            if let idx = images.randomElement() {
                sidebar.selectRow(idx)
            }
            return
        } else if let navMgr = navMgr {
            start = navMgr.currentLocation
        } else {
            return
        }

        cancelIOOperations(forPane: p)
        let avoidId = selected?.id
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            let found = MainSplitViewController.pickRandomImage(from: start, avoidingItemId: avoidId, isCancelled: { workItem.isCancelled })
            DispatchQueue.main.async {
                guard let self = self else { return }
                if workItem.isCancelled {
                    // A navigation in this pane arms its own overlay; one in the other pane does not.
                    if p == 1 && !self.isDirectoryLoadInFlight(pane: 1) && self.pendingSiblingSteps[1] == nil {
                        self.dualCanvasVC.imageView1.hideLoading()
                    }
                    return
                }
                self.lock.lock()
                if self.randomImageWalks[p] === workItem { self.randomImageWalks[p] = nil }
                self.lock.unlock()
                if p == 1 { self.dualCanvasVC.imageView1.hideLoading() }
                guard let found = found else {
                    self.statusBarView.showMessage("No images found")
                    return
                }
                self.showPickedImage(found.item, at: found.location, pane: p)
            }
        }
        lock.lock()
        randomImageWalks[p] = workItem
        lock.unlock()
        if p == 1 {
            dualCanvasVC.imageView1.beginLoading(statusText: "Picking a random image...")
        }
        loadQueue.async(execute: workItem)
    }

    private func showPickedImage(_ item: FileItem, at location: NavigationLocation, pane p: Int) {
        let sidebar = (p == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        let navMgr = (p == 2) ? navigationManager2 : navigationManager1
        let inFavorites = (p == 2) ? showFavoritesOnlyPane2 : showFavoritesOnly
        if !inFavorites, navMgr?.currentLocation == location,
           let idx = sidebar.items.firstIndex(where: { $0.id == item.id }) {
            sidebar.selectRow(idx)
            return
        }
        // Leaving favorites mode starts a reload of the location; the one below supersedes it.
        if p == 1 {
            navigationManager1 = NavigationManager(initialLocation: location)
            if showFavoritesOnly { showFavoritesOnly = false }
        } else {
            navigationManager2 = NavigationManager(initialLocation: location)
            if showFavoritesOnlyPane2 { showFavoritesOnlyPane2 = false }
        }
        if location.isArchive { cancelAllIOOperations() } else { cancelIOOperations(forPane: p) }
        reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: item.id)
    }

    /// Walks down from `start` picking entries at random until it reaches an
    /// image; see `showRandomImage`.  Off the main thread.
    private static func pickRandomImage(from start: NavigationLocation, avoidingItemId avoidId: String?, isCancelled: @escaping () -> Bool) -> (location: NavigationLocation, item: FileItem)? {
        let maxWalks = 8
        let maxDepth = 16
        for _ in 0..<maxWalks {
            let navMgr = NavigationManager(initialLocation: start)
            for depth in 0..<maxDepth {
                if isCancelled() { return nil }
                let location = navMgr.currentLocation
                let listed = DiskIOGate.shared.perform(.interactive, label: location.physicalPath) {
                    navMgr.contents(isCancelled: isCancelled)
                }
                if isCancelled() { return nil }
                var candidates = listed.filter {
                    $0.type == .image || $0.type == .directory || $0.type == .archiveZip || $0.type == .archiveRar
                        || ($0.isDirectory && $0.type != .parentDirectory)
                }
                // Prefer a different image from the one shown, when there is one.
                if candidates.count > 1, let avoidId = avoidId {
                    candidates.removeAll { $0.id == avoidId }
                }
                guard let pick = candidates.randomElement() else {
                    // Nothing at the start: no walk can find anything.
                    if depth == 0 { return nil }
                    break
                }
                if pick.type == .image { return (location, pick) }
                guard navMgr.navigateTo(pick) != nil else { break }
            }
        }
        return nil
    }

    public func activateSelectedItem() {
        if let item = activeSidebar.selectedItem {
            handleActivation(of: item, pane: activePane)
        }
    }

    public func navigateUp(pane: Int? = nil) {
        let p = pane ?? activePane
        let navMgr = (p == 2) ? navigationManager2 : navigationManager1
        guard let navMgr = navMgr else { return }
        cancelAllIOOperations()
        let result = navMgr.navigateUp()
        reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
    }

    public var imageView: MainImageView {
        return dualCanvasVC.imageView1
    }

    public func showInfoForSelectedItem() {
        if let item = activeSidebar.selectedItem {
            showInfo(for: item)
        }
    }

    public func showInfo(for item: FileItem) {
        if fileInfoController == nil {
            fileInfoController = FileInfoWindowController()
        }
        fileInfoController?.show(item: item, relativeTo: view.window)
    }
}
