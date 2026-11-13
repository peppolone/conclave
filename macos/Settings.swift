// Finestra Impostazioni: barra laterale con le pagine (Generale, Chiavi API, Modelli,
// Informazioni) e a destra la pagina scelta, con sezioni e righe etichetta / controllo.

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
        unlocks: L("Voce Gemini (Flash, Flash Lite e Gemma come riserve)"),
        summary: L("Gratis, senza carta di credito."),
        url: URL(string: "https://aistudio.google.com/apikey")!,
        steps: [
            L("Apri Google AI Studio e accedi con il tuo account Google (accetta i termini, se li chiede)."),
            L("Clicca “Create API key”; se lo chiede, scegli o crea un progetto."),
            L("Copia la chiave (inizia con “AIza”) e incollala nel campo qui sopra."),
        ],
        note: L("Quote gratuite basse: Gemini Flash circa 20 richieste al giorno (un dibattito ne usa 4), Flash Lite circa 500, Gemma circa 14.000. Finita una quota l'app passa da sola al modello successivo. Nel piano gratuito Google può usare i dati per migliorare i suoi modelli: non inserire informazioni riservate.")),
    ProviderGuide(
        id: "groq", name: "Groq", free: true, optional: false,
        unlocks: L("Voci GPT-OSS e Qwen"),
        summary: L("Gratis, senza carta di credito, molto veloce."),
        url: URL(string: "https://console.groq.com/keys")!,
        steps: [
            L("Apri la console Groq e registrati (va bene anche l'account Google)."),
            L("In “API Keys” clicca “Create API Key” e dagli un nome, per esempio “Conclave”."),
            L("Copia subito la chiave (inizia con “gsk_”, Groq la mostra una sola volta) e incollala qui sopra."),
        ],
        note: L("Ha limiti al minuto: con molti modelli insieme l'app aspetta e riprova da sola.")),
    ProviderGuide(
        id: "openrouter", name: "OpenRouter", free: true, optional: false,
        unlocks: L("Modelli gratuiti “:free” (per esempio Nemotron e DeepSeek)"),
        summary: L("Gratis con i modelli “:free”, senza credito."),
        url: URL(string: "https://openrouter.ai/settings/keys")!,
        steps: [
            L("Apri OpenRouter e registrati."),
            L("In “Keys” clicca “Create Key”; come limite di credito lascia 0 per non spendere mai nulla."),
            L("Copia la chiave (inizia con “sk-or-”) e incollala qui sopra."),
        ],
        note: L("L'app usa solo i modelli gratuiti, quelli con “:free” nel nome. Senza credito le richieste al giorno sono poche e alcuni modelli sono lenti.")),
    ProviderGuide(
        id: "mistral", name: "Mistral", free: true, optional: true,
        unlocks: L("Voce Mistral Small"),
        summary: L("Gratis con limiti (piano “Experiment”)."),
        url: URL(string: "https://console.mistral.ai/api-keys")!,
        steps: [
            L("Apri la console Mistral e registrati."),
            L("Scegli il piano gratuito “Experiment” (chiede di verificare il numero di telefono)."),
            L("In “API Keys” clicca “Create new key”, copia la chiave e incollala qui sopra."),
        ],
        note: L("Utile come voce europea in più nel consiglio.")),
    ProviderGuide(
        id: "cerebras", name: "Cerebras", free: true, optional: true,
        unlocks: L("GPT-OSS, Qwen, Llama e altri modelli open, molto veloci"),
        summary: L("Gratis con limiti giornalieri."),
        url: URL(string: "https://cloud.cerebras.ai")!,
        steps: [
            L("Apri Cerebras Cloud e registrati."),
            L("In “API Keys” crea una nuova chiave e copiala (inizia con “csk-”)."),
            L("Incollala qui sopra, poi scegli i modelli nel pannello “Modelli”."),
        ],
        note: L("Un'alternativa a Groq per gli stessi modelli open.")),
    ProviderGuide(
        id: "openai", name: "OpenAI", free: false, optional: true,
        unlocks: L("Modelli GPT ufficiali di OpenAI"),
        summary: L("Solo a pagamento: l'abbonamento ChatGPT non include le API."),
        url: URL(string: "https://platform.openai.com/api-keys")!,
        steps: [
            L("Apri la piattaforma OpenAI e aggiungi credito in “Billing”."),
            L("In “API keys” clicca “Create new secret key”."),
            L("Copia la chiave (inizia con “sk-”) e incollala qui sopra."),
        ],
        note: L("Per avere GPT gratis non serve questa chiave: GPT-OSS, il modello open di OpenAI, è disponibile gratis con Groq, Cerebras o OpenRouter.")),
]

