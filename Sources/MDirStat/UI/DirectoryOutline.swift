import AppKit

/// Arborescence des dossiers, triee par taille, facon WinDirStat.
final class DirectoryOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()

    var root: FileNode? {
        didSet { reload(); if let root { outlineView.expandItem(root) } }
    }
    var onSelect: ((FileNode?) -> Void)?
    var menuProvider: ((FileNode) -> NSMenu?)?

    private enum Column: String, CaseIterable {
        case name, percent, size, items, files, modified

        var title: String {
            switch self {
            case .name: "Name"
            case .percent: "Subtree Percentage"
            case .size: "Size"
            case .items: "Items"
            case .files: "Files"
            case .modified: "Last Change"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .percent: 130
            case .size: 90
            case .items, .files: 90
            case .modified: 140
            }
        }
    }

    private var sortColumn: Column = .size
    private var ascending = false
    private var sortedCache: [ObjectIdentifier: [FileNode]] = [:]
    private var suppressSelection = false

    override init() {
        super.init()
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 120 : 50
            // Tailles, compteurs et dates se lisent du plus grand au plus petit.
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .name)
            // Seule la colonne des noms suit la largeur de la fenetre.
            if column != .name { tableColumn.resizingMask = .userResizingMask }
            if [.size, .items, .files].contains(column) {
                tableColumn.headerCell.alignment = .right
            }
            outlineView.addTableColumn(tableColumn)
            if column == .name { outlineView.outlineTableColumn = tableColumn }
        }
        outlineView.sortDescriptors = [NSSortDescriptor(key: Column.size.rawValue, ascending: false)]
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.autosaveName = "DirectoryOutline"
        outlineView.autosaveTableColumns = true
        outlineView.rowHeight = 20
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    var selectedNode: FileNode? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
    }

    /// Recharge apres une modification de l'arbre, en gardant la selection.
    func reload() {
        let selected = selectedNode
        sortedCache.removeAll()
        suppressSelection = true
        outlineView.reloadData()
        suppressSelection = false
        if let selected, let root, selected.isDescendant(of: root) { reveal(selected) }
    }

    /// Deplie les ancetres, selectionne et fait defiler jusqu'a l'element.
    func reveal(_ node: FileNode) {
        for ancestor in node.ancestors.reversed() {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        suppressSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelection = false
        outlineView.scrollRowToVisible(row)
    }

    private func children(of node: FileNode) -> [FileNode] {
        if sortColumn == .size && !ascending { return node.children }
        let key = ObjectIdentifier(node)
        if let cached = sortedCache[key] { return cached }
        let sorted = node.children.sorted(by: comparator)
        sortedCache[key] = sorted
        return sorted
    }

    private var comparator: (FileNode, FileNode) -> Bool {
        let ascending = self.ascending
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool { ascending ? a < b : a > b }
        switch sortColumn {
        case .name:
            return { a, b in
                let result = a.name.localizedStandardCompare(b.name)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size, .percent: return { order($0.size, $1.size) }
        case .items: return { order($0.items, $1.items) }
        case .files: return { order($0.files, $1.files) }
        case .modified: return { order($0.modified, $1.modified) }
        }
    }

    // MARK: - Source de donnees

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return root == nil ? 0 : 1 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return root! }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.kind == .directory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let column = Column(rawValue: descriptor.key ?? "") else { return }
        sortColumn = column
        ascending = descriptor.ascending
        reload()
    }

    // MARK: - Delegue

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode,
              let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell." + column.rawValue)

        if column == .percent {
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? PercentCell
                ?? PercentCell(identifier: identifier)
            let parentSize = node.parent?.size ?? node.size
            cell.fraction = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
            cell.barColor = PercentCell.color(depth: node.ancestors.count)
            return cell
        }

        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
            ?? TextCell(identifier: identifier, alignment: column == .name || column == .modified ? .left : .right,
                        withImage: column == .name)
        let field = cell.textField!
        field.textColor = node.isPseudo || node.unreadable ? .secondaryLabelColor : .labelColor
        field.toolTip = nil
        switch column {
        case .name:
            cell.imageView?.image = Icons.icon(for: node)
            field.stringValue = displayName(node)
            if node.unreadable { field.toolTip = "This folder could not be read. Grant Full Disk Access to MDirStat to include it." }
        case .size:
            field.stringValue = Format.bytes(node.size)
            field.toolTip = Format.count(Int(node.size)) + " bytes"
        case .items:
            field.stringValue = node.kind == .directory ? Format.count(node.items) : ""
        case .files:
            field.stringValue = node.kind == .directory ? Format.count(node.files) : ""
        case .modified:
            field.stringValue = Format.date(node.modified)
        case .percent:
            break
        }
        return cell
    }

    private func displayName(_ node: FileNode) -> String {
        switch node.kind {
        case .freeSpace: "<Free Space>"
        case .unknown: "<Unknown>"
        default: node.name
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelect?(selectedNode)
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode, node.kind == .directory else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: - Menu contextuel

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode,
              let built = menuProvider?(node) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}

extension PercentCell {
    /// Une couleur par niveau de profondeur, comme les barres de WinDirStat.
    static func color(depth: Int) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemYellow]
        return colors[depth % colors.count].withAlphaComponent(0.85)
    }
}
