// Conclave — app nativa macOS.
// Avvia il motore Node incluso nel bundle e ne mostra l'interfaccia in una finestra nativa.

import AppKit
import Combine
import Security
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Percorsi

enum Paths {
    static let dataDir: URL = {
        // COUNCIL_DATA (solo sviluppo e prove): cartella dati alternativa, mai quella reale.
        if let custom = ProcessInfo.processInfo.environment["COUNCIL_DATA"], !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Conclave", isDirectory: true)
        // Se il passaggio dal vecchio nome non è riuscito a spostarla, si resta sulla cartella vecchia.
        let legacy = base.appendingPathComponent("AI Council", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) { dir = legacy }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()
    static let envFile = dataDir.appendingPathComponent(".env")
    static let logFile = dataDir.appendingPathComponent("server.log")
    static let serverDir = Bundle.main.resourceURL!.appendingPathComponent("server", isDirectory: true)

    /// Chiavi, cronologia e log leggibili solo dall'utente: cartelle 0700, file 0600.
    /// Il motore crea i file nuovi già così; qui si sistemano quelli delle versioni precedenti.
    /// Solo i file noti: con `COUNCIL_DATA` la cartella potrebbe contenere altro.
    static func secure() {
        let fm = FileManager.default
        let set = { (url: URL, mode: Int) in try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        set(dataDir, 0o700)
        for name in [".env", "selection.json", "health.json", "server.log"] { set(dataDir.appendingPathComponent(name), 0o600) }
        let db = dataDir.appendingPathComponent("data", isDirectory: true)
        set(db, 0o700)
        for name in (try? fm.contentsOfDirectory(atPath: db.path)) ?? [] where name.hasPrefix("council.db") {
            set(db.appendingPathComponent(name), 0o600)
        }
    }
}

// MARK: - Accesso al motore

enum Engine {
    /// Segreto di questa sessione dell'app, mandato al motore sullo stdin (mai nell'ambiente):
    /// senza, il motore risponde 401 a qualunque altro processo o pagina web.
    static let token: String = {
        // Solo nelle prove (cartella dati alternativa): token scelto da chi lancia l'app, per
        // poter avviare un dibattito via API e guardarlo nell'interfaccia.
        let env = ProcessInfo.processInfo.environment
        if !(env["COUNCIL_DATA"] ?? "").isEmpty, let t = env["COUNCIL_TEST_TOKEN"], t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Generatore casuale di sistema non disponibile")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Richiesta al motore già autenticata.
    static func request(_ url: URL, timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func url(_ port: Int, _ path: String) -> URL? {
        port > 0 ? URL(string: "http://127.0.0.1:\(port)\(path)") : nil
    }

    /// Chiamata all'API del motore. Una risposta ≥ 400 diventa un errore con il messaggio del motore.
    static func call(_ port: Int, _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 60) async throws -> Data {
        guard let u = url(port, path) else { throw URLError(.cannotConnectToHost) }
        var req = request(u, timeout: timeout)
        req.httpMethod = method
        // Il motore accetta le richieste che cambiano stato solo come JSON, anche senza corpo.
        if method != "GET" { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "council", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg ?? String(format: L("errore %d"), h.statusCode)])
        }
        return data
    }
}

// MARK: - Passaggio dal vecchio nome

/// Una sola volta, prima di tutto: l'app si chiamava "AI Council" (bundle id `local.peppe.aicouncil`).
/// Porta le preferenze dal vecchio dominio e sposta la cartella dati con chiavi e cronologia.
enum LegacyMigration {
    private static let doneKey = "migratedFromAICouncil"

    static func run() {
        let d = UserDefaults.standard
        if !d.bool(forKey: doneKey) {
            // Solo le chiavi assenti nel dominio nuovo (non `object(forKey:)`, che guarda anche i globali).
            let current = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
            for (k, v) in d.persistentDomain(forName: "local.peppe.aicouncil") ?? [:] where current[k] == nil {
                d.set(v, forKey: k)
            }
            d.set(true, forKey: doneKey)
        }
        // La cartella si sposta finché serve (se non riesce, `Paths` intanto usa quella vecchia).
        guard (ProcessInfo.processInfo.environment["COUNCIL_DATA"] ?? "").isEmpty else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("AI Council", isDirectory: true)
        let new = base.appendingPathComponent("Conclave", isDirectory: true)
        // Mai sotto i piedi della vecchia app ancora aperta: il suo motore scrive in quella cartella.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.peppe.aicouncil").isEmpty else { return }
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
    }
}

// MARK: - Motore Node

final class ServerController {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var log: FileHandle?
    private var buffer = ""
    private var stopping = false
    private var output: Pipe?
    /// Porta già letta: il resto dell'output va solo nel registro.
    private var portFound = false
    /// Cambia a ogni start/stop: un avvio ancora in preparazione (lettura del PATH) superato da
    /// un riavvio non deve lanciare un secondo motore.
    private var generation = 0

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
        portFound = false
        generation += 1
        let generation = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let path = Self.loginPath()
            // Le versioni scaricate (DMG) includono Node 24 in Contents/MacOS; in sviluppo si usa quello del PATH.
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/node").path
            let node = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : Self.find("node", in: path)
            guard let node else {
                DispatchQueue.main.async { self.onCrash?(L("Node.js non trovato. Installalo (es. con nvm) e riapri l'app.")) }
                return
            }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.launch(node: node, path: path)
            }
        }
    }

    private func launch(node: String, path: String) {
        FileManager.default.createFile(atPath: Paths.logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
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
        self.output = output
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
                self.onCrash?(String(format: L("Il motore si è fermato inaspettatamente.\n\n%@"), tail))
            }
        }

        do {
            try p.run()
            process = p
            // Prima riga dello stdin: il token dell'API e le chiavi dei provider dal Portachiavi
            // (vedi src/bootstrap.ts), mai nell'ambiente: altri processi lo leggerebbero. Poi lo
            // stdin resta aperto: quando l'app si chiude, il motore lo vede chiudersi e termina.
            let hello = try JSONSerialization.data(withJSONObject: ["token": Engine.token, "keys": KeyStore.engineKeys()])
            try input.fileHandleForWriting.write(contentsOf: hello + Data("\n".utf8))
        } catch {
            onCrash?(String(format: L("Impossibile avviare il motore: %@"), error.localizedDescription))
        }
    }

    private func consume(_ text: String) {
        guard !portFound else { return }
        buffer += text
        // Si attende il fine riga: un blocco letto dalla pipe può troncare il numero a metà.
        guard let range = buffer.range(of: #"COUNCIL_PORT=(\d+)\n"#, options: .regularExpression) else { return }
        let port = Int(buffer[range].split(separator: "=")[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        buffer = ""
        portFound = true
        if port > 0 { onReady?(port) }
    }

    func stop() {
        stopping = true
        generation += 1
        // Niente più scritture nel registro dopo la sua chiusura.
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        try? log?.close()
    }
}

// MARK: - Finestra

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSMenuDelegate {
    private var window: NSWindow!
    /// Icona nella barra dei menu (facoltativa, Impostazioni ▸ Generale).
    private var statusItem: NSStatusItem?
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
    /// Impostazioni salvate durante un dibattito: il motore si riavvia quando finisce.
    private var restartPending = false
    /// Verdetti arrivati mentre l'app era in secondo piano (badge del Dock).
    private var unreadVerdicts = 0
    /// nil = autorizzazione alle notifiche non ancora chiesta in questa sessione.
    private var notificationsAllowed: Bool?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Una sola finestra principale: niente voci "Mostra la barra dei pannelli" nel menu Vista.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.secure()
        // Prima del motore e delle Impostazioni: le chiavi rimaste nel .env passano al Portachiavi.
        KeyStore.migrateEnvFile()
        _ = AppLanguage.launched
        // Tema salvato (Sistema / Chiaro / Scuro) prima di creare la finestra.
        AppAppearance.apply()
        buildMenu()
        buildWindow()
        settings.model.onSaved = { [weak self] in self?.settingsSaved() }
        settings.models.onSaved = { [weak self] in self?.settingsSaved() }
        // Primo avvio senza chiavi: apre subito le impostazioni con la guida.
        if !settings.hasAnyKey { settings.show() }

        server.onReady = { [weak self] port in
            guard let self else { return }
            self.port = port
            self.engineReady()
        }
        server.onCrash = { [weak self] message in self?.showCrash(message) }
        server.start()
        Task { await UpdateCheck.run(manual: false, over: window) }
        updateStatusItem()
        NotificationCenter.default.addObserver(forName: MenuBarPreference.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Con l'icona nella barra dei menu l'app resta attiva anche a finestra chiusa.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarPreference.enabled }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Anche con Impostazioni o Aiuto aperti il clic sul Dock riporta la finestra principale.
        if !window.isVisible { showMainWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    func applicationDidBecomeActive(_ notification: Notification) {
        unreadVerdicts = 0
        NSApp.dockTile.badgeLabel = nil
    }

    private func buildWindow() {
        // Contenuto della finestra interamente nativo (SwiftUI).
        let root = ContentRoot(
            store: store,
            openSettings: { [weak self] in self?.openSettings(nil) },
            openModels: { [weak self] in self?.settings.show(tab: .models) },
            saveFile: { [weak self] name, text in self?.saveMarkdown(filename: name, text: text) })
        content = NSHostingView(rootView: root)
        content.isHidden = true
        store.onHistoryChanged = { [weak self] in
            self?.sidebar.reload()
            // Dopo l'evento in corso: lo stato "in corso" si aggiorna subito dopo questa chiamata.
            DispatchQueue.main.async { self?.restartIfPending() }
        }
        store.onCurrentChanged = { [weak self] id in self?.sidebar.selected = id }
        store.onVerdictReady = { [weak self] q in
            self?.verdictReady(title: L("Verdetto pronto"), body: q.count > 80 ? String(q.prefix(80)) + "…" : q)
        }

        status = NSTextField(labelWithString: L("Avvio del consiglio…"))
        status.textColor = .secondaryLabelColor
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, status])
        stack.orientation = .vertical
        stack.spacing = 12
        loading = stack

        // Area del contenuto: i controlli restano nella safe area sotto la toolbar, il vetro resta alla navigazione.
        let container = NSView()
        for v in [content!, loading!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        let safe = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            // Il contenuto parte sotto la toolbar: il testo che scorre non finisce sotto il titolo;
            // la toolbar mostra lo sfondo della finestra (Brand.canvas), dello stesso colore.
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
        sidebar.onDeleted = { [weak self] id in
            self?.store.deleted(id)
            // Era il dibattito che teneva in sospeso il riavvio per le nuove impostazioni.
            self?.restartIfPending()
        }
        sidebar.onExport = { [weak self] id in self?.exportDiscussion(id) }
        sidebar.onNew = { [weak self] in self?.newDebate(nil) }
        sidebar.onSettings = { [weak self] in self?.openSettings(nil) }
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
        window.title = L("Nuova discussione")
        // La domanda è già il titolo della pagina: nella toolbar non si ripete (resta per il menu Finestra).
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        // Sfondo coerente con il marchio (si vede durante l'avvio e dietro la toolbar);
        // la barra laterale resta il vetro di sistema.
        window.backgroundColor = NSColor(Brand.canvas)
        // Sfondo di marchio sotto tutta la finestra: si vede anche dietro e intorno alla barra
        // laterale (vetro di sistema), senza stacchi tra barra e contenuto.
        let windowRoot = NSViewController()
        windowRoot.view = NSView()
        let backdrop = NSHostingView(rootView: BrandBackground())
        windowRoot.addChild(split)
        for v in [backdrop, split.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            windowRoot.view.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: windowRoot.view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: windowRoot.view.trailingAnchor),
                v.topAnchor.constraint(equalTo: windowRoot.view.topAnchor),
                v.bottomAnchor.constraint(equalTo: windowRoot.view.bottomAnchor),
            ])
        }
        window.contentViewController = windowRoot
        // Toolbar unificata: i pulsanti fluttuano su Liquid Glass sopra il contenuto.
        // Identificatore nuovo quando cambia la disposizione predefinita: quella salvata non vale più.
        let toolbar = NSToolbar(identifier: "MainToolbar2")
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
        store.$current
            .receive(on: RunLoop.main)
            .sink { [weak self] d in self?.updateTitle(d) }
            .store(in: &observers)
    }

    // MARK: Barra dei menu

    private func updateStatusItem() {
        guard MenuBarPreference.enabled else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        s.button?.image = Self.menuBarImage
        s.button?.setAccessibilityLabel("Conclave")
        s.button?.toolTip = "Conclave"
        let menu = NSMenu()
        menu.delegate = self
        s.menu = menu
        statusItem = s
    }

    /// Logo del consiglio in versione monocroma (template): segue chiaro/scuro della barra.
    private static let menuBarImage: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { r in
            let u = r.width / 1024
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let lines = NSBezierPath()
            lines.lineWidth = 60 * u
            lines.lineCapStyle = .round
            lines.move(to: NSPoint(x: 512 * u, y: 390 * u)); lines.line(to: NSPoint(x: 350 * u, y: 610 * u))
            lines.move(to: NSPoint(x: 512 * u, y: 390 * u)); lines.line(to: NSPoint(x: 674 * u, y: 610 * u))
            lines.move(to: NSPoint(x: 380 * u, y: 660 * u)); lines.line(to: NSPoint(x: 644 * u, y: 660 * u))
            lines.stroke()
            for (x, y) in [(512.0, 300.0), (290, 690), (734, 690)] {
                let rad = 150 * u
                NSBezierPath(ovalIn: NSRect(x: x * u - rad, y: y * u - rad, width: rad * 2, height: rad * 2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// Il menu dell'icona si ricostruisce a ogni apertura: le discussioni recenti sono sempre aggiornate.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(item(L("Nuova discussione"), #selector(newDebateFromMenuBar(_:)), ""))
        menu.addItem(item(L("Mostra Conclave"), #selector(showMainWindow(_:)), ""))
        // Con una ricerca attiva la lista della barra laterale è filtrata: niente recenti parziali.
        let recent = sidebar.query.trimmingCharacters(in: .whitespaces).isEmpty ? sidebar.items.prefix(5) : []
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: L("Recenti"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for d in recent {
                let i = item(Self.short(d.displayTitle, 48), #selector(openRecent(_:)), "")
                i.tag = d.id
                i.toolTip = d.question
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item(L("Impostazioni…"), #selector(openSettings(_:)), ""))
        let quit = NSMenuItem(title: L("Esci da Conclave"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    @objc func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func newDebateFromMenuBar(_ sender: Any?) {
        showMainWindow(nil)
        newDebate(nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        showMainWindow(nil)
        sidebar.selected = sender.tag
        Task { await store.open(sender.tag) }
    }

    private static let titleDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    private func updateTitle(_ d: DebateState?) {
        guard let d else {
            window.title = L("Nuova discussione")
            window.subtitle = ""
            updateToolbarItems(hasDebate: false)
            return
        }
        window.title = d.displayTitle
        var parts: [String] = []
        if d.isRunning {
            let phase = d.phases.last?.title
            window.subtitle = phase.map { String(format: L("In corso — %@"), $0) } ?? L("In corso")
        } else if d.busy {
            window.subtitle = String(format: L("In corso — %@"), L("domanda di seguito"))
        } else {
            if let r = d.rounds { parts.append(r == 0 ? L("senza round") : (r == 1 ? L("1 round") : String(format: L("%d round"), r))) }
            if !d.participants.isEmpty { parts.append(String(format: L("%d modelli"), d.participants.count)) }
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
        status.stringValue = L("Motore non attivo")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Conclave non riesce a funzionare")
        alert.informativeText = message
        alert.addButton(withTitle: L("Riprova"))
        alert.addButton(withTitle: L("Esci"))
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.restartServer(nil) } else { NSApp.terminate(nil) }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("Informazioni su Conclave"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(item(L("Controlla aggiornamenti…"), #selector(checkForUpdates(_:)), ""))
        app.addItem(.separator())
        app.addItem(item(L("Impostazioni…"), #selector(openSettings(_:)), ","))
        app.addItem(item(L("Apri cartella dati"), #selector(openDataFolder(_:)), ""))
        app.addItem(item(L("Riavvia motore"), #selector(restartServer(_:)), "r", [.command, .shift]))
        app.addItem(.separator())
        let services = NSMenu(title: L("Servizi"))
        let servicesItem = NSMenuItem(title: L("Servizi"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: L("Nascondi Conclave"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Nascondi altre"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Mostra tutte"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Esci da Conclave"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Nomi e posizioni delle voci come in Note e Mail (letti dai loro MainMenu.nib).
        let file = NSMenu(title: L("File"))
        file.addItem(item(L("Nuova discussione"), #selector(newDebate(_:)), "n"))
        file.addItem(.separator())
        file.addItem(withTitle: L("Chiudi"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        file.addItem(item(L("Esporta come Markdown…"), #selector(exportDebate(_:)), "e", [.command, .shift]))

        let edit = NSMenu(title: L("Modifica"))
        // "Annulla" è anche il pulsante Cancel: chiave distinta per l'inglese "Undo".
        edit.addItem(withTitle: NSLocalizedString("menu.undo", value: "Annulla", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Ripristina"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Taglia"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copia"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Incolla"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // ⌫ senza modificatori: la voce si disattiva quando si scrive in un campo di testo,
        // così il tasto torna al campo (vedi validateMenuItem).
        edit.addItem(item(L("Elimina"), #selector(deleteDiscussion(_:)), "\u{8}", []))
        edit.addItem(withTitle: L("Seleziona tutto"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: L("Trova"))
        find.addItem(item(L("Cerca nelle discussioni"), #selector(findDiscussions(_:)), "f"))
        let findItem = NSMenuItem(title: L("Trova"), action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)

        let view = NSMenu(title: L("Vista"))
        // L'etichetta diventa "Mostra…" o "Nascondi…" in validateMenuItem.
        view.addItem(item(L("Nascondi barra laterale"), #selector(toggleSidebar(_:)), "s", [.command, .control]))
        // AppKit cambia da solo l'etichetta in "Mostra…" quando la barra è nascosta.
        view.addItem(withTitle: L("Nascondi barra strumenti"), action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: L("Personalizza la barra strumenti…"), action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        view.addItem(.separator())
        // Testo di risposte e verdetto.
        view.addItem(item(L("Ingrandisci"), #selector(zoomTextIn(_:)), "+"))
        view.addItem(item(L("Riduci"), #selector(zoomTextOut(_:)), "-"))
        view.addItem(item(L("Dimensioni reali"), #selector(zoomTextReset(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item(L("Ricarica"), #selector(reload(_:)), "r"))
        view.addItem(.separator())
        view.addItem(withTitle: L("Attiva modalità a tutto schermo"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // Menu dell'app: comandi della discussione (disattivati quando non applicabili).
        let debate = NSMenu(title: L("Discussione"))
        debate.addItem(item(L("Avvia"), #selector(startDebate(_:)), "\r"))
        debate.addItem(item(L("Interrompi"), #selector(stopDebate(_:)), "."))
        debate.addItem(.separator())
        debate.addItem(item(L("Copia verdetto"), #selector(copyVerdict(_:)), "c", [.command, .shift]))

        let win = NSMenu(title: L("Finestra"))
        win.addItem(withTitle: L("Contrai"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: L("Ridimensiona"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: L("Porta tutto in primo piano"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win

        let help = NSMenu(title: L("Aiuto"))
        help.addItem(item(L("Aiuto di Conclave"), #selector(showHelp(_:)), "?"))
        help.addItem(.separator())
        help.addItem(item(L("Mostra registro del motore"), #selector(openLog(_:)), ""))
        NSApp.helpMenu = help

        for (title, menu) in [("Conclave", app), (L("File"), file), (L("Modifica"), edit), (L("Vista"), view),
                              (L("Discussione"), debate), (L("Finestra"), win), (L("Aiuto"), help)] {
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
        if !window.isVisible { showMainWindow(nil) }
        sidebar.selected = nil
        store.newDiscussion()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Task { await UpdateCheck.run(manual: true, over: window) }
    }

    @objc func zoomTextIn(_ sender: Any?) { TextZoom.step(1) }
    @objc func zoomTextOut(_ sender: Any?) { TextZoom.step(-1) }
    @objc func zoomTextReset(_ sender: Any?) { TextZoom.reset() }

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
        if window.toolbar?.isVisible == false { window.toggleToolbarShown(nil) }
        sidebar.focusSearch()
    }

    @objc func deleteDiscussion(_ sender: Any?) {
        revealSidebar()
        sidebar.requestDelete()
    }

    /// ⌘↩: avvia il dibattito dal composer o invia la domanda di seguito nella discussione aperta.
    @objc func startDebate(_ sender: Any?) {
        Task {
            if store.current == nil { await store.start() } else { await store.sendFollowup() }
        }
    }

    @objc func stopDebate(_ sender: Any?) {
        Task { await store.cancel() }
    }

    @objc func copyVerdict(_ sender: Any?) {
        guard let v = store.current?.verdict else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    /// Esporta una discussione della cronologia: se non è quella mostrata la apre prima.
    private func exportDiscussion(_ id: Int) {
        if store.current?.id == id { exportDebate(nil); return }
        Task {
            await store.open(id)
            // Apertura non riuscita o superata da un altro clic: mai esportare un'altra discussione.
            guard store.current?.id == id else { NSSound.beep(); return }
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
            menuItem.title = sidebarItem.isCollapsed ? L("Mostra barra laterale") : L("Nascondi barra laterale")
            return true
        case #selector(deleteDiscussion(_:)):
            return NSApp.keyWindow === window && focusInSidebar && sidebar.selected != nil
        case #selector(findDiscussions(_:)):
            return NSApp.keyWindow === window && store.engineReady
        case #selector(startDebate(_:)):
            return NSApp.keyWindow === window && (d == nil ? store.canStart : store.canSendFollowup)
        case #selector(stopDebate(_:)):
            return NSApp.keyWindow === window && d?.busy == true
        case #selector(copyVerdict(_:)), #selector(exportDebate(_:)):
            return d?.verdict != nil
        case #selector(zoomTextIn(_:)):
            return TextZoom.canGrow
        case #selector(zoomTextOut(_:)):
            return TextZoom.canShrink
        case #selector(zoomTextReset(_:)):
            return !TextZoom.isDefault
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

    func toolbarDidRemoveItem(_ notification: Notification) {
        if let item = notification.userInfo?["item"] as? NSToolbarItem, item.itemIdentifier == Self.searchItem { sidebar.detachSearch(item) }
    }

    private static let searchItem = NSToolbarItem.Identifier("searchDebates")
    private static let newItem = NSToolbarItem.Identifier("newDebate")
    private static let settingsItem = NSToolbarItem.Identifier("settings")
    private static let copyItem = NSToolbarItem.Identifier("copyVerdict")
    private static let exportItem = NSToolbarItem.Identifier("export")

    // A destra: azioni della discussione, spazio fisso, "Nuova discussione" e in fondo la ricerca
    // (come in Note e Mail: sopra la barra laterale non c'è posto per un campo intero).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.copyItem, Self.exportItem, .space, Self.newItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.searchItem, .sidebarTrackingSeparator, .flexibleSpace, .space,
         Self.copyItem, Self.exportItem, Self.newItem, Self.settingsItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Campo di ricerca di sistema: filtra la cronologia della barra laterale mentre si scrive.
        if id == Self.searchItem {
            let search = NSSearchToolbarItem(itemIdentifier: id)
            search.label = L("Cerca")
            search.paletteLabel = L("Cerca nelle discussioni")
            search.toolTip = L("Cerca nelle discussioni (⌘F)")
            if flag { sidebar.attach(search) }
            return search
        }
        let item = NSToolbarItem(itemIdentifier: id)
        // Pulsanti-icona con tooltip; label e paletteLabel per VoiceOver, menu di overflow e Personalizza.
        func symbol(_ name: String, _ description: String) {
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            item.isBordered = true
        }
        switch id {
        case Self.newItem:
            item.label = L("Nuova discussione")
            item.toolTip = L("Nuova discussione (⌘N)")
            symbol("square.and.pencil", L("Nuova discussione"))
            item.action = #selector(newDebate(_:))
        case Self.copyItem:
            item.label = L("Copia verdetto")
            item.toolTip = L("Copia il verdetto (⇧⌘C)")
            symbol("doc.on.doc", L("Copia verdetto"))
            item.action = #selector(copyVerdict(_:))
            item.isHidden = store.current == nil
        case Self.exportItem:
            item.label = L("Esporta")
            item.paletteLabel = L("Esporta come Markdown")
            item.toolTip = L("Esporta come Markdown (⇧⌘E)")
            symbol("square.and.arrow.up", L("Esporta come Markdown"))
            item.action = #selector(exportDebate(_:))
            item.isHidden = store.current == nil
        case Self.settingsItem:
            item.label = L("Impostazioni")
            item.toolTip = L("Impostazioni (⌘,)")
            symbol("gearshape", L("Impostazioni"))
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
        settings.show()
    }

    // MARK: Ponte: salvataggio e notifiche

    private func saveMarkdown(filename: String, text: String) {
        var name = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == ".md" { name = L("discussione") }
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
                alert.messageText = L("Impossibile salvare il file")
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
        w.title = L("Aiuto di Conclave")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HelpView())
        w.center()
        helpWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Le nuove impostazioni valgono dal riavvio del motore, che però interrompe i dibattiti in corso.
    private func settingsSaved() {
        guard store.hasRunning else { restartServer(nil); return }
        let alert = NSAlert()
        alert.messageText = L("Una discussione è in corso")
        alert.informativeText = L("Le nuove impostazioni valgono dal riavvio del motore, che interrompe la discussione in corso.")
        alert.addButton(withTitle: L("Applica al termine"))
        alert.addButton(withTitle: L("Riavvia ora"))
        if alert.runModal() == .alertSecondButtonReturn { restartServer(nil) } else { restartPending = true }
    }

    private func restartIfPending() {
        guard restartPending, !store.hasRunning else { return }
        restartServer(nil)
    }

    @objc func restartServer(_ sender: Any?) {
        restartPending = false
        content.isHidden = true
        store.engineStopped()
        loading.isHidden = false
        status.stringValue = L("Riavvio del motore…")
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
        settings.engineStarted()
        // La tastiera non deve finire nel campo di ricerca della barra laterale.
        window.makeFirstResponder(nil)
        if let id = store.current?.id { Task { await store.open(id) } }
    }
}

// MARK: - Aiuto

struct HelpView: View {
    private let topics: [(String, String)] = [
        (L("Come funziona"), L("Più modelli rispondono alla stessa domanda, si criticano a vicenda per il numero di round scelto e rivedono la propria posizione. Alla fine il giudice scrive il verdetto.")),
        (L("Avviare una discussione"), L("Scrivi la domanda, scegli almeno due partecipanti, i round e il giudice, poi premi Avvia (⌘↩).")),
        (L("Chiavi API"), L("Claude funziona se hai Claude Code con un abbonamento Claude. Per gli altri modelli aggiungi una chiave gratuita di Gemini, Groq o OpenRouter in Impostazioni (⌘,).")),
        (L("Cronologia"), L("Le discussioni restano nella barra laterale. Cerca con ⌘F, elimina con ⌫ o con il clic destro.")),
        (L("Se qualcosa non va"), L("Usa Conclave ▸ Riavvia motore (⇧⌘R) oppure Aiuto ▸ Mostra registro del motore.")),
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

// Scrivere sullo stdin di un motore già uscito deve dare un errore, non chiudere l'app.
signal(SIGPIPE, SIG_IGN)
LegacyMigration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
