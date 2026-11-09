import AppKit

/// Fenetre unique : arborescence et extensions en haut, treemap en bas, barre d'etat.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSUserInterfaceValidations, NSToolbarItemValidation, NSSplitViewDelegate {
    private let outline = DirectoryOutline()
    private let extensions = ExtensionList()
    private let treemap = TreemapView()
    private let mainSplit = NSSplitView()
    private let topSplit = NSSplitView()
    private let overlay = ScanOverlay()
    private let statusLabel = NSTextField(labelWithString: "")
    private let totalsLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "", target: nil, action: nil)

    private var root: FileNode?
    private var zoomRoot: FileNode? { didSet { treemap.root = zoomRoot } }
    private var stats: ExtensionStats?
    private var selected: FileNode?
    /// Capacite et espace libre, si la racine analysee est un volume.
    private var volume: (total: Int64, free: Int64)?
    private var scanner: Scanner?
    private var scanTimer: Timer?
    private var scanStart = Date()
    private var scanDuration: TimeInterval = 0
    private var picker: VolumePicker?
    private var awaitingRender = false

    /// Appele une fois, quand le premier treemap d'une analyse est affiche.
    var onScanDisplayed: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var showFreeSpace: Bool {
        get { defaults.bool(forKey: "showFreeSpace") }
        set { defaults.set(newValue, forKey: "showFreeSpace") }
    }
    private var showUnknown: Bool {
        get { defaults.object(forKey: "showUnknown") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showUnknown") }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MDirStat"
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildContent()
        connect()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Construction

    private func buildContent() {
        guard let window, let content = window.contentView else { return }

        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        // NSSplitView classique (cadres, pas Auto Layout) : la liste des extensions
        // garde sa largeur quand la fenetre change de taille, l'arborescence s'adapte.
        outline.scrollView.frame = NSRect(x: 0, y: 0, width: 840, height: 380)
        extensions.scrollView.frame = NSRect(x: 841, y: 0, width: 430, height: 380)
        topSplit.frame = NSRect(x: 0, y: 0, width: 1280, height: 380)
        treemap.frame = NSRect(x: 0, y: 381, width: 1280, height: 440)
        topSplit.addSubview(outline.scrollView)
        topSplit.addSubview(extensions.scrollView)
        topSplit.delegate = self
        topSplit.autosaveName = "TopSplit"

        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thin
        mainSplit.addSubview(topSplit)
        mainSplit.addSubview(treemap)
        mainSplit.delegate = self
        mainSplit.autosaveName = "MainSplit"

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        totalsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        totalsLabel.textColor = .secondaryLabelColor
        totalsLabel.setContentHuggingPriority(.required, for: .horizontal)
        accessButton.bezelStyle = .inline
        accessButton.controlSize = .small
        accessButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        accessButton.imagePosition = .imageLeading
        accessButton.contentTintColor = .systemOrange
        accessButton.target = self
        accessButton.action = #selector(openFullDiskAccess)
        accessButton.toolTip = "Some folders could not be read. Click to open the Full Disk Access settings."
        accessButton.isHidden = true

        let statusBar = NSStackView(views: [statusLabel, accessButton, totalsLabel])
        statusBar.orientation = .horizontal
        statusBar.spacing = 12
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        overlay.isHidden = true
        overlay.cancelButton.target = self
        overlay.cancelButton.action = #selector(cancelScan)

        for view in [mainSplit, statusBar, overlay] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            mainSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainSplit.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            overlay.leadingAnchor.constraint(equalTo: mainSplit.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: mainSplit.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: mainSplit.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: mainSplit.bottomAnchor),
        ])

        // Positions par defaut des separateurs, une fois la fenetre mise en page
        // (les vues du NSSplitView ont un cadre nul tant qu'il n'a pas tourne).
        let firstLaunch = defaults.object(forKey: "NSSplitView Subview Frames MainSplit") == nil
        DispatchQueue.main.async { [self] in
            content.layoutSubtreeIfNeeded()
            if firstLaunch || extensions.scrollView.frame.width < 40 && !extensions.scrollView.isHidden {
                topSplit.setPosition(topSplit.bounds.width * 0.66, ofDividerAt: 0)
            }
            if firstLaunch {
                // Ramene les colonnes a la largeur visible, sans defilement horizontal.
                topSplit.layoutSubtreeIfNeeded()
                outline.outlineView.sizeToFit()
                extensions.tableView.sizeToFit()
            }
            if firstLaunch || treemap.frame.height < 40 && !treemap.isHidden {
                mainSplit.setPosition(mainSplit.bounds.height * 0.45, ofDividerAt: 0)
            }
        }
        treemap.isHidden = defaults.bool(forKey: "hideTreemap")
        extensions.scrollView.isHidden = defaults.bool(forKey: "hideExtensions")
        updateStatus()
    }

    private func connect() {
        outline.onSelect = { [weak self] node in
            if let node { self?.select(node, fromTreemap: false) }
        }
        outline.menuProvider = { [weak self] node in self?.contextMenu(for: node) }
        treemap.onSelect = { [weak self] node in self?.select(node, fromTreemap: true) }
        treemap.onHover = { [weak self] node in self?.updateStatus(hovered: node) }
        treemap.menuProvider = { [weak self] node in self?.contextMenu(for: node) }
        treemap.onRendered = { [weak self] in
            guard let self, self.awaitingRender else { return }
            self.awaitingRender = false
            self.onScanDisplayed?()
        }
        extensions.onSelect = { [weak self] id in self?.treemap.highlightedExtension = id }
    }

    // MARK: - Analyse

    /// Feuille de choix d'un volume ou d'un dossier.
    @objc func openDocument(_ sender: Any?) {
        guard let window, picker == nil, window.attachedSheet == nil else { return }
        let picker = VolumePicker()
        self.picker = picker
        picker.begin(on: window) { [weak self] url in
            self?.picker = nil
            if let url { self?.startScan(url: url) }
        }
    }

    func startScan(url: URL) {
        let path = url.standardizedFileURL.path
        volume = MainWindowController.volumeInfo(for: url)
        treemap.cancelRendering()
        root = nil
        zoomRoot = nil
        stats = nil
        selected = nil
        outline.root = nil
        extensions.stats = nil
        treemap.selection = nil
        treemap.highlightedExtension = nil
        window?.title = "MDirStat"
        window?.subtitle = path
        window?.representedURL = nil

        runScan(path: path, name: nil, title: "Scanning \(path)") { [weak self] node, stats in
            guard let self else { return }
            guard let node, let stats else { return }
            self.root = node
            self.stats = stats
            self.applyPseudoNodes()
            self.outline.root = node
            self.extensions.stats = stats
            self.treemap.colors = stats.colorsByID
            self.awaitingRender = true
            self.zoomRoot = node
            self.selected = node
            self.outline.reveal(node)
            self.treemap.selection = node
            self.window?.representedURL = URL(fileURLWithPath: path)
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
            self.updateTitle()
            self.updateStatus()
        }
    }

    /// Analyse un dossier sur un fil a part ; completion sur le fil principal.
    /// Les statistiques ne sont calculees que pour une analyse complete (name == nil).
    private func runScan(path: String, name: String?, title: String,
                         completion: @escaping (FileNode?, ExtensionStats?) -> Void) {
        scanner?.cancel()
        let scanner = Scanner(path: path)
        self.scanner = scanner
        scanStart = Date()
        overlay.show(title: title)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateProgress(scanner.progress.snapshot)
        }

        Scanner.runDetached {
            let node = scanner.run(rootName: name)
            let stats = name == nil ? node.map { ExtensionStats(root: $0) } : nil
            DispatchQueue.main.async {
                guard self.scanner === scanner else { return }
                self.scanner = nil
                self.scanTimer?.invalidate()
                self.scanTimer = nil
                self.scanDuration = Date().timeIntervalSince(self.scanStart)
                self.overlay.hide()
                if node == nil && !scanner.cancelled {
                    let alert = NSAlert()
                    alert.messageText = "Cannot read “\(path)”."
                    alert.informativeText = "The folder does not exist or MDirStat is not allowed to read it."
                    if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
                completion(node, stats)
            }
        }
    }

    private func updateProgress(_ progress: ScanProgress.Snapshot) {
        overlay.detailLabel.stringValue = "\(Format.count(progress.files)) files  ·  "
            + "\(Format.count(progress.dirs)) folders  ·  \(Format.bytes(progress.bytes))  ·  "
            + Format.elapsed(Date().timeIntervalSince(scanStart))
    }

    @objc func cancelScan(_ sender: Any?) {
        scanner?.cancel()
    }

    @objc func rescan(_ sender: Any?) {
        guard let root, scanner == nil else { return }
        startScan(url: URL(fileURLWithPath: root.name))
    }

    /// Reanalyse le dossier choisi et le remplace dans l'arbre.
    @objc func refreshSelected(_ sender: Any?) {
        guard scanner == nil, let node = targetNode(sender) else { return }
        guard let directory = node.kind == .directory ? node : node.parent else { return }
        guard let parent = directory.parent else { rescan(sender); return }
        runScan(path: directory.path, name: directory.name, title: "Refreshing \(directory.path)") { [weak self] fresh, _ in
            guard let self, let fresh, let root = self.root else { return }
            self.treemap.cancelRendering()
            treeLock.lock()
            parent.replaceChild(directory, with: fresh)
            let stats = ExtensionStats(root: root)
            treeLock.unlock()
            self.stats = stats
            self.treemap.colors = stats.colorsByID
            self.extensions.stats = stats
            if let zoom = self.zoomRoot, zoom.isDescendant(of: directory) { self.zoomRoot = fresh }
            self.applyPseudoNodes()
            self.reloadAll()
            self.select(fresh, fromTreemap: true)
        }
    }

    private static func volumeInfo(for url: URL) -> (total: Int64, free: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys), let volumeURL = values.volume,
              volumeURL.standardizedFileURL.path == url.standardizedFileURL.path else { return nil }
        return (Int64(values.volumeTotalCapacity ?? 0), Int64(values.volumeAvailableCapacity ?? 0))
    }

    /// Ajoute ou retire <Free Space> et <Unknown> sous la racine d'un volume.
    private func applyPseudoNodes() {
        guard let root else { return }
        treemap.cancelRendering()
        treeLock.lock()
        defer { treeLock.unlock() }
        for node in root.children where node.isPseudo { root.size -= node.size }
        root.children.removeAll { $0.isPseudo }
        if let volume {
            let scanned = root.size
            let used = volume.total - volume.free
            if showUnknown && used > scanned {
                let unknown = FileNode(name: "<Unknown>", kind: .unknown, parent: root)
                unknown.size = used - scanned
                root.children.append(unknown)
            }
            if showFreeSpace && volume.free > 0 {
                let free = FileNode(name: "<Free Space>", kind: .freeSpace, parent: root)
                free.size = volume.free
                root.children.append(free)
            }
            for node in root.children where node.isPseudo { root.size += node.size }
        }
        root.sortChildren()
    }

    private func reloadAll() {
        outline.reload()
        extensions.reload()
        treemap.invalidate()
        updateTitle()
        updateStatus()
    }

    // MARK: - Selection et etat

    private func select(_ node: FileNode, fromTreemap: Bool) {
        selected = node
        treemap.selection = node
        if fromTreemap { outline.reveal(node) }
        updateStatus()
    }

    private func updateTitle() {
        guard let window, let root else { return }
        window.title = root.name == "/" ? (FileManager.default.displayName(atPath: "/")) : (root.name as NSString).lastPathComponent
        window.subtitle = "\(root.name)  ·  \(Format.bytes(root.size))"
    }

    private func updateStatus(hovered: FileNode? = nil) {
        if let node = hovered ?? selected {
            var text = node.isPseudo ? (node.kind == .freeSpace ? "Free space" : "Unknown (not found by the scan)") : node.path
            text += "    \(Format.bytes(node.size))"
            if node.kind == .directory && node !== root { text += "  ·  \(Format.count(node.files)) files" }
            if let root, !node.isPseudo, root.size > 0, node !== root {
                text += "  ·  \(Format.percent(Double(node.size) / Double(root.size))) of total"
            }
            statusLabel.stringValue = text
        } else {
            statusLabel.stringValue = root == nil ? "Ready" : ""
        }

        if let root {
            totalsLabel.stringValue = "\(Format.count(root.files)) files  ·  \(Format.count(root.subdirs)) folders  ·  "
                + "scanned in \(Format.elapsed(scanDuration))"
            accessButton.isHidden = root.errors == 0
            accessButton.title = root.errors == 1 ? "1 folder unreadable" : "\(Format.count(root.errors)) folders unreadable"
        } else {
            totalsLabel.stringValue = ""
            accessButton.isHidden = true
        }
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Actions sur un element

    private func targetNode(_ sender: Any?) -> FileNode? {
        ((sender as? NSMenuItem)?.representedObject as? FileNode) ?? selected
    }

    private func contextMenu(for node: FileNode) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        add("Open", #selector(openItem))
        add("Reveal in Finder", #selector(revealInFinder))
        add("Copy Path", #selector(copy(_:)))
        menu.addItem(.separator())
        add("Zoom Treemap Here", #selector(zoomIn))
        add("Refresh", #selector(refreshSelected))
        menu.addItem(.separator())
        add("Move to Trash", #selector(moveToTrash))
        return menu
    }

    @objc func openItem(_ sender: Any?) {
        guard let node = targetNode(sender), !node.isPseudo else { return }
        NSWorkspace.shared.open(node.url)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let node = targetNode(sender), !node.isPseudo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc func copy(_ sender: Any?) {
        guard let node = targetNode(sender), !node.isPseudo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    @objc func selectParent(_ sender: Any?) {
        guard let parent = selected?.parent else { return }
        select(parent, fromTreemap: true)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let window, let node = targetNode(sender), !node.isPseudo, let parent = node.parent else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = "\(Format.bytes(node.size)) will be moved to the Trash from \(parent.path)."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
            self.treemap.cancelRendering()
            treeLock.lock()
            parent.removeChild(node)
            self.stats?.remove(subtree: node)
            treeLock.unlock()
            if let zoom = self.zoomRoot, zoom.isDescendant(of: node) { self.zoomRoot = parent }
            self.applyPseudoNodes()
            self.selected = parent
            self.treemap.selection = parent
            self.reloadAll()
            self.outline.reveal(parent)
        }
    }

    // MARK: - Treemap

    @objc func zoomIn(_ sender: Any?) {
        guard let node = targetNode(sender) else { return }
        guard let target = node.kind == .directory ? node : node.parent, target !== zoomRoot else { return }
        zoomRoot = target
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let parent = zoomRoot?.parent else { return }
        zoomRoot = parent
    }

    @objc func resetZoom(_ sender: Any?) {
        guard let root, zoomRoot !== root else { return }
        zoomRoot = root
    }

    @objc func toggleFreeSpace(_ sender: Any?) {
        showFreeSpace.toggle()
        applyPseudoNodes()
        reloadAll()
    }

    @objc func toggleUnknown(_ sender: Any?) {
        showUnknown.toggle()
        applyPseudoNodes()
        reloadAll()
    }

    @objc func toggleTreemap(_ sender: Any?) {
        treemap.isHidden.toggle()
        defaults.set(treemap.isHidden, forKey: "hideTreemap")
        mainSplit.adjustSubviews()
    }

    @objc func toggleExtensions(_ sender: Any?) {
        extensions.scrollView.isHidden.toggle()
        defaults.set(extensions.scrollView.isHidden, forKey: "hideExtensions")
        topSplit.adjustSubviews()
    }

    // MARK: - Separateurs

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView !== topSplit || view !== extensions.scrollView
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, 120)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - 120)
    }

    // MARK: - Validation

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let node = (item as? NSMenuItem)?.representedObject as? FileNode ?? selected
        let idle = scanner == nil
        let menuItem = item as? NSMenuItem
        switch item.action {
        case #selector(openDocument): return idle
        case #selector(rescan): return idle && root != nil
        case #selector(cancelScan): return !idle
        case #selector(refreshSelected): return idle && node != nil && !(node?.isPseudo ?? true)
        case #selector(openItem), #selector(revealInFinder), #selector(copy(_:)):
            return node != nil && !(node?.isPseudo ?? true)
        case #selector(moveToTrash): return idle && node?.parent != nil && !(node?.isPseudo ?? true)
        case #selector(selectParent): return selected?.parent != nil
        case #selector(zoomIn):
            guard let node, !node.isPseudo else { return false }
            return (node.kind == .directory ? node : node.parent) !== zoomRoot
        case #selector(zoomOut): return zoomRoot?.parent != nil
        case #selector(resetZoom): return root != nil && zoomRoot !== root
        case #selector(toggleFreeSpace):
            menuItem?.state = showFreeSpace ? .on : .off
            return true
        case #selector(toggleUnknown):
            menuItem?.state = showUnknown ? .on : .off
            return true
        case #selector(toggleTreemap):
            menuItem?.title = treemap.isHidden ? "Show Treemap" : "Hide Treemap"
            return true
        case #selector(toggleExtensions):
            menuItem?.title = extensions.scrollView.isHidden ? "Show Extension List" : "Hide Extension List"
            return true
        default: return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validateUserInterfaceItem(item)
    }

    // MARK: - Barre d'outils

    private enum ToolbarID {
        static let open = NSToolbarItem.Identifier("open")
        static let rescan = NSToolbarItem.Identifier("rescan")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let trash = NSToolbarItem.Identifier("trash")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.open, ToolbarID.rescan, .flexibleSpace, ToolbarID.zoomOut, ToolbarID.zoomIn,
         .space, ToolbarID.reveal, ToolbarID.trash]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let specs: [NSToolbarItem.Identifier: (String, String, Selector)] = [
            ToolbarID.open: ("Open", "folder", #selector(openDocument)),
            ToolbarID.rescan: ("Rescan", "arrow.clockwise", #selector(rescan)),
            ToolbarID.zoomIn: ("Zoom In", "plus.magnifyingglass", #selector(zoomIn)),
            ToolbarID.zoomOut: ("Zoom Out", "minus.magnifyingglass", #selector(zoomOut)),
            ToolbarID.reveal: ("Reveal in Finder", "magnifyingglass", #selector(revealInFinder)),
            ToolbarID.trash: ("Move to Trash", "trash", #selector(moveToTrash)),
        ]
        guard let (label, symbol, action) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.isBordered = true
        return item
    }

    // MARK: - Fenetre

    func windowWillClose(_ notification: Notification) {
        scanner?.cancel()
    }

    /// Image de la fenetre, pour les verifications automatiques (MDIRSTAT_SNAPSHOT).
    func snapshot(to path: String) {
        let target = window?.attachedSheet ?? window
        guard let view = target?.contentView?.superview ?? target?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
