// Finestra Impostazioni: inserimento delle chiavi API con guida passo passo per ogni provider.

import AppKit
import SwiftUI

// MARK: - Guide dei provider

struct ProviderGuide: Identifiable {
    let id: String          // chiave in models.json → providers
    let name: String
    let models: String      // modelli che sblocca
    let url: URL
    let steps: [String]
    let note: String
}

let providerGuides: [ProviderGuide] = [
    ProviderGuide(
        id: "gemini", name: "Google Gemini",
        models: "Gemini Flash",
        url: URL(string: "https://aistudio.google.com/apikey")!,
        steps: [
            "Apri Google AI Studio con il pulsante qui sotto e accedi con il tuo account Google.",
            "Accetta i termini di servizio, se richiesto.",
            "Clicca “Create API key” (Crea chiave API) e, se te lo chiede, scegli o crea un progetto.",
            "Copia la chiave (inizia con “AIza…”) e incollala nel campo qui sotto.",
        ],
        note: "Gratuito ma con quote basse: i Gemini Flash circa 20 richieste al giorno (un dibattito completo ne usa 4), i Flash Lite circa 500, Gemma circa 14.000. Finita la quota l'app passa da sola al modello successivo. I Pro non sono inclusi. Nel piano gratuito Google può usare i dati per migliorare i suoi modelli: non inserire informazioni riservate."),
    ProviderGuide(
        id: "groq", name: "Groq",
        models: "GPT-OSS 120B, Llama 3.3 70B, Kimi K2",
        url: URL(string: "https://console.groq.com/keys")!,
        steps: [
            "Apri la console Groq e registrati (va bene anche l'account Google).",
            "Nel menu “API Keys” clicca “Create API Key” e dagli un nome, es. “AI Council”.",
            "Copia subito la chiave (inizia con “gsk_…”): Groq la mostra una sola volta.",
            "Incollala nel campo qui sotto.",
        ],
        note: "Gratuito senza carta di credito, molto veloce. Ha limiti al minuto: con troppi modelli insieme l'app aspetta e riprova da sola."),
    ProviderGuide(
        id: "openrouter", name: "OpenRouter",
        models: "DeepSeek e gli altri modelli “:free”",
        url: URL(string: "https://openrouter.ai/settings/keys")!,
        steps: [
            "Apri OpenRouter e registrati.",
            "In “Keys” clicca “Create Key”; come limite di credito puoi lasciare 0 per non spendere mai nulla.",
            "Copia la chiave (inizia con “sk-or-…”) e incollala nel campo qui sotto.",
        ],
        note: "Usiamo solo i modelli gratuiti (quelli con “:free” nel nome). Senza credito il numero di richieste al giorno è basso."),
    ProviderGuide(
        id: "mistral", name: "Mistral (facoltativo)",
        models: "Mistral Small",
        url: URL(string: "https://console.mistral.ai/api-keys")!,
        steps: [
            "Apri la console Mistral e registrati.",
            "Scegli il piano gratuito “Experiment” (chiede di verificare il numero di telefono).",
            "In “API Keys” clicca “Create new key”, poi copia la chiave.",
            "Incollala nel campo qui sotto.",
        ],
        note: "Gratuito con limiti. Utile come voce europea in più nel consiglio."),
    ProviderGuide(
        id: "cerebras", name: "Cerebras (facoltativo)",
        models: "GPT-OSS, Qwen, Llama e altri modelli open, molto veloci",
        url: URL(string: "https://cloud.cerebras.ai")!,
        steps: [
            "Apri Cerebras Cloud e registrati.",
            "Nel menu “API Keys” crea una nuova chiave e copiala (inizia con “csk-…”).",
            "Incollala nel campo qui sotto, poi scegli i modelli nella scheda “Modelli”.",
        ],
        note: "Piano gratuito con limiti giornalieri. Utile come alternativa a Groq per gli stessi modelli open."),
    ProviderGuide(
        id: "openai", name: "OpenAI – ChatGPT (a pagamento)",
        models: "GPT ufficiali di OpenAI",
        url: URL(string: "https://platform.openai.com/api-keys")!,
        steps: [
            "Attenzione: l'abbonamento ChatGPT (anche gratuito) non include le API, e OpenAI non offre più crediti gratuiti garantiti.",
            "Se vuoi comunque usarlo: apri la piattaforma OpenAI, aggiungi credito in “Billing”.",
            "In “API keys” clicca “Create new secret key”, copia la chiave (inizia con “sk-…”) e incollala qui.",
        ],
        note: "Per avere GPT gratis usa GPT-OSS, il modello open di OpenAI, tramite Groq, Cerebras o OpenRouter."),
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
                    tests[id] = .fail("Chiave non valida (errore \(code)). Ricopiala dalla pagina del provider.")
                } else {
                    tests[id] = .fail("Il provider ha risposto con errore \(code). Riprova tra poco.")
                }
            } catch {
                tests[id] = .fail("Connessione non riuscita: \(error.localizedDescription)")
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
        if !gone.isEmpty {
            // Nessuna azione richiesta all'utente: al riavvio il motore li sostituisce e salva la scelta.
            let ok = working.isEmpty ? "" : "funzionante: \(working.joined(separator: ", ")). "
            return .ok("Chiave valida · \(ok)Ritirati dal provider: \(gone.joined(separator: ", ")). L'app li sostituisce da sola con i migliori modelli disponibili: li trovi nella scheda Modelli.")
        }
        if !busy.isEmpty {
            let ok = working.isEmpty ? "" : "attivo: \(working.joined(separator: ", ")) · "
            return .ok("Chiave valida · \(ok)momentaneamente occupato: \(busy.joined(separator: ", ")) (durante il dibattito l'app riprova da sola)")
        }
        return .ok("Chiave valida · funzionante: \(working.joined(separator: ", "))")
    }

    func save() throws {
        var values: [String: String] = [:]
        for (id, p) in providers { values[p.keyEnv] = keys[id] ?? "" }
        try EnvFile.write(values)
        dirty = false
        onSaved?()
    }
}

