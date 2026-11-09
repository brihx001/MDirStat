import AppKit

/// Feuille de depart : choisir un volume monte, le dossier personnel ou un dossier.
final class VolumePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Volume {
        let url: URL
        let name: String
        let total: Int64
        let free: Int64
        let icon: NSImage
    }

    private let panel: NSPanel
    private let tableView = NSTableView()
    private var volumes: [Volume] = []
    private var completion: ((URL?) -> Void)?
    private weak var parentWindow: NSWindow?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.minSize = NSSize(width: 480, height: 260)
        loadVolumes()
        buildContent()
    }

    func begin(on window: NSWindow, completion: @escaping (URL?) -> Void) {
        self.completion = completion
        parentWindow = window
        window.beginSheet(panel)
        panel.makeFirstResponder(tableView)
    }

    private func finish(_ url: URL?) {
        parentWindow?.endSheet(panel)
        let completion = self.completion
        self.completion = nil
        completion?(url)
    }

    private func loadVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsBrowsableKey, .effectiveIconKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false else { return nil }
            return Volume(url: url,
                          name: values.volumeLocalizedName ?? url.lastPathComponent,
                          total: Int64(values.volumeTotalCapacity ?? 0),
                          free: Int64(values.volumeAvailableCapacity ?? 0),
                          icon: (values.effectiveIcon as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path))
        }
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "Select a volume or folder to analyze")
        title.font = .boldSystemFont(ofSize: 13)

        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 200), ("used", "Used", 160), ("total", "Total", 90), ("free", "Free", 90),
        ]
        for (id, label, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            if id == "total" || id == "free" { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.rowHeight = 26
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(analyzeSelection)
        if !volumes.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let home = NSButton(title: "Home Folder", target: self, action: #selector(analyzeHome))
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let analyze = NSButton(title: "Analyze", target: self, action: #selector(analyzeSelection))
        analyze.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [home, choose, spacer, cancel, analyze])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        panel.contentView = content
    }

    @objc private func analyzeSelection() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        finish(volumes[row].url)
    }

    @objc private func analyzeHome() {
        finish(FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Analyze"
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            self?.finish(url)
        }
    }

    @objc private func cancel() {
        finish(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { volumes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let volume = volumes[row]
        if id == "used" {
            let cell = PercentCell(identifier: NSUserInterfaceItemIdentifier("used"))
            cell.fraction = volume.total > 0 ? Double(volume.total - volume.free) / Double(volume.total) : 0
            return cell
        }
        let cell = TextCell(identifier: NSUserInterfaceItemIdentifier(id),
                            alignment: id == "name" ? .left : .right, withImage: id == "name")
        switch id {
        case "name":
            cell.imageView?.image = volume.icon
            cell.textField?.stringValue = volume.url.path == "/" ? volume.name : "\(volume.name)  (\(volume.url.path))"
        case "total":
            cell.textField?.stringValue = Format.bytes(volume.total)
        default:
            cell.textField?.stringValue = Format.bytes(volume.free)
        }
        return cell
    }
}
