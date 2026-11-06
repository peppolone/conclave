// AI Council — app nativa macOS.
// Avvia il motore Node incluso nel bundle e ne mostra l'interfaccia in una finestra nativa.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Percorsi

enum Paths {
    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AI Council", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let envFile = dataDir.appendingPathComponent(".env")
    static let logFile = dataDir.appendingPathComponent("server.log")
    static let serverDir = Bundle.main.resourceURL!.appendingPathComponent("server", isDirectory: true)
}

// MARK: - Motore Node

final class ServerController {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var log: FileHandle?
    private var buffer = ""
    private var stopping = false

    var onReady: ((Int) -> Void)?
    var onCrash: ((String) -> Void)?

    /// Le app avviate dal Finder non ereditano il PATH della shell (nvm, ~/.local/bin):
    /// lo si legge una volta dalla shell di login dell'utente.
    private static func loginPath() -> String {
        let home = NSHomeDirectory()
        var fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for v in versions.sorted(by: >) { fallback.insert("\(nvm.path)/\(v)/bin", at: 0) }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "echo __PATH__$PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate() }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__PATH__") }) {
                return String(line.dropFirst(8)) + ":" + fallback.joined(separator: ":")
            }
        } catch {}
        return fallback.joined(separator: ":")
    }

    private static func find(_ name: String, in path: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func start() {
        stopping = false
        buffer = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let path = Self.loginPath()
            guard let node = Self.find("node", in: path) else {
                DispatchQueue.main.async { self.onCrash?("Node.js non trovato. Installalo (es. con nvm) e riapri l'app.") }
                return
            }
            DispatchQueue.main.async { self.launch(node: node, path: path) }
        }
    }

    private func launch(node: String, path: String) {
        FileManager.default.createFile(atPath: Paths.logFile.path, contents: nil)
        log = try? FileHandle(forWritingTo: Paths.logFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["--disable-warning=ExperimentalWarning", Paths.serverDir.appendingPathComponent("src/server.ts").path]
        p.currentDirectoryURL = Paths.serverDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["PORT"] = "0"
        env["COUNCIL_DATA"] = Paths.dataDir.path
        env["COUNCIL_PARENT"] = "app"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        p.environment = env

        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        stdinPipe = input

        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.log?.write(data)
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.consume(text) }
        }
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                // Ignora la chiusura voluta (stop/riavvio) e quella di un processo ormai sostituito.
                guard let self, !self.stopping, self.process === ended else { return }
                let tail = (try? String(contentsOf: Paths.logFile, encoding: .utf8))?
                    .split(separator: "\n").suffix(8).joined(separator: "\n") ?? ""
                self.onCrash?("Il motore si è fermato inaspettatamente.\n\n\(tail)")
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            onCrash?("Impossibile avviare il motore: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        buffer += text
        // Si attende il fine riga: un blocco letto dalla pipe può troncare il numero a metà.
        guard let range = buffer.range(of: #"COUNCIL_PORT=(\d+)\n"#, options: .regularExpression) else { return }
        let port = Int(buffer[range].split(separator: "=")[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        buffer = ""
        if port > 0 { onReady?(port) }
    }

    func stop() {
        stopping = true
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        try? log?.close()
    }
}

// MARK: - Finestra

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var window: NSWindow!
    /// Contenuto nativo SwiftUI (composer e dibattito).
    private var content: NSView!
    private var loading: NSView!
    private var status: NSTextField!
    private let server = ServerController()
    private lazy var settings = SettingsWindowController(port: { [weak self] in self?.port ?? 0 })
    private lazy var sidebar = SidebarModel(port: { [weak self] in self?.port ?? 0 })
    private lazy var store = CouncilStore(port: { [weak self] in self?.port ?? 0 })
    private var port = 0
    /// Verdetti arrivati mentre l'app era in secondo piano (badge del Dock).
    private var unreadVerdicts = 0
    /// nil = autorizzazione alle notifiche non ancora chiesta in questa sessione.
    private var notificationsAllowed: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedSettings()
        buildMenu()
        buildWindow()
        settings.model.onSaved = { [weak self] in self?.restartServer(nil) }
        settings.models.onSaved = { [weak self] in self?.restartServer(nil) }
        // Primo avvio senza chiavi: apre subito le impostazioni con la guida.
        if !settings.hasAnyKey { settings.show() }

        server.onReady = { [weak self] port in
            guard let self else { return }
            self.port = port
            self.engineReady()
        }
        server.onCrash = { [weak self] message in self?.showCrash(message) }
        server.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    func applicationDidBecomeActive(_ notification: Notification) {
        unreadVerdicts = 0
        NSApp.dockTile.badgeLabel = nil
    }

    /// Al primo avvio crea il file delle chiavi partendo dal modello incluso.
    private func seedSettings() {
        guard !FileManager.default.fileExists(atPath: Paths.envFile.path) else { return }
        let example = Paths.serverDir.appendingPathComponent(".env.example")
        try? FileManager.default.copyItem(at: example, to: Paths.envFile)
    }

    private func buildWindow() {
        // Contenuto della finestra interamente nativo (SwiftUI).
        let root = ContentRoot(
            store: store,
            openSettings: { [weak self] in self?.openSettings(nil) },
            openModels: { [weak self] in self?.seedSettings(); self?.settings.show(tab: .models) },
            saveFile: { [weak self] name, text in self?.saveMarkdown(filename: name, text: text) })
        content = NSHostingView(rootView: root)
        content.isHidden = true
        store.onHistoryChanged = { [weak self] in self?.sidebar.reload() }
        store.onCurrentChanged = { [weak self] id in self?.sidebar.selected = id }
        store.onVerdictReady = { [weak self] q in
            self?.verdictReady(title: "Verdetto pronto", body: q.count > 80 ? String(q.prefix(80)) + "…" : q)
        }

        status = NSTextField(labelWithString: "Avvio del consiglio…")
        status.textColor = .secondaryLabelColor
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, status])
        stack.orientation = .vertical
        stack.spacing = 12
        loading = stack

        // Area del contenuto: la pagina parte sotto la toolbar (safe area), il vetro resta alla navigazione.
        let container = NSView()
        for v in [content!, loading!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        let safe = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            content.topAnchor.constraint(equalTo: safe.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            loading.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
        ])
        let contentVC = NSViewController()
        contentVC.view = container

        // Barra laterale nativa: su macOS 26 diventa automaticamente un pannello Liquid Glass.
        sidebar.onOpen = { [weak self] id in
            guard let self else { return }
            Task { await self.store.open(id) }
        }
        sidebar.onDeleted = { [weak self] id in self?.store.deleted(id) }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(model: sidebar)))
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 480

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "MainSplit"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "AI Council"
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = split
        // Toolbar unificata: i pulsanti fluttuano su Liquid Glass sopra il contenuto.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    private func showCrash(_ message: String) {
        content.isHidden = true
        store.engineStopped()
        loading.isHidden = false
        status.stringValue = "Motore non attivo"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AI Council non riesce a funzionare"
        alert.informativeText = message
        alert.addButton(withTitle: "Riprova")
        alert.addButton(withTitle: "Esci")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.restartServer(nil) } else { NSApp.terminate(nil) }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Informazioni su AI Council", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Impostazioni…", #selector(openSettings(_:)), ","))
        app.addItem(item("Apri cartella dati", #selector(openDataFolder(_:)), ""))
        app.addItem(item("Riavvia motore", #selector(restartServer(_:)), "r", [.command, .shift]))
        app.addItem(.separator())
        app.addItem(withTitle: "Nascondi AI Council", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Esci da AI Council", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "File")
        file.addItem(item("Nuova discussione", #selector(newDebate(_:)), "n"))
        file.addItem(item("Esporta discussione…", #selector(exportDebate(_:)), "e", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Chiudi finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Modifica")
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = NSMenu(title: "Vista")
        view.addItem(item("Mostra/nascondi barra laterale", #selector(toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Ricarica", #selector(reload(_:)), "r"))
        view.addItem(withTitle: "Modalità a tutto schermo", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let win = NSMenu(title: "Finestra")
        win.addItem(withTitle: "Contrai", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        for (title, menu) in [("AI Council", app), ("File", file), ("Modifica", edit), ("Vista", view), ("Finestra", win)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    @objc func newDebate(_ sender: Any?) {
        sidebar.selected = nil
        store.newDiscussion()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        (window.contentViewController as? NSSplitViewController)?.toggleSidebar(sender)
    }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("newDebate")
    private static let settingsItem = NSToolbarItem.Identifier("settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.newItem:
            item.label = "Nuova discussione"
            item.toolTip = "Nuova discussione (⌘N)"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Nuova discussione")
            item.action = #selector(newDebate(_:))
        case Self.settingsItem:
            item.label = "Impostazioni"
            item.toolTip = "Impostazioni e chiavi API (⌘,)"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Impostazioni")
            item.action = #selector(openSettings(_:))
        default:
            return nil
        }
        item.target = self
        return item
    }

    @objc func exportDebate(_ sender: Any?) {
        // Solo se c'è un verdetto da esportare.
        guard store.current?.verdict != nil, let e = store.exportMarkdown() else { NSSound.beep(); return }
        saveMarkdown(filename: e.filename, text: e.text)
    }

    @objc func reload(_ sender: Any?) {
        Task { await store.reloadModels() }
        sidebar.reload()
        if let id = store.current?.id { Task { await store.open(id) } }
    }

    @objc func openSettings(_ sender: Any?) {
        seedSettings()
        settings.show()
    }

    // MARK: Ponte: salvataggio e notifiche

    private func saveMarkdown(filename: String, text: String) {
        var name = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == ".md" { name = "discussione" }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Impossibile salvare il file"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: self.window)
            }
        }
    }

    private func verdictReady(title: String, body: String) {
        guard !NSApp.isActive else { return }
        unreadVerdicts += 1
        NSApp.dockTile.badgeLabel = String(unreadVerdicts)
        NSApp.requestUserAttention(.informationalRequest)
        postNotification(title: title, body: body)
    }

    /// Notifica di sistema "best effort": con la firma ad-hoc può non comparire; errori ignorati.
    private func postNotification(title: String, body: String) {
        // Senza bundle identifier UNUserNotificationCenter.current() solleva un'eccezione.
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            if self.notificationsAllowed == nil {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                self.notificationsAllowed = granted
            }
            guard self.notificationsAllowed == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    @objc func openDataFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.dataDir) }

    @objc func restartServer(_ sender: Any?) {
        content.isHidden = true
        store.engineStopped()
        loading.isHidden = false
        status.stringValue = "Riavvio del motore…"
        port = 0
        server.stop()
        server.start()
    }

    /// Motore pronto: si mostra il contenuto e si ricaricano modelli e cronologia.
    private func engineReady() {
        loading.isHidden = true
        content.isHidden = false
        store.engineStarted()
        sidebar.reload()
        // La tastiera non deve finire nel campo di ricerca della barra laterale.
        window.makeFirstResponder(nil)
        if let id = store.current?.id { Task { await store.open(id) } }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