// MARK: - Chiavi API

enum EnvFile {
    static func read() -> [String: String] {
        guard let text = try? String(contentsOf: Paths.envFile, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (k, v) = parse(line) else { continue }
            out[k] = v
        }
        return out
    }

    private static func parse(_ line: Substring) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return (String(t[..<eq]), String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
    }

    private static func envLines() -> [String] {
        ((try? String(contentsOf: Paths.envFile, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Aggiorna solo le variabili indicate, lasciando invariati commenti e altre righe.
    static func write(_ values: [String: String]) throws {
        var lines = envLines()
        var pending = values
        for i in lines.indices {
            guard let (k, _) = parse(Substring(lines[i])) else { continue }
            if let v = pending.removeValue(forKey: k) { lines[i] = "\(k)=\(v)" }
        }
        if lines.last == "" { lines.removeLast() }
        for (k, v) in pending.sorted(by: { $0.key < $1.key }) { lines.append("\(k)=\(v)") }
        try save(lines)
    }

    /// Toglie le righe delle variabili per cui `drop` è vero, lasciando invariato il resto.
    static func remove(where drop: (String) -> Bool) throws {
        let all = envLines()
        let kept = all.filter { line in parse(Substring(line)).map { !drop($0.0) } ?? true }
        guard kept.count != all.count else { return }
        try save(kept.last == "" ? Array(kept.dropLast()) : kept)
    }

    /// File temporaneo già 0600 (le chiavi sono personali) e poi rename: mai un `.env` a metà.
    private static func save(_ lines: [String]) throws {
        let tmp = Paths.dataDir.appendingPathComponent(".env.tmp")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        guard rename(tmp.path, Paths.envFile.path) == 0 else {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: tmp)
            throw err
        }
    }
}

/// Dove stanno le chiavi API: nel Portachiavi; nelle prove (`COUNCIL_DATA`) nel `.env` della
/// cartella temporanea, senza mai toccare il Portachiavi reale.
enum KeyStore {
    static var usesKeychain: Bool { (ProcessInfo.processInfo.environment["COUNCIL_DATA"] ?? "").isEmpty }

    static func isSecret(_ name: String) -> Bool { name.hasSuffix("_KEY") || name.hasSuffix("_TOKEN") }

    /// Tutte le chiavi in una sola voce (JSON nome → valore). Senza Team ID Apple il Portachiavi
    /// lega la voce alla singola build (partition list `cdhash:`): dopo un aggiornamento chiede
    /// la password una volta per voce, quindi una voce sola = una sola richiesta ("Sempre").
    /// La voce non si cancella mai (una build diversa non può: errSecInvalidOwnerEdit), si riscrive.
    private static let account = "api-keys"

    /// nil se la voce non esiste ancora.
    private static func stored() throws -> [String: String]? {
        guard let text = try Keychain.conclave.read(account) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else {
            throw KeychainError(status: errSecDecode, account: account)
        }
        return dict
    }

    private static func store(_ keys: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: keys.filter { !$0.value.isEmpty }, options: [.sortedKeys])
        try Keychain.conclave.write(account, String(decoding: data, as: UTF8.self))
    }

    /// Valori delle variabili indicate. Una chiave rimasta nel `.env` (passaggio al Portachiavi
    /// non riuscito) vale finché non è nel Portachiavi: il motore la usa ancora.
    static func read(_ names: [String]) -> [String: String] {
        let env = EnvFile.read()
        guard usesKeychain else { return env }
        let keys: [String: String]
        do { keys = try stored() ?? [:] }
        catch { NSLog("Conclave: %@", error.localizedDescription); keys = [:] }
        var out: [String: String] = [:]
        for name in names { out[name] = keys[name] ?? env[name] }
        return out
    }

    /// Salva le chiavi indicate (valore vuoto = toglie). Se la voce esiste ma non si legge, non si
    /// scrive nulla: riscriverla perderebbe le altre chiavi. Nel `.env` non devono restare copie
    /// vecchie: il motore le leggerebbe ancora.
    static func write(_ values: [String: String]) throws {
        guard usesKeychain else { return try EnvFile.write(values) }
        var keys = try stored() ?? [:]
        for (name, value) in values { keys[name] = value.isEmpty ? nil : value }
        try store(keys)
        try EnvFile.remove { values[$0] != nil }
    }

    /// Chiavi non vuote da mandare al motore sullo stdin (mai nell'ambiente né su disco).
    static func engineKeys() -> [String: String] {
        guard usesKeychain else { return [:] }
        do { return try stored() ?? [:] }
        catch { NSLog("Conclave: chiavi non lette dal Portachiavi: %@", error.localizedDescription); return [:] }
    }

    /// Una sola volta (e di nuovo se qualcuno rimette chiavi nel `.env`): sposta le variabili
    /// `*_KEY`/`*_TOKEN` nel Portachiavi. Il `.env` si riscrive senza quelle righe solo se la
    /// scrittura è riuscita; altrimenti resta com'è e il motore continua a leggerlo.
    static func migrateEnvFile() {
        guard usesKeychain else { return }
        let secrets = EnvFile.read().filter { isSecret($0.key) }
        guard !secrets.isEmpty else { return }
        do {
            var keys = try stored() ?? [:]
            for (name, value) in secrets where !value.isEmpty { keys[name] = value }
            try store(keys)
            try EnvFile.remove(where: isSecret)
        } catch {
            NSLog("Conclave: chiavi non spostate nel Portachiavi, il file .env resta invariato: %@", error.localizedDescription)
        }
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
    /// Valori letti all'apertura: si salvano solo le chiavi cambiate, così una voce che non si è
    /// potuta leggere (campo vuoto) non viene cancellata da un salvataggio.
    private var loadedKeys: [String: String] = [:]
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
        let stored = KeyStore.read(providers.values.map(\.keyEnv))
        keys = Dictionary(uniqueKeysWithValues: providers.map { ($0.key, stored[$0.value.keyEnv] ?? "") })
        loadedKeys = keys
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
                    tests[id] = .fail(String(format: L("Non funziona: chiave non valida (errore %d). Ricopiala per intero dalla pagina del provider."), code))
                } else {
                    tests[id] = .fail(String(format: L("Non funziona: il provider ha risposto con l'errore %d. Riprova tra poco."), code))
                }
            } catch {
                tests[id] = .fail(String(format: L("Non funziona: connessione non riuscita (%@)."), error.localizedDescription))
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
        let list = { (names: [String]) in names.joined(separator: ", ") }
        let ok = working.isEmpty ? [] : [String(format: L("Rispondono: %@."), list(working))]
        if !gone.isEmpty {
            // Nessuna azione richiesta all'utente: al riavvio il motore li sostituisce e salva la scelta.
            return .warn(([L("La chiave funziona.")] + ok + [String(format: L("Ritirati dal provider: %@; l'app li sostituisce da sola con i migliori disponibili (li trovi nel pannello Modelli)."), list(gone))]).joined(separator: " "))
        }
        if !busy.isEmpty {
            return .warn(([L("La chiave funziona.")] + ok + [String(format: L("Occupati in questo momento: %@; durante il dibattito l'app riprova da sola."), list(busy))]).joined(separator: " "))
        }
        return .ok(working.isEmpty ? L("Funziona: la chiave è valida.") : String(format: L("Funziona: rispondono %@."), list(working)))
    }

    func save() throws {
        var values: [String: String] = [:]
        for (id, p) in providers where (keys[id] ?? "") != (loadedKeys[id] ?? "") { values[p.keyEnv] = keys[id] ?? "" }
        try KeyStore.write(values)
        loadedKeys = keys
        dirty = false
        onSaved?()
    }
}

/// Stato dell'interfaccia delle pagine: le pagine si ricreano a ogni cambio di voce nella barra
/// laterale e i loro `@State` ripartirebbero da capo. Vive quanto la finestra; si azzera solo
/// quando le Impostazioni si riaprono (insieme al ricaricamento dei dati).
@MainActor
final class SettingsPageState: ObservableObject {
    @Published var shownKeys: Set<String> = []        // provider con la chiave in chiaro
    @Published var guideOpen: [String: Bool] = [:]    // provider → guida aperta (nil = predefinito)
    @Published var loginError: String?                // pagina Generale
    @Published var keysError: String?                 // pagina Chiavi API
    @Published var modelsError: String?               // pagina Modelli
    @Published var modelsSaving = false
    @Published var modelsExpanded: Set<String> = []

