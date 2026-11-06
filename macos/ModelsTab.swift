// Scheda "Modelli": il consiglio è fatto di voci, una per famiglia di modelli
// (Claude, Gemini, GPT-OSS, Qwen…). Per ogni voce il modello è "Automatico"
// (il motore sceglie il migliore che risponde, le altre varianti fanno da riserva)
// oppure un modello fisso scelto dall'utente.

import AppKit
import SwiftUI

// MARK: - Dati scambiati con il motore

struct CatalogItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let created: Double?
    let context: Int?
    let free: Bool?
    let freeNote: String?
    let description: String?
    let score: Double
    let recommended: Bool
    let family: String?
    let familyLabel: String?
}

struct ProviderInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let hasKey: Bool
}

struct SelModel: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var kind: String
    var provider: String?
    var model: String
    var fallback: [String]?
    var `default`: Bool?
    var family: String?
}

struct SelectionDTO: Codable, Equatable {
    var auto: Bool
    var models: [SelModel]
}

struct HealthDTO: Decodable, Equatable {
    let status: String
    let using: String?
    let note: String?
    let chain: [String]?
}

private struct ModelsResponse: Decodable {
    struct Item: Decodable { let id: String; let health: HealthDTO }
    let models: [Item]
    let checking: Bool?
}

struct ProbeDTO: Decodable, Equatable {
    let status: String
    let ms: Int
    let message: String?
}

/// Una famiglia di modelli di un provider, ricavata dal catalogo.
struct ModelFamily: Identifiable {
    let id: String          // valore di `family`
    let label: String
    let items: [CatalogItem] // in ordine di score decrescente: il primo è il migliore
    var best: CatalogItem { items[0] }
    var isFree: Bool { items.contains { $0.free != false } }
}

