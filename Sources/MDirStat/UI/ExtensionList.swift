import AppKit

/// Extension list: treemap color, bytes, share and file count.
final class ExtensionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = NSTableView()

    var stats: ExtensionStats? { didSet { reload() } }
    var onSelect: ((Int32?) -> Void)?

    private enum Column: String, CaseIterable {
        case ext, description, bytes, percent, files

        var title: String {
            switch self {
            case .ext: "Extension"
            case .description: "Description"
            case .bytes: "Bytes"
            case .percent: "% Bytes"
            case .files: "Files"
            }
        }

        var width: CGFloat {
            switch self {
            case .ext: 84
            case .description: 130
            case .bytes: 76
            case .percent: 58
            case .files: 62
            }
        }
    }

    /// Indices into stats.entries, in display order.
    private var rows: [Int] = []
    private var suppressSelection = false

    override init() {
        super.init()
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue,
                                                                   ascending: column == .ext || column == .description)
            // Only the description column follows the pane width.
            if column != .description { tableColumn.resizingMask = .userResizingMask }
            if [.bytes, .percent, .files].contains(column) { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.bytes.rawValue, ascending: false)]
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.autosaveName = "ExtensionList"
        tableView.autosaveTableColumns = true
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    func reload() {
        let selected = selectedExtension
        if let stats {
            rows = stats.entries.indices.filter { stats.entries[$0].files > 0 }
            sortRows()
        } else {
            rows = []
        }
        suppressSelection = true
        tableView.reloadData()
        if let selected, let row = rows.firstIndex(of: Int(selected)) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        suppressSelection = false
    }

    var selectedExtension: Int32? {
        let row = tableView.selectedRow
        return row >= 0 && row < rows.count ? Int32(rows[row]) : nil
    }

    /// Selects the extension of a file chosen elsewhere, without sending the event back.
    func reveal(extension id: Int32?) {
        suppressSelection = true
        if let id, let row = rows.firstIndex(of: Int(id)) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        suppressSelection = false
    }

    private func sortRows() {
        guard let stats, let descriptor = tableView.sortDescriptors.first,
              let column = Column(rawValue: descriptor.key ?? "") else { return }
        let entries = stats.entries
        let ascending = descriptor.ascending
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool { ascending ? a < b : a > b }
        switch column {
        case .ext: rows.sort { order(entries[$0].ext, entries[$1].ext) }
        case .description:
            rows.sort { order(ExtensionStats.description(of: entries[$0].ext), ExtensionStats.description(of: entries[$1].ext)) }
        case .bytes, .percent: rows.sort { order(entries[$0].bytes, entries[$1].bytes) }
        case .files: rows.sort { order(entries[$0].files, entries[$1].files) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reload()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let stats, let column = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let entry = stats.entries[rows[row]]
        let identifier = NSUserInterfaceItemIdentifier("ext." + column.rawValue)
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
            ?? TextCell(identifier: identifier,
                        alignment: column == .ext || column == .description ? .left : .right,
                        withImage: column == .ext)
        let field = cell.textField!
        switch column {
        case .ext:
            let color = entry.colorIndex >= 0 ? ExtensionStats.palette[entry.colorIndex] : ExtensionStats.otherColor
            cell.imageView?.image = Icons.swatch(color)
            field.stringValue = entry.ext.isEmpty ? "(none)" : "." + entry.ext
        case .description:
            field.stringValue = ExtensionStats.description(of: entry.ext)
        case .bytes:
            field.stringValue = Format.bytes(entry.bytes)
        case .percent:
            let total = stats.totalBytes
            field.stringValue = total > 0 ? Format.percent(Double(entry.bytes) / Double(total)) : ""
        case .files:
            field.stringValue = Format.count(entry.files)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelect?(selectedExtension)
    }
}