    func reset() {
        shownKeys = []
        guideOpen = [:]
        loginError = nil
        keysError = nil
        modelsError = nil
        modelsExpanded = []
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
        case .ok(let m): line(m, "checkmark.circle.fill", Brand.success)
        case .warn(let m): line(m, "exclamationmark.triangle.fill", Brand.warning)
        case .fail(let m): line(m, "xmark.octagon.fill", Brand.danger)
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

// MARK: - Elementi comuni delle pagine

/// Linea sottile tra le righe di una sezione.
struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(Brand.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// Pagina delle Impostazioni: titolo grande e sezioni una sotto l'altra, il contenuto scorre.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sezione con titolo, righe separate da linee sottili e una nota facoltativa sotto.
struct SettingsSection<Accessory: View, Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory.font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            .padding(.bottom, 6)
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    row
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.id != rows.last?.id { SettingsHairline() }
                }
            }
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// Riga etichetta a sinistra (con spiegazione facoltativa) e controllo a destra.
struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if detail == nil {
                    // Etichetta breve: sempre su una riga, mai spezzata a metà parola.
                    Text(label).lineLimit(1).fixedSize()
                } else {
                    Text(label).fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 16)
            control
        }
    }
}

/// Barra in fondo alla pagina (stato a sinistra, Annulla / Salva e attiva a destra).
struct SettingsBar<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHairline()
            HStack(spacing: 8) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }
}

