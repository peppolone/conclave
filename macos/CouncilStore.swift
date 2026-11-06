// Stato dell'interfaccia nativa: opzioni del consiglio, dibattito corrente (in diretta via SSE),
// apertura di dibattiti passati, annullamento ed esportazione. Parla solo con il motore locale.

import AppKit
import SwiftUI

// MARK: - Dati

struct VoiceInfo: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: String      // "abbonamento" per Claude
    let model: String
    let available: Bool
    let health: HealthDTO?
    var isClaude: Bool { id == "claude" }
    /// Problema da segnalare con "!" sul pulsante (nil se tutto ok).
    var problem: String? {
        guard let h = health else { return nil }
        switch h.status {
        case "down": return "Non risponde" + (h.note.map { " — \($0)" } ?? "")
        case "busy": return "Sovraccarico, riproverà" + (h.note.map { " — \($0)" } ?? "")
        default: return nil
        }
    }
}

struct CardState: Identifiable, Equatable {
    let id: String            // id della voce (o "judge:…")
    var title: String         // es. "Gemini · Risposta B"
    var text: String?
    var error: String?
    var skipped = false       // ha saltato il round ma resta nel dibattito
    var seconds: Double?
    var usedModel: String?
    var replaced: String?
    var waiting: Bool { text == nil && error == nil }
}

struct PhaseState: Identifiable, Equatable {
    let id: String            // initial / critique / revise / final
    var title: String
    var note: String?
    var cards: [CardState]
}

struct DebateState: Equatable {
    let id: Int
    var question: String
    var rounds: Int?
    var judgeLabel: String?
    var parentId: Int?
    var status: String        // running, done, failed, cancelled, interrupted
    var statusText: String
    var startedAt: Date?
    var finishedAt: Date?
    var phases: [PhaseState] = []
    var verdict: String?
    var verdictBy: String?
    var participants: [String: (label: String, letter: String)] = [:]
    var isRunning: Bool { status == "running" }

    static func == (a: DebateState, b: DebateState) -> Bool {
        a.id == b.id && a.status == b.status && a.phases == b.phases && a.verdict == b.verdict
            && a.statusText == b.statusText && a.question == b.question && a.finishedAt == b.finishedAt
    }
}

struct ParentRef: Equatable { let id: Int; let question: String }

// MARK: - Store

@MainActor
final class CouncilStore: ObservableObject {
    // Opzioni del consiglio
    @Published var voices: [VoiceInfo] = []
    @Published var selected: Set<String> = [] { didSet { persist() } }
    @Published var rounds = 3 { didSet { persist() } }
    @Published var judge = "claude" { didSet { persist() } }
    @Published var claudeModel = "sonnet" { didSet { persist() } }
    @Published var claudeModels = ["sonnet", "opus", "haiku"]
    @Published var lockedCount = 0          // voci configurate ma senza chiave API
    @Published var checking = false
    @Published var question = ""
    @Published var parent: ParentRef?
    @Published var startError: String?
    @Published var starting = false

    // Dibattito mostrato (nil = composer)
    @Published var current: DebateState?
    @Published var engineReady = false

    let port: () -> Int
    var onHistoryChanged: (() -> Void)?
    var onCurrentChanged: ((Int?) -> Void)?
    var onVerdictReady: ((_ question: String) -> Void)?

    private var stream: Task<Void, Never>?
    private var healthPoll: Task<Void, Never>?
    private var loadedPrefs = false
    private let defaults = UserDefaults.standard

    static let phaseOrder = ["initial", "critique", "revise", "final"]
    static let phaseTitles = [
        "initial": "Risposte iniziali",
        "critique": "Round 1 · Critica incrociata",
        "revise": "Round 2 · Revisione",
        "final": "Round 3 · Posizione finale",
    ]
    static let roundsTitles = [3: "3 – completo", 2: "2 – fino alla revisione", 1: "1 – solo critica", 0: "0 – solo risposte, veloce"]

