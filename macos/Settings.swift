// Finestra Impostazioni: pannelli "Chiavi API" e "Modelli" in una toolbar di pannelli
// (NSTabViewController, stile .toolbar), come le Impostazioni delle app di sistema.

import AppKit
import SwiftUI

// MARK: - Guide dei provider

struct ProviderGuide: Identifiable {
    let id: String          // chiave in models.json → providers
    let name: String
    let free: Bool          // false: solo a pagamento
    let optional: Bool      // non serve per un consiglio gratuito completo
    let unlocks: String     // voci che sblocca
    let summary: String     // una riga: costo e condizioni
    let url: URL
    let steps: [String]
    let note: String        // dettagli (quote, privacy), dentro la guida
}

let providerGuides: [ProviderGuide] = [
    ProviderGuide(
        id: "gemini", name: "Google Gemini", free: true, optional: false,
        unlocks: "Voce Gemini (Flash, Flash Lite e Gemma come riserve)",
        summary: "Gratis, senza carta di credito.",
        url: URL(string: "https://aistudio.google.com/apikey")!,
        steps: [
            "Apri Google AI Studio e accedi con il tuo account Google (accetta i termini, se li chiede).",
            "Clicca “Create API key”; se lo chiede, scegli o crea un progetto.",
            "Copia la chiave (inizia con “AIza”) e incollala nel campo qui sopra.",
        ],
        note: "Quote gratuite basse: Gemini Flash circa 20 richieste al giorno (un dibattito ne usa 4), Flash Lite circa 500, Gemma circa 14.000. Finita una quota l'app passa da sola al modello successivo. Nel piano gratuito Google può usare i dati per migliorare i suoi modelli: non inserire informazioni riservate."),
    ProviderGuide(
        id: "groq", name: "Groq", free: true, optional: false,
        unlocks: "Voci GPT-OSS e Qwen",
        summary: "Gratis, senza carta di credito, molto veloce.",
        url: URL(string: "https://console.groq.com/keys")!,
        steps: [
            "Apri la console Groq e registrati (va bene anche l'account Google).",
            "In “API Keys” clicca “Create API Key” e dagli un nome, per esempio “AI Council”.",
            "Copia subito la chiave (inizia con “gsk_”, Groq la mostra una sola volta) e incollala qui sopra.",
        ],
        note: "Ha limiti al minuto: con molti modelli insieme l'app aspetta e riprova da sola."),
    ProviderGuide(
        id: "openrouter", name: "OpenRouter", free: true, optional: false,
        unlocks: "Modelli gratuiti “:free” (per esempio Nemotron e DeepSeek)",
        summary: "Gratis con i modelli “:free”, senza credito.",
        url: URL(string: "https://openrouter.ai/settings/keys")!,
        steps: [
            "Apri OpenRouter e registrati.",
            "In “Keys” clicca “Create Key”; come limite di credito lascia 0 per non spendere mai nulla.",
            "Copia la chiave (inizia con “sk-or-”) e incollala qui sopra.",
        ],
        note: "L'app usa solo i modelli gratuiti, quelli con “:free” nel nome. Senza credito le richieste al giorno sono poche e alcuni modelli sono lenti."),
    ProviderGuide(
        id: "mistral", name: "Mistral", free: true, optional: true,
        unlocks: "Voce Mistral Small",
        summary: "Gratis con limiti (piano “Experiment”).",
        url: URL(string: "https://console.mistral.ai/api-keys")!,
        steps: [
            "Apri la console Mistral e registrati.",
            "Scegli il piano gratuito “Experiment” (chiede di verificare il numero di telefono).",
            "In “API Keys” clicca “Create new key”, copia la chiave e incollala qui sopra.",
        ],
        note: "Utile come voce europea in più nel consiglio."),
    ProviderGuide(
        id: "cerebras", name: "Cerebras", free: true, optional: true,
        unlocks: "GPT-OSS, Qwen, Llama e altri modelli open, molto veloci",
        summary: "Gratis con limiti giornalieri.",
        url: URL(string: "https://cloud.cerebras.ai")!,
        steps: [
            "Apri Cerebras Cloud e registrati.",
            "In “API Keys” crea una nuova chiave e copiala (inizia con “csk-”).",
            "Incollala qui sopra, poi scegli i modelli nel pannello “Modelli”.",
        ],
        note: "Un'alternativa a Groq per gli stessi modelli open."),
    ProviderGuide(
        id: "openai", name: "OpenAI", free: false, optional: true,
        unlocks: "Modelli GPT ufficiali di OpenAI",
        summary: "Solo a pagamento: l'abbonamento ChatGPT non include le API.",
        url: URL(string: "https://platform.openai.com/api-keys")!,
        steps: [
            "Apri la piattaforma OpenAI e aggiungi credito in “Billing”.",
            "In “API keys” clicca “Create new secret key”.",
            "Copia la chiave (inizia con “sk-”) e incollala qui sopra.",
        ],
        note: "Per avere GPT gratis non serve questa chiave: GPT-OSS, il modello open di OpenAI, è disponibile gratis con Groq, Cerebras o OpenRouter."),
]

