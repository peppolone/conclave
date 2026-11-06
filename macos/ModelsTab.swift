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
        guard let id else { return "Abbonamento Claude Pro" }
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

private func statusColor(_ s: String?) -> Color {
    switch s {
    case "ok": return .green
    case "busy", "checking": return .orange
    case "down", "quota", "gone", "auth", "error": return .red
    default: return .secondary
    }
}

private func statusText(_ h: HealthDTO?) -> String {
    switch h?.status {
    case "ok": return "Risponde"
    case "checking": return "Verifica in corso…"
    case "busy": return "Sovraccarico"
    case "down": return "Non risponde"
    case "nokey": return "Manca la chiave"
    default: return "Non verificato"
    }
}

private func probeText(_ p: ProbeDTO) -> String {
    switch p.status {
    case "ok": return "Risponde · \(String(format: "%.1f", Double(p.ms) / 1000)) s"
    case "busy": return "Sovraccarico ora, riprova più tardi"
    case "quota": return "Non incluso nel piano gratuito / quota esaurita"
    case "gone": return "Non disponibile per il tuo account"
    case "auth": return "Chiave non valida"
    default: return p.message ?? "Errore"
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

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
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
                VStack(spacing: 12) {
                    Text(err).foregroundStyle(.secondary)
                    Button("Riprova") { Task { await model.load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    councilSection
                    catalogSection
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                let n = model.selection.models.count
                Text(n == 1 ? "1 voce nel consiglio" : "\(n) voci nel consiglio").foregroundStyle(.secondary)
                if let saveError { Text(saveError).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("Annulla") { Task { await model.load() }; close() }
                    .keyboardShortcut(.cancelAction)
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
            .padding(14)
        }
    }

    // MARK: Voci del consiglio

    private var councilSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.selection.auto }, set: { model.setAuto($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scelta automatica all'avvio")
                    Text("All'apertura l'app prova ogni voce. Se un modello non risponde o è stato ritirato, passa a un'altra variante della stessa famiglia.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(model.selection.models) { m in voiceRow(m) }

            HStack {
                if !model.selection.models.contains(where: { $0.kind == "claude-cli" }) {
                    Button("Aggiungi Claude") { model.addClaude() }
                }
                Spacer()
                if model.checking {
                    ProgressView().controlSize(.small)
                    Text("Verifica dei modelli in corso…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Aggiorna stato") { Task { await model.refreshHealth() } }
                    .buttonStyle(.borderless)
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voci del consiglio")
                Text("Ogni voce è una famiglia di modelli. Con «Automatico» l'app usa il migliore disponibile e, se non risponde, passa da sola a un'altra variante della stessa famiglia.")
                    .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(statusColor(h?.status)).frame(width: 9, height: 9).padding(.top, 5)
                    .help(statusText(h))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.label).font(.body.weight(.medium))
                    Text(voiceDetail(m, h))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let note = h?.note {
                        Text(note).font(.caption).foregroundStyle(h?.status == "ok" ? Color.orange : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if h?.status == "nokey" {
                        Text("Manca la chiave API: aggiungila nella scheda “Chiavi API”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) { model.remove(m) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Togli dal consiglio")
            }
            HStack(spacing: 8) {
                Text("Modello").foregroundStyle(.secondary)
                modelPicker(m)
                Spacer()
                Toggle("Spuntato di default", isOn: Binding(get: { m.default ?? false }, set: { model.setDefault(m, $0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(.leading, 19)
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
        Section {
            let withKey = model.providers.filter(\.hasKey)
            if withKey.isEmpty {
                Text("Nessun provider configurato. Aggiungi una chiave nella scheda “Chiavi API”.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $model.provider) {
                    ForEach(withKey) { p in Text(p.name).tag(p.id) }
                }
                .onChange(of: model.provider) { _, _ in Task { await model.loadCatalog() } }

                // Etichette nascoste dentro la Form: altrimenti occupano una colonna e il testo va a capo.
                HStack(spacing: 12) {
                    TextField("Cerca", text: $model.search, prompt: Text("Cerca una famiglia o un modello…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, maxWidth: .infinity)
                    Toggle("Solo gratuiti", isOn: $model.onlyFree)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    Button { Task { await model.loadCatalog(fresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Ricarica il catalogo")
                }

                let families = model.visibleFamilies
                if model.loadingCatalog {
                    HStack { ProgressView().controlSize(.small); Text("Carico il catalogo…").foregroundStyle(.secondary) }
                } else if let e = model.catalogError {
                    Text("Catalogo non disponibile: \(e)").foregroundStyle(.red)
                } else if families.isEmpty {
                    Text("Nessuna famiglia corrisponde ai filtri.").foregroundStyle(.secondary)
                } else {
                    ForEach(families) { f in familyRow(f) }
                }
            }
        } header: {
            Text("Aggiungi una voce")
        } footer: {
            Text("“Consigliato” è una stima basata su versione, data e dimensione del modello: i provider non pubblicano una classifica. Usa “Prova” per sapere se un modello risponde davvero con il tuo account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func familyRow(_ f: ModelFamily) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(f.label).font(.body.weight(.medium)).lineLimit(1)
                        if f.best.recommended { Badge(text: "★ Consigliato", color: .blue) }
                        if f.items.contains(where: { $0.free == true }) {
                            Badge(text: "Gratis", color: .green)
                        } else if f.items.allSatisfy({ $0.free == false }) {
                            Badge(text: "A pagamento", color: .red)
                        } else {
                            Badge(text: "Da verificare", color: .orange)
                        }
                    }
                    Text("\(f.items.count == 1 ? "1 modello" : "\(f.items.count) modelli") · migliore: \(f.best.name)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isVoice(f) {
                    Text("Nel consiglio").font(.caption).foregroundStyle(.secondary).fixedSize().frame(minWidth: 82)
                } else {
                    Button("Aggiungi") { model.addFamily(f) }.fixedSize().frame(minWidth: 82)
                }
            }
            DisclosureGroup("Mostra i modelli", isExpanded: Binding(
                get: { expanded.contains("\(model.provider)/\(f.id)") },
                set: { on in
                    let k = "\(model.provider)/\(f.id)"
                    if on { expanded.insert(k) } else { expanded.remove(k) }
                })) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(f.items) { item in variantRow(item) }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func variantRow(_ item: CatalogItem) -> some View {
        let key = model.probeKey(model.provider, item.id)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body).lineLimit(1)
                    if item.recommended { Badge(text: "★ Consigliato", color: .blue) }
                    switch item.free {
                    case .some(true): Badge(text: "Gratis", color: .green)
                    case .some(false): Badge(text: "A pagamento", color: .red)
                    case .none: Badge(text: "Da verificare", color: .orange)
                    }
                }
                Text([item.id, dateText(item.created), shortContext(item.context)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let note = item.freeNote {
                    Text(note).font(.caption).foregroundStyle(item.free == false ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = model.probes[key] {
                    Label(probeText(p), systemImage: p.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(statusColor(p.status))
                }
            }
            .help(item.description ?? item.freeNote ?? "")
            Spacer()
            if model.probing.contains(key) {
                ProgressView().controlSize(.small)
            } else {
                Button("Prova") { model.probe(item) }.fixedSize()
            }
        }
    }
}
