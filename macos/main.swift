// AI Council — app nativa macOS.
// Avvia il motore Node incluso nel bundle e ne mostra l'interfaccia in una finestra nativa.

import AppKit
import Combine
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    private var window: NSWindow!
    private var split: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var observers: Set<AnyCancellable> = []
    private var helpWindow: NSWindow?
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
        sidebar.onExport = { [weak self] id in self?.exportDiscussion(id) }
        sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SidebarView(model: sidebar)))
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 480

        split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "MainSplit"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Nuova discussione"
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = split
        // Toolbar unificata: i pulsanti fluttuano su Liquid Glass sopra il contenuto.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Impostazioni non è di default (HIG): si può aggiungere da Vista ▸ Personalizza la barra strumenti.
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)

        // Titolo = domanda, sottotitolo = meta; si aggiornano con la discussione mostrata.
        Publishers.CombineLatest(store.$current, store.$parent)
            .receive(on: RunLoop.main)
            .sink { [weak self] d, p in self?.updateTitle(d, parent: p) }
            .store(in: &observers)
    }

    private static let titleDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    private func updateTitle(_ d: DebateState?, parent: ParentRef?) {
        guard let d else {
            window.title = "Nuova discussione"
            window.subtitle = parent.map { "Approfondimento di «\(Self.short($0.question, 40))»" } ?? ""
            updateToolbarItems(hasDebate: false)
            return
        }
        window.title = Self.short(d.question, 60)
        var parts: [String] = []
        if d.isRunning {
            let phase = d.phases.last?.title
            window.subtitle = phase.map { "In corso — \($0)" } ?? "In corso"
        } else {
            if let r = d.rounds { parts.append(r == 0 ? "senza round" : "\(r) round") }
            if !d.participants.isEmpty { parts.append("\(d.participants.count) modelli") }
            if let s = d.startedAt { parts.append(Self.titleDate.string(from: s)) }
            if d.status != "done" { parts.append(CouncilStore.statusText(d.status)) }
            window.subtitle = parts.joined(separator: " · ")
        }
        updateToolbarItems(hasDebate: true)
    }

    private static func short(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    /// Le azioni del dibattito compaiono nella toolbar solo con una discussione aperta.
    private func updateToolbarItems(hasDebate: Bool) {
        for item in window.toolbar?.items ?? [] where item.itemIdentifier == Self.copyItem || item.itemIdentifier == Self.exportItem {
            item.isHidden = !hasDebate
        }
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
        let services = NSMenu(title: "Servizi")
        let servicesItem = NSMenuItem(title: "Servizi", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Nascondi AI Council", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Nascondi altre", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Mostra tutte", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Esci da AI Council", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = NSMenu(title: "Archivio")
        file.addItem(item("Nuova discussione", #selector(newDebate(_:)), "n"))
        file.addItem(.separator())
        file.addItem(withTitle: "Chiudi finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Modifica")
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Ripeti", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // ⌫ senza modificatori: la voce si disattiva quando si scrive in un campo di testo,
        // così il tasto torna al campo (vedi validateMenuItem).
        edit.addItem(item("Elimina", #selector(deleteDiscussion(_:)), "\u{8}", []))
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Trova")
        find.addItem(item("Cerca nelle discussioni", #selector(findDiscussions(_:)), "f"))
        let findItem = NSMenuItem(title: "Trova", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)

        let view = NSMenu(title: "Vista")
        // L'etichetta diventa "Mostra…" o "Nascondi…" in validateMenuItem.
        view.addItem(item("Nascondi barra laterale", #selector(toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(withTitle: "Personalizza la barra strumenti…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(item("Ricarica", #selector(reload(_:)), "r"))
        view.addItem(.separator())
        view.addItem(withTitle: "Modalità a tutto schermo", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // Menu dell'app: comandi della discussione (disattivati quando non applicabili).
        let debate = NSMenu(title: "Discussione")
        debate.addItem(item("Avvia", #selector(startDebate(_:)), "\r"))
        debate.addItem(item("Interrompi", #selector(stopDebate(_:)), "."))
        debate.addItem(.separator())
        debate.addItem(item("Copia verdetto", #selector(copyVerdict(_:)), "c", [.command, .shift]))
        debate.addItem(item("Esporta come Markdown…", #selector(exportDebate(_:)), "e", [.command, .shift]))
        debate.addItem(item("Approfondisci…", #selector(deepenDebate(_:)), "d"))

        let win = NSMenu(title: "Finestra")
        win.addItem(withTitle: "Contrai", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: "Porta tutto in primo piano", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        let help = NSMenu(title: "Aiuto")
        help.addItem(item("Aiuto di AI Council", #selector(showHelp(_:)), "?"))
        help.addItem(.separator())
        help.addItem(item("Mostra registro del motore", #selector(openLog(_:)), ""))
        NSApp.helpMenu = help

        for (title, menu) in [("AI Council", app), ("Archivio", file), ("Modifica", edit), ("Vista", view),
                              ("Discussione", debate), ("Finestra", win), ("Aiuto", help)] {
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
        split.toggleSidebar(sender)
    }

    /// Porta in vista la barra laterale se è nascosta (serve a ricerca ed eliminazione).
    private func revealSidebar() {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    @objc func findDiscussions(_ sender: Any?) {
        revealSidebar()
        window.makeKeyAndOrderFront(nil)
        sidebar.focusSearch()
    }

    @objc func deleteDiscussion(_ sender: Any?) {
        revealSidebar()
        sidebar.requestDelete()
    }

    @objc func startDebate(_ sender: Any?) {
        Task { await store.start() }
    }

    @objc func stopDebate(_ sender: Any?) {
        Task { await store.cancel() }
    }

    @objc func copyVerdict(_ sender: Any?) {
        guard let v = store.current?.verdict else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    @objc func deepenDebate(_ sender: Any?) {
        sidebar.selected = nil
        store.deepen()
    }

    /// Esporta una discussione della cronologia: se non è quella mostrata la apre prima.
    private func exportDiscussion(_ id: Int) {
        if store.current?.id == id { exportDebate(nil); return }
        Task {
            await store.open(id)
            exportDebate(nil)
        }
    }

    /// true se il fuoco è nella barra laterale (⌫ elimina solo da lì, mai dal testo del dibattito).
    private var focusInSidebar: Bool {
        guard let v = window.firstResponder as? NSView, !(v is NSText) else { return false }
        return v.isDescendant(of: sidebarItem.viewController.view)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let d = store.current
        switch menuItem.action {
        case #selector(toggleSidebar(_:)):
            menuItem.title = sidebarItem.isCollapsed ? "Mostra barra laterale" : "Nascondi barra laterale"
            return true
        case #selector(deleteDiscussion(_:)):
            return NSApp.keyWindow === window && focusInSidebar && sidebar.selected != nil
        case #selector(findDiscussions(_:)):
            return NSApp.keyWindow === window && store.engineReady
        case #selector(startDebate(_:)):
            return NSApp.keyWindow === window && d == nil && store.canStart
        case #selector(stopDebate(_:)):
            return NSApp.keyWindow === window && d?.isRunning == true
        case #selector(copyVerdict(_:)), #selector(exportDebate(_:)):
            return d?.verdict != nil
        case #selector(deepenDebate(_:)):
            return d != nil && d?.isRunning == false
        default:
            return true
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.copyItem, Self.exportItem: return store.current?.verdict != nil
        default: return true
        }
    }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("newDebate")
    private static let settingsItem = NSToolbarItem.Identifier("settings")
    private static let copyItem = NSToolbarItem.Identifier("copyVerdict")
    private static let exportItem = NSToolbarItem.Identifier("export")

    // Due gruppi a destra: azioni della discussione, spazio fisso, "Nuova discussione".
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.copyItem, Self.exportItem, .space, Self.newItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
         Self.copyItem, Self.exportItem, Self.newItem, Self.settingsItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        // Pulsanti con testo: etichette sempre visibili (richiesta dell'utente, ammessa dalle HIG).
        switch id {
        case Self.newItem:
            item.label = "Nuova discussione"
            item.title = "Nuova discussione"
            item.toolTip = "Inizia una nuova discussione (⌘N)"
            item.isBordered = true
            item.action = #selector(newDebate(_:))
        case Self.copyItem:
            item.label = "Copia verdetto"
            item.title = "Copia verdetto"
            item.toolTip = "Copia il verdetto negli appunti (⇧⌘C)"
            item.isBordered = true
            item.action = #selector(copyVerdict(_:))
            item.isHidden = store.current == nil
        case Self.exportItem:
            item.label = "Esporta…"
            item.paletteLabel = "Esporta come Markdown"
            item.title = "Esporta…"
            item.toolTip = "Esporta la discussione come Markdown (⇧⌘E)"
            item.isBordered = true
            item.action = #selector(exportDebate(_:))
            item.isHidden = store.current == nil
        case Self.settingsItem:
            item.label = "Impostazioni"
            item.title = "Impostazioni"
            item.isBordered = true
            item.toolTip = "Impostazioni e chiavi API (⌘,)"
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

    @objc func openLog(_ sender: Any?) { NSWorkspace.shared.open(Paths.logFile) }

    /// Aiuto essenziale in una finestra nativa (l'app non ha un Help Book).
    @objc func showHelp(_ sender: Any?) {
        if let w = helpWindow { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Aiuto di AI Council"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HelpView())
        w.center()
        helpWindow = w
        w.makeKeyAndOrderFront(nil)
    }

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

// MARK: - Aiuto

struct HelpView: View {
    private let topics: [(String, String)] = [
        ("Come funziona", "Più modelli rispondono alla stessa domanda, si criticano a vicenda per il numero di round scelto e rivedono la propria posizione. Alla fine il giudice scrive il verdetto."),
        ("Avviare una discussione", "Scrivi la domanda, scegli almeno due partecipanti, i round e il giudice, poi premi Avvia (⌘↩)."),
        ("Chiavi API", "Claude funziona se hai Claude Code con un abbonamento Claude. Per gli altri modelli aggiungi una chiave gratuita di Gemini, Groq o OpenRouter in Impostazioni (⌘,)."),
        ("Cronologia", "Le discussioni restano nella barra laterale. Cerca con ⌘F, elimina con ⌫ o con il clic destro."),
        ("Se qualcosa non va", "Usa AI Council ▸ Riavvia motore (⇧⌘R) oppure Aiuto ▸ Mostra registro del motore."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topics, id: \.0) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.0).font(.headline)
                        Text(t.1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