// MARK: - Pagina Generale

struct GeneralPage: View {
    @State private var appearance = AppAppearance.current
    @State private var language = AppLanguage.current
    @State private var openAtLogin = LoginItem.enabled || LoginItem.needsApproval
    @ObservedObject var ui: SettingsPageState
    @State private var menuBar = MenuBarPreference.enabled
    @AppStorage(UpdateCheck.enabledKey) private var updates = true

    private var appearanceDetail: String {
        switch appearance {
        case .system: return L("Sistema: segue l'aspetto scelto in macOS.")
        case .light: return L("Chiaro: sempre chiaro, anche se macOS è scuro.")
        case .dark: return L("Scuro: sempre scuro, anche se macOS è chiaro.")
        }
    }

    private var loginDetail: String {
        if let loginError = ui.loginError { return loginError }
        if LoginItem.needsApproval { return L("Da approvare in Impostazioni di Sistema ▸ Generali ▸ Elementi di login.") }
        return L("Conclave si apre da solo quando accedi al Mac.")
    }

    var body: some View {
        SettingsPage(L("Generale")) {
            SettingsSection(L("Aspetto")) {
                SettingsRow(L("Tema"), detail: appearanceDetail) {
                    Picker(L("Tema"), selection: $appearance) {
                        ForEach(AppAppearance.allCases) { a in
                            Label(a.title, systemImage: a.symbol)
                                .labelStyle(.iconOnly)
                                .help(a.title)
                                .tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)
                    .help(L("Tema") + ": " + appearance.title)
                }
            }
            SettingsSection(L("Lingua")) {
                SettingsRow(L("Lingua dell'interfaccia"),
                            detail: L("Le risposte dei modelli seguono sempre la lingua della domanda.")) {
                    Picker(L("Lingua dell'interfaccia"), selection: $language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.title).tag(l) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if language != AppLanguage.launched {
                    SettingsRow(L("La nuova lingua si applica al riavvio di Conclave.")) {
                        Button(L("Riavvia ora")) { AppLanguage.relaunch() }
                    }
                }
            }
            SettingsSection(L("Avvio e barra dei menu")) {
                SettingsRow(L("Apri all'accesso"), detail: loginDetail) {
                    Toggle(L("Apri all'accesso"), isOn: $openAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow(L("Mostra nella barra dei menu"),
                            detail: L("Icona di Conclave in alto a destra: nuova discussione, discussioni recenti e finestra principale. Chiudendo la finestra l'app resta attiva.")) {
                    Toggle(L("Mostra nella barra dei menu"), isOn: $menuBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            SettingsSection(L("Aggiornamenti")) {
                SettingsRow(L("Controlla gli aggiornamenti"),
                            detail: L("Una volta a settimana Conclave chiede a GitHub se c'è una versione nuova e ti avvisa. Non installa nulla da solo e non invia dati.")) {
                    Toggle(L("Controlla gli aggiornamenti"), isOn: $updates)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
        .onChange(of: appearance) { _, a in AppAppearance.apply(a) }
        .onChange(of: language) { _, l in AppLanguage.save(l) }
        .onChange(of: menuBar) { _, on in MenuBarPreference.set(on) }
        .onChange(of: openAtLogin) { _, on in
            // "Da approvare" conta come attivo: spegnendo l'interruttore si annulla la registrazione.
            guard on != (LoginItem.enabled || LoginItem.needsApproval) else { return }
            do {
                try LoginItem.set(on)
                ui.loginError = nil
            } catch {
                ui.loginError = L("Non è stato possibile cambiare l'apertura all'accesso:") + " " + error.localizedDescription
                openAtLogin = LoginItem.enabled || LoginItem.needsApproval
            }
        }
    }
}

// MARK: - Pagina Chiavi API

struct ProviderSection: View {
    let guide: ProviderGuide
    @ObservedObject var model: SettingsModel
    @ObservedObject var ui: SettingsPageState

    private var showKey: Bool {
        get { ui.shownKeys.contains(guide.id) }
        nonmutating set { if newValue { ui.shownKeys.insert(guide.id) } else { ui.shownKeys.remove(guide.id) } }
    }

    /// Guida aperta in partenza solo se manca la chiave di un provider gratuito principale;
    /// poi vale la scelta dell'utente, che resta anche cambiando pagina.
    private var guideOpen: Binding<Bool> {
        Binding(get: { ui.guideOpen[guide.id] ?? (!model.hasKey(guide.id) && !guide.optional) },
                set: { ui.guideOpen[guide.id] = $0 })
    }

    private var test: TestState { model.tests[guide.id] ?? .idle }

    /// Stato a parole accanto al titolo della sezione.
    private var statusText: String {
        switch test {
        case .ok: return L("Funziona")
        case .warn: return L("Funziona, con avvisi")
        case .fail: return L("Non funziona")
        case .testing: return L("Verifica in corso")
        case .idle: return model.hasKey(guide.id) ? L("Chiave inserita") : L("Nessuna chiave")
        }
    }

    var body: some View {
        SettingsSection(guide.name, footer: guide.unlocks + ". " + guide.summary) {
            HStack(spacing: 8) {
                Badge.cost(guide.free)
                Text(statusText)
            }
        } content: {
            SettingsRow(L("Chiave API")) {
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
                    .frame(minWidth: 200, maxWidth: 260)
                    Button(showKey ? L("Nascondi") : L("Mostra")) { showKey.toggle() }
                        .help(showKey ? L("Nascondi la chiave") : L("Mostra la chiave per controllarla"))
                        .fixedSize()
                    Button("Verifica") { model.test(guide.id) }
                        .fixedSize()
                        .help("Prova la chiave con una richiesta vera ai modelli del consiglio")
                        .disabled(!model.hasKey(guide.id) || test == .testing)
                }
            }

            if test != .idle { TestResultView(state: test) }

            DisclosureGroup("Come ottenere la chiave", isExpanded: guideOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(guide.note)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: guide.url) {
                        Label(String(format: L("Apri la pagina delle chiavi di %@"), guide.name), systemImage: "arrow.up.right.square")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var ui: SettingsPageState
    var close: () -> Void
    @AppStorage("SettingsShowOtherProviders") private var showOthers = false

    private var available: [ProviderGuide] { providerGuides.filter { model.providers[$0.id] != nil } }
    private var main: [ProviderGuide] { available.filter { !$0.optional } }
    private var others: [ProviderGuide] { available.filter(\.optional) }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPage(L("Chiavi API")) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "gift")
                        .font(.title2)
                        .foregroundStyle(Brand.success)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Puoi usare Conclave gratis").font(.headline)
                        Text("Claude non chiede chiavi se hai installato Claude Code con un abbonamento Claude (facoltativo). Gemini, Groq e OpenRouter danno chiavi gratuite, senza carta di credito: con queste il consiglio ha già più voci. Incolla una chiave, premi “Verifica”, poi “Salva e attiva”.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline))
                .accessibilityElement(children: .combine)

                ForEach(main) { g in ProviderSection(guide: g, model: model, ui: ui) }

                if !others.isEmpty {
                    SettingsSection(L("Altri provider"), footer: L("Facoltativi: servono solo se vuoi altre voci. OpenAI è l'unico a pagamento.")) {
                        SettingsRow(L("Mostra altri provider"), detail: others.map(\.name).joined(separator: ", ")) {
                            Toggle(L("Mostra altri provider"), isOn: $showOthers)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                    if showOthers || others.contains(where: { model.hasKey($0.id) }) {
                        ForEach(others) { g in ProviderSection(guide: g, model: model, ui: ui) }
                    }
                }

                Text("Le chiavi restano solo su questo Mac, nel Portachiavi di macOS (voci “Conclave – …” in Accesso Portachiavi).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsBar {
                Text(String(format: L("%d di %d provider configurati"), model.configuredCount, model.providers.count))
                    .foregroundStyle(.secondary)
                if let error = ui.keysError {
                    Text(error).foregroundStyle(Brand.danger).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                // Senza Esc: nei campi Esc deve solo annullare la modifica, non chiudere e perdere tutto.
                Button("Annulla") { model.reload(); close() }
                Button("Salva e attiva") {
                    do { try model.save(); ui.keysError = nil; close() } catch { ui.keysError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty)
            }
        }
    }
}

// MARK: - Pagina Informazioni

let projectURL = URL(string: "https://github.com/peppolone/Conclave")!

struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return L("di sviluppo") }
        if let b = info?["CFBundleVersion"] as? String, b != v { return "\(v) (\(b))" }
        return v
    }

    var body: some View {
        SettingsPage(L("Informazioni")) {
            HStack(spacing: 16) {
                CouncilLogo(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conclave").font(.title3.weight(.semibold))
                    Text(String(format: L("Versione %@"), version)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)

            Text("Più modelli di intelligenza artificiale discutono la tua domanda in round, si criticano a vicenda e un giudice emette il verdetto. Chiavi e discussioni restano su questo Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSection(L("Collegamenti")) {
                SettingsRow(L("Progetto"), detail: L("Codice sorgente e novità")) {
                    Link(destination: projectURL) {
                        Label("Apri su GitHub", systemImage: "arrow.up.right.square")
                    }
                }
                SettingsRow(L("Cartella dati"), detail: L("Chiavi, scelta dei modelli e cronologia delle discussioni")) {
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.dataDir])
                    }
                }
            }
        }
    }
}

// MARK: - Navigazione

enum SettingsTab: Int, CaseIterable, Identifiable {
    case keys = 0, models = 1, general = 2, about = 3
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: L("Generale")
        case .keys: L("Chiavi API")
        case .models: L("Modelli")
        case .about: L("Informazioni")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .keys: "key"
        case .models: "person.3"
        case .about: "info.circle"
        }
    }

    /// Parole che la ricerca della barra laterale riconosce.
    var keywords: String {
        switch self {
        case .general: L("aspetto tema chiaro scuro sistema carattere font lingua language accesso login avvio barra dei menu")
        case .keys: L("chiave chiavi api provider gemini groq openrouter mistral cerebras openai gratis")
        case .models: L("voci consiglio catalogo claude famiglia prova riserva automatico")
        case .about: L("versione progetto github cartella dati")
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q) || keywords.lowercased().contains(q)
    }
}

/// Gruppi della barra laterale, nell'ordine in cui compaiono.
private let settingsGroups: [(title: String, tabs: [SettingsTab])] = [
    (L("Preferenze"), [.general]),
    (L("Consiglio"), [.keys, .models]),
    ("Conclave", [.about]),
]

/// Pagina scelta; ricorda l'ultima aperta.
@MainActor
final class SettingsNav: ObservableObject {
    static let lastTabKey = "SettingsLastTab"
    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey) }
    }

    init() {
        tab = SettingsTab(rawValue: UserDefaults.standard.integer(forKey: Self.lastTabKey)) ?? .keys
    }
}

struct SettingsSidebar: View {
    @ObservedObject var nav: SettingsNav
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $query, prompt: L("Cerca"))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
            List(selection: Binding<SettingsTab?>(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) {
                ForEach(settingsGroups, id: \.title) { group in
                    let tabs = group.tabs.filter { $0.matches(query) }
                    if !tabs.isEmpty {
                        Section(group.title) {
                            ForEach(tabs) { t in
                                Label(t.title, systemImage: t.symbol)
                                    .tag(t)
                                    .listItemTint(.fixed(Brand.accent))
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(nav.tab == t ? Brand.selection : .clear)
                                            .padding(.horizontal, 10)
                                    )
                                    .background(SystemHighlightRemover())
                            }
                        }
                    }
                }
                if !SettingsTab.allCases.contains(where: { $0.matches(query) }) {
                    Text("Nessun risultato").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .tint(Brand.accent)
        }
    }
}

struct SettingsDetail: View {
    @ObservedObject var nav: SettingsNav
    let keys: SettingsModel
    let models: ModelsModel
    let ui: SettingsPageState
    let close: () -> Void

    var body: some View {
        Group {
            switch nav.tab {
            case .general: GeneralPage(ui: ui)
            case .keys: SettingsView(model: keys, ui: ui, close: close)
            case .models: ModelsTab(model: models, ui: ui, close: close)
            case .about: AboutPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Lo sfondo di marchio sta sotto tutta la finestra (anche dietro la barra laterale).
        .tint(Brand.accent)
    }
}

// MARK: - Finestra

/// Dimensione fissa della finestra (HIG Impostazioni: non ridimensionabile); le pagine scorrono.
let settingsWindowSize = CGSize(width: 820, height: 600)
private let settingsSidebarWidth: CGFloat = 200

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let nav = SettingsNav()
    private let ui = SettingsPageState()
    let model = SettingsModel()
    let models: ModelsModel

    init(port: @escaping () -> Int) {
        models = ModelsModel(port: port)
        super.init()
    }

    private func makeWindow() -> NSWindow {
        // performClose passa da windowShouldClose: dopo "Salva e attiva" in una pagina si chiede
        // comunque delle modifiche non salvate nell'altra.
        let close: () -> Void = { [weak self] in self?.window?.performClose(nil) }

        let sidebarVC = NSHostingController(rootView: SettingsSidebar(nav: nav).rebuildOnAppearanceChange())
        let detailVC = NSHostingController(rootView: SettingsDetail(nav: nav, keys: model, models: models, ui: ui, close: close).rebuildOnAppearanceChange())
        // Solo il vincolo di dimensione massima: con [] la vista SwiftUI resta fuori da Auto Layout
        // e alla prima apertura gli interruttori comparivano senza pomello; con il predefinito
        // .standardBounds (anche minimo e dimensione ideale) la pagina Modelli allargava la finestra.
        sidebarVC.sizingOptions = [.maxSize]
        detailVC.sizingOptions = [.maxSize]

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = settingsSidebarWidth
        sidebarItem.maximumThickness = settingsSidebarWidth
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = settingsWindowSize.width - settingsSidebarWidth - 40

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        // Niente Riduci né Zoom, finestra non ridimensionabile (HIG Impostazioni).
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: settingsWindowSize),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = L("Impostazioni")
        w.delegate = self
        // Sfondo di marchio sotto tutta la finestra, come nella finestra principale.
        let root = NSViewController()
        root.view = NSView()
        let backdrop = NSHostingView(rootView: BrandBackground())
        root.addChild(split)
        for v in [backdrop, split.view] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.view.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            ])
        }
        w.contentViewController = root
        // Toolbar vuota e non personalizzabile: dà la barra del titolo unificata sopra la barra laterale.
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        w.setContentSize(settingsWindowSize)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("SettingsWindow")
        return w
    }

    // MARK: Chiusura con modifiche non salvate

    /// Come nei documenti delle app Mac: chiudendo con modifiche si chiede se salvarle.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty || models.dirty else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = L("Vuoi salvare le modifiche alle Impostazioni?")
        alert.informativeText = L("Se non le salvi, le modifiche andranno perse.")
        alert.addButton(withTitle: L("Salva"))
        let discard = alert.addButton(withTitle: L("Non salvare"))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: L("Annulla"))
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.saveAndClose()
            case .alertSecondButtonReturn: self?.discardAndClose()
            default: break
            }
        }
        return false
    }

    /// Salva le pagine con modifiche; se un salvataggio non riesce la finestra resta aperta
    /// sulla pagina dell'errore.
    private func saveAndClose() {
        if model.dirty {
            do {
                try model.save()
                ui.keysError = nil
            } catch {
                ui.keysError = error.localizedDescription
                nav.tab = .keys
                return
            }
        }
        guard models.dirty else { window?.close(); return }
        ui.modelsSaving = true
        Task {
            do {
                try await models.save()
                ui.modelsError = nil
                ui.modelsSaving = false
                window?.close()
            } catch {
                ui.modelsError = error.localizedDescription
                ui.modelsSaving = false
                nav.tab = .models
            }
        }
    }

    private func discardAndClose() {
        model.reload()
        models.dirty = false   // alla prossima apertura show() ricarica i modelli dal motore
        window?.close()        // close() non ripassa da windowShouldClose
    }

    /// Il motore è (ri)partito: se le Impostazioni sono aperte si ricaricano i modelli,
    /// così "Motore non pronto" non resta a schermo dopo l'avvio.
    func engineStarted() {
        guard window?.isVisible == true else { return }
        Task { await models.load() }
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil { window = makeWindow() }
        if let tab { nav.tab = tab }
        // Finestra già aperta (⌘, o "Aggiungi modelli…"): ricaricare cancellerebbe una chiave
        // appena incollata o una scelta di modelli non ancora salvata.
        // Minimizzata conta come aperta: le modifiche non salvate sono ancora lì.
        if window?.isVisible != true && window?.isMiniaturized != true {
            model.reload()
            ui.reset()
            Task { await models.load() }
        }
        window?.makeKeyAndOrderFront(nil)
        // Nessun campo attivo all'apertura: né la ricerca della barra laterale né una chiave.
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var hasAnyKey: Bool { model.configuredCount > 0 }
}