// MARK: - Interfaccia

struct ProviderSection: View {
    let guide: ProviderGuide
    @ObservedObject var model: SettingsModel
    @State private var showKey = false
    @State private var expanded: Bool

    init(guide: ProviderGuide, model: SettingsModel) {
        self.guide = guide
        self.model = model
        _expanded = State(initialValue: (model.keys[guide.id] ?? "").isEmpty)
    }

    private var hasKey: Bool { !(model.keys[guide.id] ?? "").isEmpty }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Dopo aver incollato la chiave premi “Verifica”, poi “Salva e attiva” in basso.")
                        .font(.callout.weight(.medium))
                        .padding(.top, 2)
                    Text(guide.note)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Button {
                        NSWorkspace.shared.open(guide.url)
                    } label: {
                        Label("Apri la pagina per creare la chiave", systemImage: "arrow.up.right.square")
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            } label: {
                HStack {
                    Image(systemName: hasKey ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(hasKey ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(guide.name).font(.headline)
                        Text(guide.models).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Group {
                    if showKey {
                        TextField("Incolla qui la chiave", text: model.binding(guide.id))
                    } else {
                        SecureField("Incolla qui la chiave", text: model.binding(guide.id))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(showKey ? "Nascondi" : "Mostra")
                Button("Verifica") { model.test(guide.id) }
                    .disabled(!hasKey || model.tests[guide.id] == .testing)
            }

            switch model.tests[guide.id] ?? .idle {
            case .idle: EmptyView()
            case .testing: HStack { ProgressView().controlSize(.small); Text("Verifica in corso (provo i modelli)…").foregroundStyle(.secondary) }
            case .ok(let m): Label(m, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .warn(let m): Label(m, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .fail(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var close: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chiavi API").font(.title2.bold())
                        Text("Claude usa il tuo abbonamento Pro tramite Claude Code e non richiede chiavi. Per far partecipare gli altri modelli servono chiavi gratuite: segui la guida di ciascun provider. Ne bastano due per avere un dibattito; più ne aggiungi, più voci avrà il consiglio.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(providerGuides.filter { model.providers[$0.id] != nil }) { g in
                    ProviderSection(guide: g, model: model)
                }
                Section {
                    Text("Le chiavi restano solo su questo Mac, nel file “.env” della cartella dati dell'app, leggibile solo dal tuo utente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("\(model.configuredCount) di \(model.providers.count) provider configurati")
                    .foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Annulla") { model.reload(); close() }
                    .keyboardShortcut(.cancelAction)
                Button("Salva e attiva") {
                    do { try model.save(); close() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
            }
            .padding(14)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 720)
    }
}

// MARK: - Finestra

enum SettingsTab: Hashable { case keys, models }

@MainActor
final class SettingsNav: ObservableObject {
    @Published var tab: SettingsTab = .keys
}

struct SettingsRoot: View {
    @ObservedObject var nav: SettingsNav
    @ObservedObject var keys: SettingsModel
    @ObservedObject var models: ModelsModel
    var close: () -> Void

    var body: some View {
        TabView(selection: $nav.tab) {
            SettingsView(model: keys, close: close)
                .tabItem { Label("Chiavi API", systemImage: "key") }
                .tag(SettingsTab.keys)
            ModelsTab(model: models, close: close)
                .tabItem { Label("Modelli", systemImage: "person.3") }
                .tag(SettingsTab.models)
        }
        .padding(.top, 6)
        .frame(minWidth: 640, minHeight: 560)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    let model = SettingsModel()
    let models: ModelsModel
    private let nav = SettingsNav()

    init(port: @escaping () -> Int) {
        models = ModelsModel(port: port)
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Impostazioni"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: SettingsRoot(nav: nav, keys: model, models: models) { [weak w] in w?.close() })
            w.setContentSize(NSSize(width: 720, height: 780))
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            window = w
        }
        if let tab { nav.tab = tab }
        model.reload()
        Task { await models.load() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var hasAnyKey: Bool { model.configuredCount > 0 }
}
