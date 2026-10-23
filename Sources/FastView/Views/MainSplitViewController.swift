import AppKit

public class MainSplitViewController: NSSplitViewController, SidebarDelegate {
    public let sidebarContainerVC = SidebarContainerViewController()
    public let dualCanvasVC = DualCanvasViewController()
    private let mainContentVC = NSViewController()
    private let statusBarView = StatusBarView()

    private var navigationManager1: NavigationManager?
    private var navigationManager2: NavigationManager?
    private let loadQueue = DispatchQueue(label: "com.fastview.directoryload", qos: .userInitiated)
    private var currentDirectoryLoadItem1: DispatchWorkItem?
    private var currentDirectoryLoadItem2: DispatchWorkItem?
    private let lock = NSLock()
    private static let sidebarWidthKey = "FastViewSidebarWidth"

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
    private var lastSelectedInfoPath: String?
    public private(set) var lastMeasuredSpeedMBs: Double = 25.0

    @objc private func copyInfoPathAction() {
        if let path = lastSelectedInfoPath {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
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

    public var showFavoritesOnly: Bool = false {
        didSet {
            UserDefaults.standard.set(showFavoritesOnly, forKey: "FastViewIsFavoritesMode")
            if showFavoritesOnly != oldValue {
                reloadDirectoryContentsAsync()
            }
        }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        splitView.delegate = self
        let savedWidth = UserDefaults.standard.double(forKey: MainSplitViewController.sidebarWidthKey)
        if savedWidth > 120 && splitView.subviews.count > 0 {
            splitView.setPosition(CGFloat(savedWidth), ofDividerAt: 0)
        }
    }

    override public func splitViewDidResizeSubviews(_ notification: Notification) {
        if splitView.subviews.count > 0 {
            let currentWidth = splitView.subviews[0].frame.width
            if currentWidth > 120 {
                UserDefaults.standard.set(currentWidth, forKey: MainSplitViewController.sidebarWidthKey)
            }
        }
    }

    private func setupUI() {
        sidebarContainerVC.sidebarVC1.delegate = self
        sidebarContainerVC.sidebarVC2.delegate = self
        activePane = 1

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

        let mainItem = NSSplitViewItem(viewController: mainContentVC)
        mainItem.minimumThickness = 300

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
    }

    public func loadLocation(_ location: NavigationLocation, pane: Int = 1, targetSelectedItemPath: String? = nil) {
        cancelIOOperations(forPane: pane)
        if pane == 1 {
            navigationManager1 = NavigationManager(initialLocation: location)
            reloadDirectoryContentsAsync(pane: 1, targetSelectedItemPath: targetSelectedItemPath)
        } else {
            navigationManager2 = NavigationManager(initialLocation: location)
            sidebarContainerVC.updateViewMode(isDual: true)
            dualCanvasVC.setDualViewEnabled(true)
            activePane = 2
            reloadDirectoryContentsAsync(pane: 2, targetSelectedItemPath: targetSelectedItemPath)
        }
    }

    @objc public func openSecondFolder() {
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
        UserDefaults.standard.set(false, forKey: "FastViewIsDualViewEnabled")
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
        UserDefaults.standard.set(canvas.fg1OnTop, forKey: "FastViewFG1OnTop")
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
            if UserDefaults.standard.object(forKey: "FastViewFG1OnTop") != nil {
                self.dualCanvasVC.combiningCanvasView.fg1OnTop = UserDefaults.standard.bool(forKey: "FastViewFG1OnTop")
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
        lock.unlock()
    }

    public func cancelAllIOOperations() {
        cancelIOOperations(forPane: 1)
        cancelIOOperations(forPane: 2)
        ThumbnailGenerator.shared.cancelAllPendingTasks()
    }

    public func reloadDirectoryContentsPublic() {
        reloadDirectoryContentsAsync(pane: activePane)
    }

    private func reloadDirectoryContentsAsync(pane: Int = 1, targetSelectedItemPath: String? = nil, isNavigatingUp: Bool = false) {
        cancelIOOperations(forPane: pane)

        let targetSidebar = (pane == 2) ? sidebarContainerVC.sidebarVC2 : sidebarContainerVC.sidebarVC1
        let navMgr = (pane == 2) ? navigationManager2 : navigationManager1

        let startTime = CFAbsoluteTimeGetCurrent()

        if showFavoritesOnly && pane == 1 {
            let favorites = SQLiteCache.shared.getAllFavorites()
            targetSidebar.setHeaderTitle("Favorites")
            targetSidebar.setItems(favorites, selectFirst: targetSelectedItemPath == nil)
            statusBarView.updateDirectoryStats(imageCount: favorites.count, totalSizeBytes: 0, locationName: "Favorites")

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
            return
        }

        guard let navMgr = navMgr else { return }

        let path = navMgr.currentLocation.physicalPath
        let isArchive = navMgr.currentLocation.isArchive

        let archiveURL = URL(fileURLWithPath: path)
        let archiveName = archiveURL.lastPathComponent
        let folderName = archiveURL.deletingLastPathComponent().lastPathComponent

        var archiveSize: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            archiveSize = size
        }

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
            statusBarView.updateDirectoryStats(imageCount: 0, totalSizeBytes: archiveSize, locationName: locationTitle)
        }

        if isArchive && pane == 1 {
            let loadingMessage = String(format: "Opening archive %@...", archiveName)
            dualCanvasVC.imageView1.showLoading(fileSizeBytes: archiveSize, pastSpeedMBs: lastMeasuredSpeedMBs, statusText: loadingMessage)
        }

        FileLogger.shared.log("DIR_OPEN_START", path: path)

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !workItem.isCancelled else { return }

            let items = navMgr.contents()
            if workItem.isCancelled { return }

            let elapsedTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            FileLogger.shared.log("DIR_OPEN_END", path: path, durationMs: elapsedTime)

            let imageItems = items.filter { $0.type == .image }

            DispatchQueue.main.async {
                if workItem.isCancelled { return }
                targetSidebar.setItems(items, selectFirst: targetSelectedItemPath == nil)

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

    public func switchToCurrentItemLocationMode() {
        guard let item = activeSidebar.selectedItem else {
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
        loadLocation(loc, pane: activePane, targetSelectedItemPath: targetPath)
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

        if pane == 1 {
            if item.type == .image {
                statusBarView.updateImageInfo(item: item, image: nil, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)
                if MemoryLRUCache.shared.object(forKey: "full_\(item.id)") == nil {
                    dualCanvasVC.imageView1.showLoading(fileSizeBytes: item.fileSize, pastSpeedMBs: lastMeasuredSpeedMBs)
                }
            } else if item.type == .archiveZip || item.type == .archiveRar {
                statusBarView.updateSelectedItemStats(item: item, containedImagesCount: nil, parentName: parentName)
            }
        }

        if item.isDirectory || item.type == .parentDirectory {
            if pane == 1 {
                statusBarView.updateSelectedItemStats(item: item, containedImagesCount: nil, parentName: parentName)
                dualCanvasVC.setImage(nil, pane: 1)
            }
            return
        }

        let readStartTime = CFAbsoluteTimeGetCurrent()

        ThumbnailGenerator.shared.loadFullImage(for: item) { [weak self] image in
            guard let self = self else { return }
            guard targetSidebar.selectedItem?.id == item.id else { return }

            if let image = image {
                let duration = CFAbsoluteTimeGetCurrent() - readStartTime
                if duration > 0 && item.fileSize > 0 {
                    let speedMBs = (Double(item.fileSize) / (1024.0 * 1024.0)) / duration
                    self.lastMeasuredSpeedMBs = (self.lastMeasuredSpeedMBs * 0.7) + (speedMBs * 0.3)
                }

                self.dualCanvasVC.setImage(image, pane: pane)
                if pane == 1 {
                    self.statusBarView.updateImageInfo(item: item, image: image, currentIndex: currentIndex, totalImages: totalImages, parentName: parentName)
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

            targetSidebar.loadVisibleThumbnailsIfIdle()
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
        if showFavoritesOnly {
            switchToCurrentItemLocationMode()
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
        let p = pane ?? activePane
        let navMgr = (p == 2) ? navigationManager2 : navigationManager1
        guard let navMgr = navMgr else { return }
        cancelAllIOOperations()

        let result = navMgr.navigateUp()
        let parentLocation = navMgr.currentLocation
        let parentMgr = NavigationManager(initialLocation: parentLocation)
        let parentItems = parentMgr.contents()

        if let exitedIdx = parentItems.firstIndex(where: { $0.path == result.exitedItemPath || $0.id == result.exitedItemPath }),
           exitedIdx > 0 {
            let prevSibling = parentItems[exitedIdx - 1]
            if prevSibling.isDirectory || prevSibling.type == .archiveZip || prevSibling.type == .archiveRar {
                _ = navMgr.navigateTo(prevSibling)
                reloadDirectoryContentsAsync(pane: p)
            } else {
                reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: prevSibling.path)
            }
        } else {
            reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
        }
    }

    public func selectNextHierarchyItem(pane: Int? = nil) {
        let p = pane ?? activePane
        let navMgr = (p == 2) ? navigationManager2 : navigationManager1
        guard let navMgr = navMgr else { return }
        cancelAllIOOperations()
        let result = navMgr.navigateUp()
        let parentLocation = navMgr.currentLocation
        let parentMgr = NavigationManager(initialLocation: parentLocation)
        let parentItems = parentMgr.contents()

        if let exitedIdx = parentItems.firstIndex(where: { $0.path == result.exitedItemPath || $0.id == result.exitedItemPath }),
           exitedIdx < parentItems.count - 1 {
            let nextSibling = parentItems[exitedIdx + 1]
            if nextSibling.isDirectory || nextSibling.type == .archiveZip || nextSibling.type == .archiveRar {
                _ = navMgr.navigateTo(nextSibling)
                reloadDirectoryContentsAsync(pane: p)
            } else {
                reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: nextSibling.path)
            }
        } else {
            reloadDirectoryContentsAsync(pane: p, targetSelectedItemPath: result.exitedItemPath, isNavigatingUp: true)
        }
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
        guard let item = sidebarVC.selectedItem else { return }

        let alert = NSAlert()
        alert.messageText = "File Information"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Close")

        let fullPath = item.archivePath != nil ? "\(item.archivePath!) / \(item.path)" : item.path
        let fsPath = item.archivePath ?? item.path
        let fileManager = FileManager.default

        var createdStr = "N/A"
        var modifiedStr = "N/A"
        var sizeStr = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

        if let attrs = try? fileManager.attributesOfItem(atPath: fsPath) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium

            if let creationDate = attrs[.creationDate] as? Date {
                createdStr = dateFormatter.string(from: creationDate)
            }
            if let modDate = attrs[.modificationDate] as? Date {
                modifiedStr = dateFormatter.string(from: modDate)
            }
            if let sizeNum = attrs[.size] as? Int64 {
                sizeStr = ByteCountFormatter.string(fromByteCount: sizeNum, countStyle: .file)
            }
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 160))

        let gridView = NSGridView(numberOfColumns: 2, rows: 0)
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 8
        gridView.columnSpacing = 12

        func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
            let tf = NSTextField(labelWithString: text)
            tf.font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
            tf.textColor = NSColor.secondaryLabelColor
            return tf
        }

        func makeValueField(_ text: String) -> NSTextField {
            let tf = NSTextField(string: text)
            tf.isEditable = false
            tf.isSelectable = true
            tf.drawsBackground = false
            tf.isBezeled = false
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.textColor = NSColor.labelColor
            tf.lineBreakMode = .byCharWrapping
            return tf
        }

        let pathContainer = NSStackView()
        pathContainer.orientation = .horizontal
        pathContainer.spacing = 8
        pathContainer.alignment = .centerY

        let pathField = makeValueField(fullPath)
        pathContainer.addArrangedSubview(pathField)

        let copyBtn = NSButton(title: "Copy Path", target: self, action: #selector(copyInfoPathAction))
        copyBtn.bezelStyle = .inline
        copyBtn.controlSize = .small
        pathContainer.addArrangedSubview(copyBtn)

        gridView.addRow(with: [makeLabel("Name:", bold: true), makeValueField(item.name)])
        gridView.addRow(with: [makeLabel("Path:", bold: true), pathContainer])
        gridView.addRow(with: [makeLabel("Size:", bold: true), makeValueField(sizeStr)])
        gridView.addRow(with: [makeLabel("Created:", bold: true), makeValueField(createdStr)])
        gridView.addRow(with: [makeLabel("Modified:", bold: true), makeValueField(modifiedStr)])

        container.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            gridView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        alert.accessoryView = container

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