// MARK: - File .env

enum EnvFile {
    static func read() -> [String: String] {
        guard let text = try? String(contentsOf: Paths.envFile, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq])] = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return out
    }

    /// Aggiorna solo le variabili indicate, lasciando invariati commenti e altre righe.
    static func write(_ values: [String: String]) throws {
        var lines = ((try? String(contentsOf: Paths.envFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pending = values
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let k = String(t[..<eq])
            if let v = pending.removeValue(forKey: k) { lines[i] = "\(k)=\(v)" }
        }
        if lines.last == "" { lines.removeLast() }
        for (k, v) in pending.sorted(by: { $0.key < $1.key }) { lines.append("\(k)=\(v)") }
        try (lines.joined(separator: "\n") + "\n").write(to: Paths.envFile, atomically: true, encoding: .utf8)
        // Le chiavi sono personali: leggibili solo dall'utente.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.envFile.path)
    }
}

// MARK: - Stato

struct ProviderConfig { let baseUrl: String; let keyEnv: String }

enum TestState: Equatable {
    case idle, testing, ok(String), warn(String), fail(String)
}

/// Modello del consiglio servito da un provider (da models.json).
struct CouncilModel { let label: String; let model: String; let fallback: [String] }

@MainActor
final class SettingsModel: ObservableObject {
    @Published var keys: [String: String] = [:]     // per provider id
    @Published var tests: [String: TestState] = [:]
    @Published var dirty = false
    let providers: [String: ProviderConfig]
    var councilModels: [String: [CouncilModel]] = [:]   // per provider id
    var onSaved: (() -> Void)?

    init() {
        var p: [String: ProviderConfig] = [:]
        let file = Paths.serverDir.appendingPathComponent("models.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // [String: Any]: un provider può avere campi non testuali (es. extraBody).
            for (id, v) in json["providers"] as? [String: [String: Any]] ?? [:] {
                if let b = v["baseUrl"] as? String, let k = v["keyEnv"] as? String { p[id] = ProviderConfig(baseUrl: b, keyEnv: k) }
            }
        }
        providers = p
        reload()
    }

    /// Modelli del consiglio: la scelta dell'utente (selection.json) o l'elenco predefinito.
    private func loadCouncilModels() {
        let userFile = Paths.dataDir.appendingPathComponent("selection.json")
        let bundled = Paths.serverDir.appendingPathComponent("models.json")
        var cm: [String: [CouncilModel]] = [:]
        for file in [userFile, bundled] {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]], !models.isEmpty else { continue }
            for m in models {
                if let prov = m["provider"] as? String, let label = m["label"] as? String, let model = m["model"] as? String {
                    cm[prov, default: []].append(CouncilModel(label: label, model: model, fallback: m["fallback"] as? [String] ?? []))
                }
            }
            break
        }
        councilModels = cm
    }

    func reload() {
        loadCouncilModels()
        let env = EnvFile.read()
        keys = Dictionary(uniqueKeysWithValues: providers.map { ($0.key, env[$0.value.keyEnv] ?? "") })
        tests = [:]
        dirty = false
    }

    var configuredCount: Int { keys.values.filter { !$0.isEmpty }.count }

    func hasKey(_ id: String) -> Bool { !(keys[id] ?? "").isEmpty }

    func binding(_ id: String) -> Binding<String> {
        Binding(get: { self.keys[id] ?? "" }, set: {
            let v = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            // I campi riscrivono lo stesso valore quando compaiono: conta solo un cambiamento vero.
            guard v != (self.keys[id] ?? "") else { return }
            self.keys[id] = v
            self.tests[id] = .idle
            self.dirty = true
        })
    }

    /// Verifica la chiave chiedendo al provider l'elenco dei modelli (nessun costo).
    func test(_ id: String) {
        // OpenRouter mostra l'elenco modelli anche senza chiave: per lui si interroga /key.
        let path = id == "openrouter" ? "key" : "models"
        guard let p = providers[id], let key = keys[id], !key.isEmpty,
              let url = URL(string: "\(p.baseUrl)/\(path)") else { return }
        tests[id] = .testing
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    tests[id] = await probeModels(id, p, key)
                } else if code == 401 || code == 403 || code == 400 {
                    tests[id] = .fail("Non funziona: chiave non valida (errore \(code)). Ricopiala per intero dalla pagina del provider.")
                } else {
                    tests[id] = .fail("Non funziona: il provider ha risposto con l'errore \(code). Riprova tra poco.")
                }
            } catch {
                tests[id] = .fail("Non funziona: connessione non riuscita (\(error.localizedDescription)).")
            }
        }
    }

    /// Prova davvero ogni modello del consiglio con una richiesta minima:
    /// l'elenco dei provider può includere modelli ritirati per i nuovi utenti.
    private func probeModels(_ id: String, _ p: ProviderConfig, _ key: String) async -> TestState {
        let wanted = councilModels[id] ?? []
        var working: [String] = [], busy: [String] = [], gone: [String] = []
        for m in wanted {
            // Principale e riserve: basta che uno risponda.
            var codes: [Int] = []
            for name in [m.model] + m.fallback {
                guard let url = URL(string: "\(p.baseUrl)/chat/completions") else { continue }
                var req = URLRequest(url: url, timeoutInterval: 45)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "model": name, "max_tokens": 200,
                    "messages": [["role": "user", "content": "Scrivi solo: OK"]],
                ])
                let code = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                codes.append(code)
                if code == 200 { break }
            }
            if codes.contains(200) { working.append(m.label) }
            else if codes.contains(where: { $0 == 429 || $0 >= 500 || $0 == 0 }) { busy.append(m.label) } // temporaneo
            else { gone.append(m.label) }                                                                 // 400/404: ritirato
        }
        let ok = working.isEmpty ? "" : " Rispondono: \(working.joined(separator: ", "))."
        if !gone.isEmpty {
            // Nessuna azione richiesta all'utente: al riavvio il motore li sostituisce e salva la scelta.
            return .warn("La chiave funziona.\(ok) Ritirati dal provider: \(gone.joined(separator: ", ")); l'app li sostituisce da sola con i migliori disponibili (li trovi nel pannello Modelli).")
        }
        if !busy.isEmpty {
            return .warn("La chiave funziona.\(ok) Occupati in questo momento: \(busy.joined(separator: ", ")); durante il dibattito l'app riprova da sola.")
        }
        return .ok(working.isEmpty ? "Funziona: la chiave è valida." : "Funziona: rispondono \(working.joined(separator: ", ")).")
    }

    func save() throws {
        var values: [String: String] = [:]
        for (id, p) in providers { values[p.keyEnv] = keys[id] ?? "" }
        try EnvFile.write(values)
        dirty = false
        onSaved?()
    }
}

