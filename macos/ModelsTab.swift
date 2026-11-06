// Scheda "Modelli": composizione del consiglio scelta dai cataloghi dei provider.

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
}

struct SelectionDTO: Codable, Equatable {
    var auto: Bool
    var models: [SelModel]
}

struct HealthDTO: Decodable, Equatable {
    let status: String
    let using: String?
    let note: String?
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

enum CatalogSort: String, CaseIterable, Identifiable {
    case recommended = "Consigliati", recent = "Più recenti", name = "Nome"
    var id: String { rawValue }
}

// MARK: - Modello

@MainActor
final class ModelsModel: ObservableObject {
    @Published var providers: [ProviderInfo] = []
    @Published var provider = ""
    @Published var catalog: [CatalogItem] = []
    @Published var catalogError: String?
    @Published var loadingCatalog = false
    @Published var selection = SelectionDTO(auto: true, models: [])
    @Published var health: [String: HealthDTO] = [:]
    @Published var checking = false
    @Published var probes: [String: ProbeDTO] = [:]
    @Published var probing: Set<String> = []
    @Published var onlyFree = true
    @Published var sort: CatalogSort = .recommended
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
        } catch {
            engineError = "Il motore non è pronto. Riprova tra qualche secondo."
        }
    }

    func refreshHealth() async {
        guard let r = try? await get("/api/models", as: ModelsResponse.self) else { return }
        health = Dictionary(uniqueKeysWithValues: r.models.map { ($0.id, $0.health) })
        checking = r.checking ?? false
    }

    func loadCatalog(fresh: Bool = false) async {
        guard !provider.isEmpty else { catalog = []; return }
        loadingCatalog = true
        catalogError = nil
        defer { loadingCatalog = false }
        do {
            catalog = try await get("/api/catalog/\(provider)\(fresh ? "?fresh=1" : "")", as: [CatalogItem].self)
        } catch {
            catalog = []
            catalogError = error.localizedDescription
        }
    }

    var visibleCatalog: [CatalogItem] {
        var list = catalog
        if onlyFree { list = list.filter { $0.free != false } }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) } }
        switch sort {
        case .recommended: break // già ordinato dal motore
        case .recent: list.sort { ($0.created ?? 0, $0.score) > ($1.created ?? 0, $1.score) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Array(list.prefix(150))
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

    func isMember(_ item: CatalogItem) -> Bool {
        selection.models.contains { $0.provider == provider && $0.model == item.id }
    }

    func add(_ item: CatalogItem) {
        let base = "\(provider)-\(item.id)".lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        var id = base, n = 2
        while selection.models.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        let label = item.name.replacingOccurrences(of: " (free)", with: "")
        selection.models.append(SelModel(id: id, label: String(label.prefix(40)), kind: "openai",
                                         provider: provider, model: item.id, fallback: nil, default: true))
        dirty = true
    }

    func remove(_ m: SelModel) {
        selection.models.removeAll { $0.id == m.id }
        dirty = true
    }

    func addClaude() {
        guard !selection.models.contains(where: { $0.kind == "claude-cli" }) else { return }
        selection.models.insert(SelModel(id: "claude", label: "Claude", kind: "claude-cli", provider: nil,
                                         model: "sonnet", fallback: nil, default: false), at: 0)
        dirty = true
    }

    func setDefault(_ m: SelModel, _ on: Bool) {
        guard let i = selection.models.firstIndex(where: { $0.id == m.id }) else { return }
        selection.models[i].default = on
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
    }
}

struct ModelsTab: View {
    @ObservedObject var model: ModelsModel
    var close: () -> Void
    @State private var saveError: String?
    @State private var saving = false

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
                Text("\(model.selection.models.count) modelli nel consiglio").foregroundStyle(.secondary)
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

    private var councilSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.selection.auto }, set: { model.setAuto($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scelta automatica all'avvio")
                    Text("All'apertura l'app prova ogni modello. Se uno non risponde o è stato ritirato, lo sostituisce con il migliore disponibile dello stesso provider.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(model.selection.models) { m in
                let h = model.health[m.id]
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(statusColor(h?.status)).frame(width: 9, height: 9).padding(.top, 5)
                        .help(statusText(h))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label).font(.body.weight(.medium))
                        Text("\(model.providerName(m.provider)) · \(m.model)")
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
                    Toggle("Spuntato di default", isOn: Binding(get: { m.default ?? false }, set: { model.setDefault(m, $0) }))
                        .toggleStyle(.checkbox).font(.caption)
                    Button(role: .destructive) { model.remove(m) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Togli dal consiglio")
                }
            }

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
            Text("Membri del consiglio")
        }
    }

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
                    TextField("Cerca", text: $model.search, prompt: Text("Cerca un modello…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, maxWidth: .infinity)
                    Picker("Ordina", selection: $model.sort) {
                        ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Ordina il catalogo")
                    Toggle("Solo gratuiti", isOn: $model.onlyFree)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    Button { Task { await model.loadCatalog(fresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Ricarica il catalogo")
                }

                if model.loadingCatalog {
                    HStack { ProgressView().controlSize(.small); Text("Carico il catalogo…").foregroundStyle(.secondary) }
                } else if let e = model.catalogError {
                    Text("Catalogo non disponibile: \(e)").foregroundStyle(.red)
                } else if model.visibleCatalog.isEmpty {
                    Text("Nessun modello corrisponde ai filtri.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.visibleCatalog) { item in catalogRow(item) }
                }
            }
        } header: {
            Text("Aggiungi dal catalogo")
        } footer: {
            Text("“Consigliato” è una stima basata su versione, data e dimensione del modello: i provider non pubblicano una classifica. Usa “Prova” per sapere se un modello risponde davvero con il tuo account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func catalogRow(_ item: CatalogItem) -> some View {
        let key = model.probeKey(model.provider, item.id)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
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
                Button("Prova") { model.probe(item) }
            }
            if model.isMember(item) {
                Text("Nel consiglio").font(.caption).foregroundStyle(.secondary).frame(width: 82)
            } else {
                Button("Aggiungi") { model.add(item) }.frame(width: 82)
            }
        }
    }
}
