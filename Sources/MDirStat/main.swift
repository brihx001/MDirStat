import AppKit

/// Ne pas telecharger les fichiers iCloud « sans donnees » en les parcourant :
/// readdir sur un dossier non materialise echoue au lieu de le rapatrier.
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

        // Pour les verifications : MDIRSTAT_SNAPSHOT=/chemin.png ecrit l'image de la
        // fenetre une fois le treemap affiche, puis quitte.
        if let snapshot = ProcessInfo.processInfo.environment["MDIRSTAT_SNAPSHOT"] {
            controller.onScanDisplayed = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.controller.snapshot(to: snapshot)
                    NSApp.terminate(nil)
                }
            }
        }

        // Un dossier passe en argument (ou ouvert depuis le Finder) est analyse tout de suite.
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
                    exit(0)   // terminate est ignore tant qu'une feuille est ouverte
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
        let credits = NSMutableAttributedString(
            string: "Disk usage analyzer with a cushion treemap.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/brihx001",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                       .link: URL(string: "https://github.com/brihx001")!]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