    init(port: @escaping () -> Int) { self.port = port }

    // MARK: HTTP

    private func url(_ path: String) -> URL? {
        let p = port()
        return p > 0 ? URL(string: "http://127.0.0.1:\(p)\(path)") : nil
    }

    private func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        guard let u = url(path) else { throw URLError(.cannotConnectToHost) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "council", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg ?? "errore \(h.statusCode)"])
        }
        return data
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Modelli e opzioni

    /// Da chiamare quando il motore è (ri)partito.
    func engineStarted() {
        engineReady = true
        Task { await reloadModels() }
    }

    func engineStopped() {
        engineReady = false
        stream?.cancel()
    }

    func reloadModels() async {
        guard let data = try? await request("GET", "/api/models") else { return }
        let j = json(data)
        let list = (j["models"] as? [[String: Any]]) ?? []
        let all: [VoiceInfo] = list.compactMap { m in
            guard let id = m["id"] as? String, let label = m["label"] as? String else { return nil }
            var health: HealthDTO?
            if let h = m["health"], let hd = try? JSONSerialization.data(withJSONObject: h) {
                health = try? JSONDecoder().decode(HealthDTO.self, from: hd)
            }
            return VoiceInfo(id: id, label: label, provider: m["provider"] as? String ?? "",
                             model: m["model"] as? String ?? "", available: m["available"] as? Bool ?? false, health: health)
        }
        voices = all.filter(\.available)
        lockedCount = all.count - voices.count
        checking = j["checking"] as? Bool ?? false
        if let cm = j["claudeModels"] as? [String], !cm.isEmpty { claudeModels = cm }

        if !loadedPrefs {
            loadedPrefs = true
            let d = j["defaults"] as? [String: Any] ?? [:]
            let saved = defaults.stringArray(forKey: "council.selected")
            let defaultIds = list.filter { ($0["default"] as? Bool) == true }.compactMap { $0["id"] as? String }
            selected = Set(saved ?? defaultIds)
            rounds = defaults.object(forKey: "council.rounds") as? Int ?? d["rounds"] as? Int ?? 3
            judge = defaults.string(forKey: "council.judge") ?? d["judge"] as? String ?? "claude"
            claudeModel = defaults.string(forKey: "council.claudeModel") ?? d["claudeModel"] as? String ?? "sonnet"
        }
        // Scelte che non esistono più (voce rimossa o senza chiave) vengono ignorate.
        selected = selected.filter { id in voices.contains { $0.id == id } }
        if judge != "claude" && !voices.contains(where: { $0.id == judge }) { judge = "claude" }
        if !claudeModels.contains(claudeModel) { claudeModel = claudeModels.first ?? "sonnet" }

        // Durante il controllo d'avvio si aggiorna lo stato ogni pochi secondi.
        healthPoll?.cancel()
        if checking {
            healthPoll = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self?.reloadModels()
            }
        }
    }

    private func persist() {
        guard loadedPrefs else { return }
        defaults.set(Array(selected), forKey: "council.selected")
        defaults.set(rounds, forKey: "council.rounds")
        defaults.set(judge, forKey: "council.judge")
        defaults.set(claudeModel, forKey: "council.claudeModel")
    }

    func displayName(_ v: VoiceInfo) -> String { v.isClaude ? "Claude \(claudeModel.capitalized)" : v.label }

    var judgeLabel: String {
        judge == "claude" ? "Claude \(claudeModel.capitalized)" : (voices.first { $0.id == judge }?.label ?? judge)
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var orderedSelection: [String] { voices.map(\.id).filter { selected.contains($0) } }

    var canStart: Bool {
        engineReady && !starting && orderedSelection.count >= 2 && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hint: String {
        if !engineReady { return "Avvio del motore…" }
        if voices.filter({ !$0.isClaude }).isEmpty { return "Nessuna chiave gratuita configurata: aggiungila nelle Impostazioni (⌘,)." }
        let n = orderedSelection.count
        if n < 2 { return "Scegli almeno 2 partecipanti cliccandoci sopra." }
        return "Circa \(n * (1 + rounds)) chiamate ai modelli + 1 verdetto · ⌘↩ per avviare"
    }

    var subtitle: String {
        rounds == 0
            ? "I modelli rispondono in parallelo, poi \(judgeLabel) emette il verdetto."
            : "I modelli rispondono, si criticano a vicenda per \(rounds) round, poi \(judgeLabel) emette il verdetto."
    }

    // MARK: Avvio

    func start() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStart else { return }
        starting = true
        startError = nil
        defer { starting = false }
        var body: [String: Any] = ["question": q, "models": orderedSelection, "rounds": rounds,
                                   "judge": judge, "claudeModel": claudeModel]
        if let parent { body["parentId"] = parent.id }
        do {
            let data = try await request("POST", "/api/debates", body: body)
            guard let id = json(data)["id"] as? Int else { throw URLError(.badServerResponse) }
            question = ""
            parent = nil
            current = DebateState(id: id, question: q, rounds: rounds, judgeLabel: judgeLabel, parentId: body["parentId"] as? Int,
                                  status: "running", statusText: "Dibattito in corso…", startedAt: .now)
            onCurrentChanged?(id)
            onHistoryChanged?()
            listen(id)
        } catch {
            startError = error.localizedDescription
        }
    }

    // MARK: Streaming (Server-Sent Events)

    private func listen(_ id: Int) {
        stream?.cancel()
        stream = Task { [weak self] in
            guard let self, let u = self.url("/api/debates/\(id)/events") else { return }
            var req = URLRequest(url: u)
            req.timeoutInterval = 3600
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                          let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    self.apply(e, debateId: id)
                }
            } catch {
                // Connessione chiusa (fine dibattito o riavvio): si rilegge lo stato salvato.
                if !Task.isCancelled, self.current?.id == id, self.current?.isRunning == true { await self.open(id) }
            }
        }
    }

    private func apply(_ e: [String: Any], debateId: Int) {
        guard var d = current, d.id == debateId, let type = e["type"] as? String else { return }
        switch type {
        case "start":
            for p in e["participants"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String { d.participants[id] = (p["label"] as? String ?? id, p["letter"] as? String ?? "") }
            }
            if let r = e["rounds"] as? Int { d.rounds = r }
            if let j = e["judge"] as? String { d.judgeLabel = j }
            d.statusText = "Dibattito in corso…"
        case "phase":
            let phase = e["phase"] as? String ?? ""
            let note = e["note"] as? String
            if phase == "verdict" { d.statusText = "Il giudice sta valutando…"; break }
            if let i = d.phases.firstIndex(where: { $0.id == phase }) {
                if let note { d.phases[i].note = note }
            } else {
                // Le voci ancora in gioco ricevono una card in attesa.
                let active = note == nil ? activeIds(d) : []
                d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: note,
                                           cards: active.map { CardState(id: $0, title: title(for: $0, in: d)) }))
            }
            d.statusText = "\(Self.phaseTitles[phase] ?? phase)…"
        case "message":
            let phase = e["phase"] as? String ?? ""
            let modelId = e["modelId"] as? String ?? ""
            let text = e["text"] as? String ?? ""
            if phase == "verdict" {
                d.verdict = text
                d.verdictBy = judgeName(modelId.replacingOccurrences(of: "judge:", with: ""), in: d)
            } else {
                upsert(&d, phase: phase, modelId: modelId) {
                    $0.text = text
                    $0.error = nil
                    $0.seconds = (e["ms"] as? Double).map { $0 / 1000 }
                    $0.usedModel = e["model"] as? String
                    $0.replaced = e["replaced"] as? String
                }
            }
        case "error":
            let phase = e["phase"] as? String ?? ""
            let modelId = e["modelId"] as? String ?? ""
            let error = e["error"] as? String ?? "errore"
            if phase == "verdict" {
                d.statusText = "Giudice non disponibile, provo un altro modello…"
            } else {
                upsert(&d, phase: phase, modelId: modelId) {
                    $0.error = error
                    $0.skipped = error.hasPrefix("ha saltato")
                }
            }
        case "done":
            let status = e["status"] as? String ?? "done"
            d.status = status
            d.finishedAt = .now
            d.statusText = status == "done" ? "Concluso" : (e["error"] as? String ?? status)
            if status == "done" { onVerdictReady?(d.question) }
            onHistoryChanged?()
        default:
            break
        }
        current = d
    }

    /// Nome leggibile del giudice: "Claude", oppure il nome della voce.
    private func judgeName(_ id: String, in d: DebateState) -> String {
        if id == "claude" { return "Claude" }
        return d.participants[id]?.label ?? voices.first { $0.id == id }?.label ?? id
    }

    private func activeIds(_ d: DebateState) -> [String] {
        // In gioco = partecipanti che non sono stati esclusi (errore definitivo nella fase iniziale).
        let excluded = Set(d.phases.first { $0.id == "initial" }?.cards.filter { $0.error != nil }.map(\.id) ?? [])
        return d.participants.keys.sorted { (d.participants[$0]?.letter ?? "") < (d.participants[$1]?.letter ?? "") }
            .filter { !excluded.contains($0) }
    }

    private func title(for modelId: String, in d: DebateState) -> String {
        if let p = d.participants[modelId] { return p.letter.isEmpty ? p.label : "\(p.label) · Risposta \(p.letter)" }
        return voices.first { $0.id == modelId }?.label ?? modelId
    }

    private func upsert(_ d: inout DebateState, phase: String, modelId: String, _ change: (inout CardState) -> Void) {
        var pi = d.phases.firstIndex { $0.id == phase }
        if pi == nil {
            d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: nil, cards: []))
            pi = d.phases.count - 1
        }
        var ci = d.phases[pi!].cards.firstIndex { $0.id == modelId }
        if ci == nil {
            d.phases[pi!].cards.append(CardState(id: modelId, title: title(for: modelId, in: d)))
            ci = d.phases[pi!].cards.count - 1
        }
        change(&d.phases[pi!].cards[ci!])
        d.phases.sort { (Self.phaseOrder.firstIndex(of: $0.id) ?? 9) < (Self.phaseOrder.firstIndex(of: $1.id) ?? 9) }
    }

    // MARK: Apertura, nuova discussione, annullamento

    func open(_ id: Int) async {
        stream?.cancel()
        guard let data = try? await request("GET", "/api/debates/\(id)") else { return }
        let j = json(data)
        let status = j["status"] as? String ?? "done"
        let opts = j["options"] as? [String: Any]
        var d = DebateState(id: id, question: j["question"] as? String ?? "", rounds: opts?["rounds"] as? Int,
                            judgeLabel: nil, parentId: j["parent_id"] as? Int, status: status,
                            statusText: Self.statusText(status), startedAt: Self.date(j["created_at"]),
                            finishedAt: Self.date(j["finished_at"]))
        if let o = opts, let jid = o["judge"] as? String {
            d.judgeLabel = jid == "claude" ? "Claude \((o["claudeModel"] as? String ?? "sonnet").capitalized)"
                : (voices.first { $0.id == jid }?.label ?? jid)
        }
        let messages = j["messages"] as? [[String: Any]] ?? []
        if let meta = messages.first(where: { ($0["model_id"] as? String) == "_meta" }),
           let c = (meta["content"] as? String)?.data(using: .utf8),
           let parts = try? JSONSerialization.jsonObject(with: c) as? [[String: Any]] {
            for p in parts { if let pid = p["id"] as? String { d.participants[pid] = (p["label"] as? String ?? pid, p["letter"] as? String ?? "") } }
        }
        if (j["live"] as? Bool) == true {
            // Dibattito in corso: lo stream rimanda tutti gli eventi dall'inizio. Se lo si sta già
            // guardando si tiene quello che c'è (niente contenuto svuotato, lo scorrimento resta dov'è).
            if current?.id != id { current = d }
            onCurrentChanged?(id)
            listen(id)
            return
        }
        current = d
        onCurrentChanged?(id)
        for m in messages {
            let mid = m["model_id"] as? String ?? ""
            let phase = m["phase"] as? String ?? ""
            if mid == "_meta" { continue }
            if mid == "_note" {
                if let i = d.phases.firstIndex(where: { $0.id == phase }) { d.phases[i].note = m["content"] as? String }
                else { d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: m["content"] as? String, cards: [])) }
                continue
            }
            if phase == "verdict" {
                if m["content"] as? String != nil { d.verdictBy = judgeName(mid.replacingOccurrences(of: "judge:", with: ""), in: d) }
                continue
            }
            upsert(&d, phase: phase, modelId: mid) {
                $0.text = m["content"] as? String
                $0.error = m["error"] as? String
                $0.skipped = ($0.error ?? "").hasPrefix("ha saltato")
                $0.seconds = (m["ms"] as? Double).map { $0 / 1000 }
                $0.usedModel = m["model_used"] as? String
                $0.replaced = m["replaced"] as? String
            }
        }
        d.verdict = j["verdict"] as? String
        current = d
    }

    func newDiscussion() {
        stream?.cancel()
        current = nil
        parent = nil
        startError = nil
        onCurrentChanged?(nil)
    }

    func deleted(_ id: Int) {
        if current?.id == id { newDiscussion() }
    }

    func cancel() async {
        guard let id = current?.id else { return }
        _ = try? await request("POST", "/api/debates/\(id)/cancel")
    }

    /// "Approfondisci": torna al composer con il dibattito corrente come contesto.
    func deepen() {
        guard let d = current else { return }
        let p = ParentRef(id: d.id, question: d.question)
        newDiscussion()
        parent = p
    }

    // MARK: Testi ed esportazione

    static func statusText(_ s: String) -> String {
        switch s {
        case "done": return "Concluso"
        case "failed": return "Non riuscito"
        case "cancelled": return "Annullato"
        case "interrupted": return "Interrotto (motore riavviato)"
        case "running": return "Dibattito in corso…"
        default: return s
        }
    }

    private static let sqlDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func date(_ v: Any?) -> Date? { (v as? String).flatMap { sqlDate.date(from: $0) } }

    /// Riga sotto la domanda: "3 round · giudice Claude Sonnet · durata 1 min 34 s".
    func meta(_ d: DebateState) -> String {
        var parts: [String] = []
        if let r = d.rounds { parts.append(r == 0 ? "senza round" : "\(r) round") }
        if let j = d.judgeLabel { parts.append("giudice \(j)") }
        if let s = d.startedAt {
            let end = d.finishedAt ?? (d.isRunning ? Date.now : nil)
            if let end {
                let secs = max(0, Int(end.timeIntervalSince(s)))
                parts.append((d.isRunning ? "in corso da " : "durata ") + (secs >= 60 ? "\(secs / 60) min \(secs % 60) s" : "\(secs) s"))
            }
        }
        return parts.joined(separator: " · ")
    }

    func exportMarkdown() -> (filename: String, text: String)? {
        guard let d = current else { return nil }
        var out = ["# \(d.question)", "", "_\(meta(d))_", ""]
        if let v = d.verdict { out += ["## Verdetto", "", v, ""] }
        for p in d.phases {
            out += ["## \(p.title)", ""]
            if let n = p.note { out += ["_\(n)_", ""] }
            for c in p.cards {
                out += ["### \(c.title)", ""]
                out.append(c.error.map { "_\($0)_" } ?? (c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                out.append("")
            }
        }
        let slug = d.question.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ((slug.isEmpty ? "dibattito" : String(slug.prefix(60))) + ".md", out.joined(separator: "\n"))
    }
}