// MARK: - Interfaccia: pannello Chiavi API

/// Esito di una verifica: simbolo colorato + testo leggibile (lo stato non dipende dal colore).
struct TestResultView: View {
    let state: TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifica in corso: provo i modelli…").foregroundStyle(.secondary)
            }
        case .ok(let m): line(m, "checkmark.circle.fill", .green)
        case .warn(let m): line(m, "exclamationmark.triangle.fill", .orange)
        case .fail(let m): line(m, "xmark.octagon.fill", .red)
        }
    }

    private func line(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}

struct ProviderSection: View {
    let guide: ProviderGuide
    @ObservedObject var model: SettingsModel
    @State private var showKey = false
    @State private var guideOpen: Bool

    init(guide: ProviderGuide, model: SettingsModel) {
        self.guide = guide
        self.model = model
        // Guida aperta solo se manca la chiave di un provider gratuito principale.
        _guideOpen = State(initialValue: !model.hasKey(guide.id) && !guide.optional)
    }

    private var test: TestState { model.tests[guide.id] ?? .idle }

    /// Stato a parole nell'intestazione della sezione.
    private var statusText: String {
        switch test {
        case .ok: return "Funziona"
        case .warn: return "Funziona, con avvisi"
        case .fail: return "Non funziona"
        case .testing: return "Verifica in corso"
        case .idle: return model.hasKey(guide.id) ? "Chiave inserita" : "Nessuna chiave"
        }
    }

    var body: some View {
        Section {
            LabeledContent("Chiave API") {
                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField("Chiave API", text: model.binding(guide.id), prompt: Text("Incolla la chiave"))
                        } else {
                            SecureField("Chiave API", text: model.binding(guide.id), prompt: Text("Incolla la chiave"))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 200)
                    Button(showKey ? "Nascondi" : "Mostra") { showKey.toggle() }
                        .help(showKey ? "Nascondi la chiave" : "Mostra la chiave per controllarla")
                    Button("Verifica") { model.test(guide.id) }
                        .help("Prova la chiave con una richiesta vera ai modelli del consiglio")
                        .disabled(!model.hasKey(guide.id) || test == .testing)
                }
            }

            if test != .idle { TestResultView(state: test) }