let autoModel = "auto"
let claudeVariants: [(id: String, name: String)] = [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

private func familyKey(_ item: CatalogItem) -> String { item.family ?? item.id }

// MARK: - Modello

@MainActor
final class ModelsModel: ObservableObject {
    @Published var providers: [ProviderInfo] = []
    @Published var provider = ""
    @Published var catalogs: [String: [CatalogItem]] = [:]
    @Published var catalogError: String?
    @Published var loadingCatalog = false
    @Published var selection = SelectionDTO(auto: true, models: [])
    @Published var health: [String: HealthDTO] = [:]
    @Published var checking = false
    @Published var probes: [String: ProbeDTO] = [:]
    @Published var probing: Set<String> = []
    @Published var onlyFree = true
    @Published var search = ""
    @Published var dirty = false
    @Published var engineError: String?

    let port: () -> Int
    var onSaved: (() -> Void)?

    init(port: @escaping () -> Int) { self.port = port }

    private func url(_ path: String) -> URL? {
        let p = port()
        return p > 0 ? URL(string: "http://127.0.0.1:\(p)\(path)") : nil
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let u = url(path) else { throw URLError(.cannotConnectToHost) }
        let (data, resp) = try await URLSession.shared.data(from: u)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "council", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg ?? "errore \(h.statusCode)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: Data) async throws -> Data {
        guard let u = url(path) else { throw URLError(.cannotConnectToHost) }
        var req = URLRequest(url: u, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "council", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg ?? "errore \(h.statusCode)"])
        }
        return data
    }

    func load() async {
        engineError = nil
        do {
            providers = try await get("/api/providers", as: [ProviderInfo].self)
            selection = try await get("/api/selection", as: SelectionDTO.self)
            dirty = false
            await refreshHealth()
            if provider.isEmpty || !providers.contains(where: { $0.id == provider && $0.hasKey }) {
                provider = providers.first(where: \.hasKey)?.id ?? ""
            }
            await loadCatalog()
            // Cataloghi dei provider usati dalle voci: servono ai menu "Modello".
            let used = Set(selection.models.compactMap(\.provider))
            for p in used where p != provider && providers.contains(where: { $0.id == p && $0.hasKey }) {
                await ensureCatalog(p)
            }
        } catch {
            engineError = "Il motore non è pronto. Riprova tra qualche secondo."
        }
    }

    func refreshHealth() async {
        guard let r = try? await get("/api/models", as: ModelsResponse.self) else { return }
        health = Dictionary(r.models.map { ($0.id, $0.health) }, uniquingKeysWith: { a, _ in a })
        checking = r.checking ?? false
    }

    /// "Aggiorna stato": il motore riprova davvero ogni voce; si rilegge lo stato finché il controllo è in corso.
    func recheckHealth() async {
        _ = try? await send("POST", "/api/health", body: Data("{}".utf8))
        for _ in 0..<45 {
            await refreshHealth()
            if !checking { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Catalogo del provider scelto nella sezione "Aggiungi una voce".
    var catalog: [CatalogItem] { catalogs[provider] ?? [] }

    func loadCatalog(fresh: Bool = false) async {
        guard !provider.isEmpty else { return }
        let p = provider
        loadingCatalog = true
        catalogError = nil
        defer { loadingCatalog = false }
        do {
            catalogs[p] = try await get("/api/catalog/\(p)\(fresh ? "?fresh=1" : "")", as: [CatalogItem].self)
        } catch {
            if catalogs[p] == nil { catalogs[p] = [] }
            catalogError = error.localizedDescription
        }
    }

    /// Carica (una volta sola) il catalogo di un provider, senza mostrare errori.
    func ensureCatalog(_ p: String) async {
        guard catalogs[p] == nil else { return }
        if let list = try? await get("/api/catalog/\(p)", as: [CatalogItem].self) { catalogs[p] = list }
    }

    /// Famiglie del provider scelto, filtrate, ordinate per score del modello migliore.
    var visibleFamilies: [ModelFamily] {
        var order: [String] = []
        var groups: [String: [CatalogItem]] = [:]
        for item in catalog {
            let k = familyKey(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        var list = order.map { k -> ModelFamily in
            let items = groups[k]!.sorted { $0.score > $1.score }
            return ModelFamily(id: k, label: items.first?.familyLabel ?? items[0].name, items: items)
        }
        if onlyFree { list = list.filter(\.isFree) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { f in
                f.label.lowercased().contains(q) || f.id.lowercased().contains(q)
                    || f.items.contains { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
            }
        }
        list.sort { $0.best.score > $1.best.score }
        return list
    }

    /// Varianti di una famiglia nel catalogo di un provider (per il menu "Modello" di una voce).
    func variants(provider p: String?, family: String?) -> [CatalogItem] {
        guard let p, let family else { return [] }
        return (catalogs[p] ?? []).filter { familyKey($0) == family }
    }

    func modelName(_ id: String, provider p: String?) -> String {
        if p == nil { return claudeVariants.first { $0.id == id }?.name ?? id }
        return catalogs[p ?? ""]?.first { $0.id == id }?.name ?? id
    }

    func probeKey(_ provider: String, _ model: String) -> String { "\(provider)/\(model)" }

    func probe(_ item: CatalogItem) {
        let key = probeKey(provider, item.id)
        probing.insert(key)
        let prov = provider
        Task {
            defer { probing.remove(key) }
            let body = try? JSONSerialization.data(withJSONObject: ["provider": prov, "model": item.id])
            if let data = try? await send("POST", "/api/probe", body: body ?? Data()),
               let r = try? JSONDecoder().decode(ProbeDTO.self, from: data) {
                probes[key] = r
            } else {
                probes[key] = ProbeDTO(status: "error", ms: 0, message: "motore non raggiungibile")
            }
        }
    }

    func isVoice(_ f: ModelFamily) -> Bool {
        selection.models.contains { $0.provider == provider && $0.family == f.id }
    }

    func addFamily(_ f: ModelFamily) {
        guard !isVoice(f) else { return }
        let clean = { (s: String) in s.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression) }
        let base = clean(f.id)
        var id = base
        if selection.models.contains(where: { $0.id == id }) { id = "\(base)-\(clean(provider))" }
        let alt = id
        var n = 2
        while selection.models.contains(where: { $0.id == id }) { id = "\(alt)-\(n)"; n += 1 }
        selection.models.append(SelModel(id: id, label: String(f.label.prefix(40)), kind: "openai",
                                         provider: provider, model: autoModel, fallback: nil,
                                         default: true, family: f.id))
        dirty = true
        Task { await ensureCatalog(provider) }
    }

    func remove(_ m: SelModel) {
        selection.models.removeAll { $0.id == m.id }
        dirty = true
    }

    func addClaude() {
        guard !selection.models.contains(where: { $0.kind == "claude-cli" }) else { return }
        selection.models.insert(SelModel(id: "claude", label: "Claude", kind: "claude-cli", provider: nil,
                                         model: "sonnet", fallback: nil, default: false, family: nil), at: 0)
        dirty = true
    }

    func setDefault(_ m: SelModel, _ on: Bool) {
        guard let i = selection.models.firstIndex(where: { $0.id == m.id }) else { return }
        selection.models[i].default = on
        dirty = true
    }

    func setModel(_ m: SelModel, _ value: String) {
        guard let i = selection.models.firstIndex(where: { $0.id == m.id }), selection.models[i].model != value else { return }
        selection.models[i].model = value
        dirty = true
    }

    func setAuto(_ on: Bool) {
        selection.auto = on
        dirty = true
    }

    func providerName(_ id: String?) -> String {
        guard let id else { return "Abbonamento Claude (Claude Code)" }
        return providers.first { $0.id == id }?.name ?? id
    }

    func save() async throws {
        let data = try JSONEncoder().encode(selection)
        _ = try await send("PUT", "/api/selection", body: data)
        dirty = false
        onSaved?()
    }
}

// MARK: - Interfaccia

/// Simbolo e colore di uno stato: il colore sta solo sul simbolo, il significato nel testo.
private func statusSymbol(_ s: String?) -> (String, Color) {
    switch s {
    case "ok": return ("checkmark.circle.fill", .green)
    case "checking": return ("clock", .secondary)
    case "busy": return ("hourglass", .orange)
    case "nokey": return ("key", .secondary)
    case "down", "quota", "gone", "auth", "error": return ("xmark.circle.fill", .red)
    default: return ("circle.dashed", .secondary)
    }
}

private func statusText(_ h: HealthDTO?) -> String {
    switch h?.status {
    case "ok": return "Risponde"
    case "checking": return "Verifica in corso"
    case "busy": return "Sovraccarico"
    case "down": return "Non risponde"
    case "quota": return "Quota esaurita"
    case "gone": return "Ritirato dal provider"
    case "auth": return "Chiave non valida"
    case "error": return "Errore"
    case "nokey": return "Manca la chiave"
    default: return "Non verificato"
    }
}

private func probeText(_ p: ProbeDTO) -> String {
    switch p.status {
    case "ok": return "Risponde in \(String(format: "%.1f", Double(p.ms) / 1000)) s"
    case "busy": return "Sovraccarico ora, riprova più tardi"
    case "quota": return "Non incluso nel piano gratuito o quota esaurita"
    case "gone": return "Non disponibile per il tuo account"
    case "auth": return "Chiave non valida"
    default: return "Non risponde: \(p.message ?? "errore sconosciuto")"
    }
}

private func shortContext(_ n: Int?) -> String? {
    guard let n, n > 0 else { return nil }
    return n >= 1_000_000 ? "\(n / 1_000_000)M token" : "\(n / 1000)k token"
}

private func dateText(_ s: Double?) -> String? {
    guard let s, s > 0 else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = "MMM yyyy"
    return f.string(from: Date(timeIntervalSince1970: s))
}

/// Stato con simbolo + testo.
private struct StatusLabel: View {
    let text: String
    let status: String?
    var body: some View {
        let (symbol, color) = statusSymbol(status)
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .fixedSize()
    }
}

/// Etichetta di contenuto del catalogo: testo sempre presente, sfondo neutro, colore solo sul simbolo.
struct Badge: View {
    enum Kind { case free, paid, unknown, recommended }
    let kind: Kind

    private var text: String {
        switch kind {
        case .free: return "Gratis"
        case .paid: return "A pagamento"
        case .unknown: return "Costo da verificare"
        case .recommended: return "Consigliato"
        }
    }

    private var symbol: (String, Color) {
        switch kind {
        case .free: return ("gift", .green)
        case .paid: return ("creditcard", .orange)
        case .unknown: return ("questionmark.circle", .secondary)
        case .recommended: return ("star.fill", .accentColor)
        }
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol.0).foregroundStyle(symbol.1).imageScale(.small)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(.fill.tertiary, in: Capsule())
        .fixedSize()
    }

    static func cost(_ free: Bool?) -> Badge {
        switch free {
        case .some(true): return Badge(kind: .free)
        case .some(false): return Badge(kind: .paid)
        case .none: return Badge(kind: .unknown)
        }
    }
}

/// Campo di ricerca nativo (NSSearchField), con la lente e il pulsante per svuotarlo.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.setAccessibilityLabel(prompt)
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        f.target = context.coordinator
        f.action = #selector(Coordinator.changed(_:))
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

struct ModelsTab: View {
    @ObservedObject var model: ModelsModel
    var close: () -> Void
    @State private var saveError: String?
    @State private var saving = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.engineError {
                ContentUnavailableView {
                    Label("Motore non pronto", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("Riprova") { Task { await model.load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsPage("Modelli") {
                    councilSection
                    catalogSection
                }
            }
            SettingsBar {
                let n = model.selection.models.count
                Text(n == 1 ? "1 voce nel consiglio" : "\(n) voci nel consiglio").foregroundStyle(.secondary)
                if let saveError {
                    Text(saveError).foregroundStyle(.red).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                // Senza Esc: nel campo di ricerca Esc deve solo svuotarlo.
                Button("Annulla") { Task { await model.load() }; close() }
                Button(saving ? "Salvataggio…" : "Salva e attiva") {
                    saving = true
                    Task {
                        do { try await model.save(); close() } catch { saveError = error.localizedDescription }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.dirty || saving)
            }
        }
    }

    // MARK: Voci del consiglio

    private var councilSection: some View {
        SettingsSection("Voci del consiglio", footer: "Ogni voce è una famiglia di modelli. Con “Automatico” l'app usa la variante migliore che risponde e tiene le altre come riserva. “Partecipa di default” la preseleziona nelle nuove discussioni.") {
            ForEach(model.selection.models) { m in voiceRow(m) }

            HStack(spacing: 8) {
                if !model.selection.models.contains(where: { $0.kind == "claude-cli" }) {
                    Button("Aggiungi Claude") { model.addClaude() }
                }
                Spacer()
                if model.checking {
                    ProgressView().controlSize(.small)
                    Text("Verifica dei modelli in corso…").foregroundStyle(.secondary)
                }
                Button("Aggiorna stato") { Task { await model.recheckHealth() } }
            }

            SettingsRow("Scelta automatica all'avvio",
                        detail: "All'apertura l'app prova ogni voce; se un modello non risponde o è stato ritirato, passa a un'altra variante della stessa famiglia.") {
                Toggle("Scelta automatica all'avvio", isOn: Binding(get: { model.selection.auto }, set: { model.setAuto($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private func voiceDetail(_ m: SelModel, _ h: HealthDTO?) -> String {
        var parts = [model.providerName(m.provider)]
        let inUse = h?.using ?? h?.chain?.first ?? (m.model == autoModel ? nil : m.model)
        if let inUse { parts.append("In uso: \(model.modelName(inUse, provider: m.provider))") }
        let reserves = (h?.chain?.count ?? 0) - 1
        if reserves > 0 { parts.append(reserves == 1 ? "1 riserva" : "\(reserves) riserve") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func voiceRow(_ m: SelModel) -> some View {
        let h = model.health[m.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.label).font(.headline)
                    Text(voiceDetail(m, h))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                StatusLabel(text: statusText(h), status: h?.status)
            }
            if let note = h?.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if h?.status == "nokey" {
                Text("Aggiungi la chiave API nel pannello “Chiavi API”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Modello")
                modelPicker(m)
                Spacer()
                Toggle("Partecipa di default", isOn: Binding(get: { m.default ?? false }, set: { model.setDefault(m, $0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Button("Rimuovi", role: .destructive) { model.remove(m) }
                    .help("Togli \(m.label) dal consiglio")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rimuovi dal consiglio", role: .destructive) { model.remove(m) }
        }
    }

    @ViewBuilder
    private func modelPicker(_ m: SelModel) -> some View {
        let binding = Binding(get: { m.model }, set: { model.setModel(m, $0) })
        if m.kind == "claude-cli" {
            Picker("Modello", selection: binding) {
                ForEach(claudeVariants, id: \.id) { Text($0.name).tag($0.id) }
                if !claudeVariants.contains(where: { $0.id == m.model }) { Text(m.model).tag(m.model) }
            }
            .labelsHidden().fixedSize()
        } else {
            let variants = model.variants(provider: m.provider, family: m.family)
            Picker("Modello", selection: binding) {
                Text("Automatico (consigliato)").tag(autoModel)
                if !variants.isEmpty { Divider() }
                ForEach(variants) { Text($0.name).tag($0.id) }
                // Modello fisso non (più) presente nel catalogo: resta selezionabile.
                if m.model != autoModel && !variants.contains(where: { $0.id == m.model }) {
                    Text(m.model).tag(m.model)
                }
            }
            .labelsHidden().fixedSize()
        }
    }

    // MARK: Aggiungi una voce

    private var catalogSection: some View {
        SettingsSection("Aggiungi una voce", footer: "I modelli “Gratis” non costano nulla: con “Mostra solo modelli gratuiti” attivo vedi solo quelli. “Consigliato” è una stima basata su versione, data e dimensione del modello; usa “Prova” per sapere se un modello risponde davvero con il tuo account.") {
            let withKey = model.providers.filter(\.hasKey)
            if withKey.isEmpty {
                Label {
                    Text("Nessun provider configurato. Aggiungi una chiave gratuita nel pannello “Chiavi API”.")
                } icon: {
                    Image(systemName: "key").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            } else {
                SettingsRow("Provider") {
                    Picker("Provider", selection: $model.provider) {
                        ForEach(withKey) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.provider) { _, _ in Task { await model.loadCatalog() } }
                }

                SettingsRow("Cerca") {
                    NativeSearchField(text: $model.search, prompt: "Cerca una famiglia o un modello")
                        .frame(width: 280)
                }

                SettingsRow("Mostra solo modelli gratuiti") {
                    Toggle("Mostra solo modelli gratuiti", isOn: $model.onlyFree)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                let families = model.visibleFamilies
                HStack(spacing: 8) {
                    if model.loadingCatalog {
                        ProgressView().controlSize(.small)
                        Text("Carico i modelli di \(model.providerName(model.provider))…").foregroundStyle(.secondary)
                    } else if let e = model.catalogError {
                        Label {
                            Text("Catalogo non disponibile: \(e)").textSelection(.enabled)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    } else {
                        Text(families.count == 1 ? "1 famiglia" : "\(families.count) famiglie")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ricarica catalogo") { Task { await model.loadCatalog(fresh: true) } }
                        .disabled(model.loadingCatalog)
                }

                if !model.loadingCatalog && model.catalogError == nil {
                    if families.isEmpty {
                        Text("Nessuna famiglia corrisponde alla ricerca o ai filtri.").foregroundStyle(.secondary)
                    } else {
                        ForEach(families) { f in familyRow(f) }
                    }
                }
            }
        }
    }

    private func familyCost(_ f: ModelFamily) -> Badge {
        if f.items.contains(where: { $0.free == true }) { return Badge(kind: .free) }
        if f.items.allSatisfy({ $0.free == false }) { return Badge(kind: .paid) }
        return Badge(kind: .unknown)
    }

    @ViewBuilder
    private func familyRow(_ f: ModelFamily) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(f.label).font(.headline).lineLimit(1)
                        familyCost(f)
                        if f.best.recommended { Badge(kind: .recommended) }
                    }
                    Text("Migliore: \(f.best.name)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isVoice(f) {
                    Label {
                        Text("Nel consiglio")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .foregroundStyle(.secondary).fixedSize()
                } else {
                    Button("Aggiungi") { model.addFamily(f) }
                        .help("Aggiungi \(f.label) come voce del consiglio")
                        .fixedSize()
                }
            }
            DisclosureGroup(f.items.count == 1 ? "Mostra il modello" : "Mostra i \(f.items.count) modelli",
                            isExpanded: Binding(
                get: { expanded.contains("\(model.provider)/\(f.id)") },
                set: { on in
                    let k = "\(model.provider)/\(f.id)"
                    if on { expanded.insert(k) } else { expanded.remove(k) }
                })) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(f.items) { item in variantRow(item) }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func variantRow(_ item: CatalogItem) -> some View {
        let key = model.probeKey(model.provider, item.id)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    Badge.cost(item.free)
                    if item.recommended { Badge(kind: .recommended) }
                }
                Text([item.id, dateText(item.created), shortContext(item.context)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let note = item.freeNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = model.probes[key] {
                    StatusLabel(text: probeText(p), status: p.status == "ok" ? "ok" : (p.status == "busy" ? "busy" : "error"))
                        .font(.caption)
                }
            }
            .help(item.description ?? item.freeNote ?? "")
            Spacer()
            if model.probing.contains(key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Prova in corso").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Prova") { model.probe(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Manda una richiesta minima per vedere se risponde con il tuo account")
            }
        }
    }
}
