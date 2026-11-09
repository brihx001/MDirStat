import AppKit

/// Do not download dataless iCloud files while scanning: reading a folder that
/// is not materialized fails instead of fetching it.
private func disableDatalessMaterialization() {
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController!
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        disableDatalessMaterialization()
        NSApp.mainMenu = MainMenu.build()
        controller = MainWindowController()
        controller.showWindow(nil)

        // For automated checks: MDIRSTAT_SNAPSHOT=/path.png writes an image of the
        // window once the treemap is displayed, then quits.
        if let snapshot = ProcessInfo.processInfo.environment["MDIRSTAT_SNAPSHOT"] {
            controller.onScanDisplayed = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.controller.snapshot(to: snapshot)
                    NSApp.terminate(nil)
                }
            }
        }

        // A folder passed as an argument (or opened from the Finder) is scanned right away.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let url = pendingURL {
            controller.startScan(url: url)
        } else if let path = arguments.first {
            controller.startScan(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            controller.openDocument(nil)
            if let snapshot = ProcessInfo.processInfo.environment["MDIRSTAT_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.controller.snapshot(to: snapshot)
                    exit(0)   // terminate is ignored while a sheet is open
                }
            }
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let controller {
            controller.window?.attachedSheet.map { controller.window?.endSheet($0) }
            controller.startScan(url: url)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show()
    }
}

/// Standard About panel, completed with the author, the build date and time
/// (MDirStatBuildDate key, written by build.sh) and the project page.
enum AboutPanel {
    static let author = "brihx001"
    static let authorURL = URL(string: "https://github.com/brihx001")!
    static let projectURL = URL(string: "https://github.com/brihx001/MDirStat")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        func text(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: base)
        }
        func link(_ string: String, _ url: URL) -> NSAttributedString {
            var attributes = base
            attributes[.link] = url
            return NSAttributedString(string: string, attributes: attributes)
        }

        let credits = NSMutableAttributedString(attributedString: text("Disk usage analyzer with a cushion treemap.\nBy "))
        credits.append(link(author, authorURL))
        if let built = buildDate {
            credits.append(text("\nBuilt \(Format.dateTime(built))"))
        }
        credits.append(text("\n"))
        credits.append(link(projectURL.absoluteString.replacingOccurrences(of: "https://", with: ""), projectURL))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Build date and time, stored by build.sh as an ISO 8601 UTC string.
    private static var buildDate: Date? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MDirStatBuildDate") as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "MDirStat")
        app.addItem(withTitle: "About MDirStat", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MDirStat", action: #selector(NSApplication.hide), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit MDirStat", action: #selector(NSApplication.terminate), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "Open…", action: #selector(MainWindowController.openDocument), keyEquivalent: "o")
        file.addItem(withTitle: "Rescan", action: #selector(MainWindowController.rescan), keyEquivalent: "r")
        file.addItem(withTitle: "Refresh Selected", action: #selector(MainWindowController.refreshSelected), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Cancel Scan", action: #selector(MainWindowController.cancelScan), keyEquivalent: ".")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose), keyEquivalent: "w")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Copy Path", action: #selector(MainWindowController.copy(_:)), keyEquivalent: "c")

        let item = submenu(in: main, title: "Item")
        item.addItem(withTitle: "Open", action: #selector(MainWindowController.openItem), keyEquivalent: "\u{F701}")
        item.addItem(withTitle: "Reveal in Finder", action: #selector(MainWindowController.revealInFinder), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        item.addItem(withTitle: "Select Parent", action: #selector(MainWindowController.selectParent), keyEquivalent: "\u{F700}")
        item.addItem(.separator())
        item.addItem(withTitle: "Move to Trash", action: #selector(MainWindowController.moveToTrash), keyEquivalent: "\u{8}")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(MainWindowController.zoomIn), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(MainWindowController.zoomOut), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(MainWindowController.resetZoom), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "Show Free Space", action: #selector(MainWindowController.toggleFreeSpace), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Show Unknown", action: #selector(MainWindowController.toggleUnknown), keyEquivalent: "u")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Hide Treemap", action: #selector(MainWindowController.toggleTreemap), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Hide Extension List", action: #selector(MainWindowController.toggleExtensions), keyEquivalent: "e")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(in: main, title: "Help")
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        return submenu
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        NSApplication.shared.run()
    }
}