            DisclosureGroup("Come ottenere la chiave", isExpanded: $guideOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(guide.note)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: guide.url) {
                        Label("Apri la pagina delle chiavi di \(guide.name)", systemImage: "arrow.up.right.square")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(guide.free ? "\(guide.name) · Gratis" : "\(guide.name) · A pagamento")
                Spacer()
                Text(statusText).font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
            }
        } footer: {
            Text("\(guide.unlocks). \(guide.summary)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var close: () -> Void
    @State private var error: String?
    @AppStorage("SettingsShowOtherProviders") private var showOthers = false

    private var available: [ProviderGuide] { providerGuides.filter { model.providers[$0.id] != nil } }
    private var main: [ProviderGuide] { available.filter { !$0.optional } }
    private var others: [ProviderGuide] { available.filter(\.optional) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Puoi usare AI Council gratis").font(.headline)
                            Text("Claude non chiede chiavi se hai installato Claude Code con un abbonamento Claude (facoltativo). Gemini, Groq e OpenRouter danno chiavi gratuite, senza carta di credito: con queste il consiglio ha già più voci. Incolla una chiave, premi “Verifica”, poi “Salva e attiva”.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "gift").foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                }

                ForEach(main) { g in ProviderSection(guide: g, model: model) }

                if !others.isEmpty {
                    Section {
                        Toggle("Mostra altri provider (\(others.map(\.name).joined(separator: ", ")))", isOn: $showOthers)
                    } footer: {
                        Text("Facoltativi: servono solo se vuoi altre voci. OpenAI è l'unico a pagamento.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if showOthers || others.contains(where: { model.hasKey($0.id) }) {
                        ForEach(others) { g in ProviderSection(guide: g, model: model) }
                    }
                }

                Section {
                    Text("Le chiavi restano solo su questo Mac, nel file “.env” della cartella dati dell'app, leggibile solo dal tuo utente.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("\(model.configuredCount) di \(model.providers.count) provider configurati")
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                // Senza Esc: nei campi Esc deve solo annullare la modifica, non chiudere e perdere tutto.
                Button("Annulla") { model.reload(); close() }
                Button("Salva e attiva") {
                    do { try model.save(); close() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
            }
            .padding(14)
        }
        .frame(width: settingsPanelSize.width, height: settingsPanelSize.height)
    }
}

// MARK: - Finestra

/// Dimensione fissa dei pannelli: la finestra non si ridimensiona, il contenuto scorre nel Form.
let settingsPanelSize = CGSize(width: 680, height: 600)

enum SettingsTab: Int { case keys = 0, models = 1 }

/// Toolbar di pannelli di sistema; ricorda l'ultimo pannello aperto.
final class SettingsTabsController: NSTabViewController {
    static let lastTabKey = "SettingsLastTab"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastTabKey)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var tabs: SettingsTabsController?
    let model = SettingsModel()
    let models: ModelsModel

    init(port: @escaping () -> Int) {
        models = ModelsModel(port: port)
    }

    private func makeWindow() -> NSWindow {
        let close: () -> Void = { [weak self] in self?.window?.close() }
        let tabs = SettingsTabsController()
        tabs.tabStyle = .toolbar
        // Senza dissolvenza: con la transizione animata il pannello nuovo restava coperto da una fascia vuota.
        tabs.transitionOptions = []

        func item(_ vc: NSViewController, _ title: String, _ symbol: String) -> NSTabViewItem {
            vc.title = title   // il titolo della finestra segue il pannello scelto
            let it = NSTabViewItem(viewController: vc)
            it.label = title
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return it
        }
        let keysVC = NSHostingController(rootView: SettingsView(model: model, close: close))
        let modelsVC = NSHostingController(rootView: ModelsTab(model: models, close: close))
        for vc in [keysVC, modelsVC] as [NSViewController] { vc.preferredContentSize = settingsPanelSize }
        tabs.addTabViewItem(item(keysVC, "Chiavi API", "key"))
        tabs.addTabViewItem(item(modelsVC, "Modelli", "person.3"))
        let last = UserDefaults.standard.integer(forKey: SettingsTabsController.lastTabKey)
        tabs.selectedTabViewItemIndex = (0..<tabs.tabViewItems.count).contains(last) ? last : 0

        let w = NSWindow(contentViewController: tabs)
        // Niente Riduci né Zoom, finestra non ridimensionabile (HIG Impostazioni).
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("SettingsPanels")
        self.tabs = tabs
        return w
    }

    /// Il motore è (ri)partito: se le Impostazioni sono aperte si ricaricano i modelli,
    /// così "Motore non pronto" non resta a schermo dopo l'avvio.
    func engineStarted() {
        guard window?.isVisible == true else { return }
        Task { await models.load() }
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil { window = makeWindow() }
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        model.reload()
        Task { await models.load() }
        window?.makeKeyAndOrderFront(nil)
        // Nessun campo attivo all'apertura: altrimenti il pannello scorre fino alla ricerca.
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var hasAnyKey: Bool { model.configuredCount > 0 }
}
