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
        case "down": return L("Non risponde") + (h.note.map { " — \($0)" } ?? "")
        case "busy": return L("Sovraccarico, riproverà") + (h.note.map { " — \($0)" } ?? "")
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
    var startedAt: Date? = nil    // quando è iniziata la fase (solo in diretta): per "In attesa · 12 s"
}

/// Titolo da mostrare per una discussione: quello scritto dal giudice o, finché manca
/// (dibattito in corso, discussioni vecchie), l'inizio della domanda in poche parole.
func debateTitle(_ title: String?, question: String) -> String {
    if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
    let q = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Prima frase, se basta; altrimenti le prime parole.
    let first = q.split(omittingEmptySubsequences: true, whereSeparator: { ".?!;:".contains($0) }).first.map(String.init) ?? q
    let words = first.split(separator: " ")
    let t = words.count <= 8 ? first + (first.count < q.count && q[q.index(q.startIndex, offsetBy: first.count)] == "?" ? "?" : "")
        : words.prefix(7).joined(separator: " ") + "…"
    return t.prefix(1).uppercased() + t.dropFirst()
}

struct DebateState: Equatable {
    let id: Int
    var question: String
    var title: String?
    var displayTitle: String { debateTitle(title, question: question) }
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
    var judging = false       // il giudice sta scrivendo il verdetto
    var isRunning: Bool { status == "running" }

    static func == (a: DebateState, b: DebateState) -> Bool {
        a.id == b.id && a.status == b.status && a.phases == b.phases && a.verdict == b.verdict
            && a.statusText == b.statusText && a.question == b.question && a.title == b.title && a.finishedAt == b.finishedAt
            && a.judging == b.judging
    }
}

struct ParentRef: Equatable { let id: Int; let question: String }

// MARK: - Store

@MainActor
final class CouncilStore: ObservableObject {
    // Opzioni del consiglio
    @Published var voices: [VoiceInfo] = []
    // Ogni preferenza si salva da sola, e solo per scelta dell'utente (non durante `syncing`).
    @Published var selected: Set<String> = [] { didSet { persistSelected() } }
    @Published var rounds = 3 { didSet { persist(rounds, "council.rounds") } }
    @Published var judge = "claude" { didSet { persist(judge, "council.judge") } }
    @Published var claudeModel = "sonnet" { didSet { persist(claudeModel, "council.claudeModel") } }
    /// true mentre si allineano le scelte ai modelli disponibili: un modello che all'avvio
    /// non risponde ancora sparisce dalla scelta mostrata, ma non da quella salvata.
    private var syncing = false
    /// Voci predefinite del motore: la scelta iniziale quando l'utente non ne ha ancora salvata una.
    private var defaultIds: [String] = []
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

    /// Round aperti/chiusi scelti dall'utente, per dibattito (restano finché l'app è aperta).
    var expandedPhases: [Int: [String: Bool]] = [:]

    private var stream: Task<Void, Never>?
    /// Dibattiti in corso non più mostrati: se ne attende la fine in background.
    private var watchers: [Int: Task<Void, Never>] = [:]
    private var openSeq = 0
    private var healthPoll: Task<Void, Never>?
    private var loadedPrefs = false
    private let defaults = UserDefaults.standard

    static let phaseOrder = ["initial", "critique", "revise", "final"]
    static let phaseTitles = [
        "initial": L("Risposte iniziali"),
        "critique": L("Round 1 · Critica incrociata"),
        "revise": L("Round 2 · Revisione"),
        "final": L("Round 3 · Posizione finale"),
    ]
    static let roundsTitles = [3: L("3 – completo"), 2: L("2 – fino alla revisione"), 1: L("1 – solo critica"), 0: L("0 – solo risposte, veloce")]

    init(port: @escaping () -> Int) { self.port = port }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await Engine.call(port(), method, path, body: data, timeout: 30)
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
        // Il riavvio interrompe anche i dibattiti seguiti in background.
        for w in watchers.values { w.cancel() }
        watchers = [:]
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

        // Le scelte salvate sono la fonte: ogni scelta dell'utente si salva subito, quindi a ogni
        // ricarica si ripartono da lì (una voce tornata disponibile torna scelta). Quelle che ora
        // non esistono (voce rimossa, senza chiave o non pronta) vengono ignorate senza salvarlo.
        syncing = true
        let d = j["defaults"] as? [String: Any] ?? [:]
        defaultIds = list.filter { ($0["default"] as? Bool) == true }.compactMap { $0["id"] as? String }
        selected = Set(defaults.stringArray(forKey: "council.selected") ?? defaultIds)
            .filter { id in voices.contains { $0.id == id } }
        rounds = defaults.object(forKey: "council.rounds") as? Int ?? d["rounds"] as? Int ?? 3
        judge = defaults.string(forKey: "council.judge") ?? d["judge"] as? String ?? "claude"
        if judge != "claude" && !voices.contains(where: { $0.id == judge }) { judge = "claude" }
        claudeModel = defaults.string(forKey: "council.claudeModel") ?? d["claudeModel"] as? String ?? "sonnet"
        if !claudeModels.contains(claudeModel) { claudeModel = claudeModels.first ?? "sonnet" }
        syncing = false
        loadedPrefs = true

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

    private func persist(_ value: Any, _ key: String) {
        guard loadedPrefs, !syncing else { return }
        defaults.set(value, forKey: key)
    }

    /// Salva la scelta tenendo le voci salvate che ora non sono disponibili (l'utente non può
    /// averle tolte: non sono mostrate), così tornano scelte quando il modello torna.
    private func persistSelected() {
        guard loadedPrefs, !syncing else { return }
        let hidden = (defaults.stringArray(forKey: "council.selected") ?? defaultIds).filter { id in !voices.contains { $0.id == id } }
        defaults.set(Array(selected.union(hidden)).sorted(), forKey: "council.selected")
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

    /// Chiamate previste ai modelli (verdetto escluso): una per partecipante a ogni fase.
    var estimatedCalls: Int { orderedSelection.count * (1 + rounds) }

    /// true quando la stima ha senso (motore pronto, almeno due partecipanti).
    var canEstimate: Bool {
        engineReady && voices.contains { !$0.isClaude } && orderedSelection.count >= 2
    }

    var hint: String {
        if !engineReady { return L("Avvio del motore…") }
        if voices.filter({ !$0.isClaude }).isEmpty { return L("Nessuna chiave gratuita configurata: aggiungila nelle Impostazioni (⌘,).") }
        let n = orderedSelection.count
        if n < 2 { return L("Scegli almeno 2 partecipanti cliccandoci sopra.") }
        return String(format: L("Circa %d chiamate ai modelli + 1 verdetto · ⌘↩ per avviare"), estimatedCalls)
    }

    var subtitle: String {
        rounds == 0
            ? String(format: L("I modelli rispondono in parallelo, poi %@ emette il verdetto."), judgeLabel)
            : String(format: L("I modelli rispondono, si criticano a vicenda per %d round, poi %@ emette il verdetto."), rounds, judgeLabel)
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
                                  status: "running", statusText: Self.statusText("running"), startedAt: .now)
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
        watchers.removeValue(forKey: id)?.cancel()
        stream = Task { [weak self] in
            guard let self, let u = Engine.url(self.port(), "/api/debates/\(id)/events") else { return }
            let req = Engine.request(u, timeout: 3600)
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard let e = Self.event(line) else { continue }
                    self.apply(e, debateId: id)
                }
            } catch {}
            // Flusso finito senza "done" (errore, 404, riavvio): si rilegge lo stato salvato,
            // altrimenti la discussione resterebbe "in corso" per sempre.
            guard !Task.isCancelled, self.current?.id == id, self.current?.isRunning == true else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // open() annulla il flusso della discussione mostrata, cioè questo task: lo si
            // stacca prima, o la rilettura verrebbe annullata e resterebbe "in corso".
            self.stream = nil
            await self.open(id)
        }
    }

    private static func event(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Chiude il flusso della discussione mostrata; se è ancora in corso la si segue in background,
    /// così cronologia, notifica e badge arrivano anche guardando altro.
    private func leaveCurrent() {
        stream?.cancel()
        if let d = current, d.isRunning { watch(d.id, title: d.displayTitle) }
    }

    private func watch(_ id: Int, title: String) {
        guard watchers[id] == nil, let u = Engine.url(port(), "/api/debates/\(id)/events") else { return }
        watchers[id] = Task { [weak self] in
            var done: [String: Any]?
            if let (bytes, _) = try? await URLSession.shared.bytes(for: Engine.request(u, timeout: 3600)) {
                do {
                    for try await line in bytes.lines {
                        if let e = Self.event(line), e["type"] as? String == "done" { done = e; break }
                    }
                } catch {}
            }
            guard let self, !Task.isCancelled else { return }
            self.watchers[id] = nil
            if done?["status"] as? String == "done" { self.onVerdictReady?(done?["title"] as? String ?? title) }
            self.onHistoryChanged?()
        }
    }

    /// true se un dibattito è in corso, mostrato o in background.
    var hasRunning: Bool { current?.isRunning == true || !watchers.isEmpty }

    private func apply(_ e: [String: Any], debateId: Int) {
        guard var d = current, d.id == debateId, let type = e["type"] as? String else { return }
        switch type {
        case "start":
            for p in e["participants"] as? [[String: Any]] ?? [] {
                if let id = p["id"] as? String { d.participants[id] = (p["label"] as? String ?? id, p["letter"] as? String ?? "") }
            }
            if let r = e["rounds"] as? Int { d.rounds = r }
            if let j = e["judge"] as? String { d.judgeLabel = j }
            d.statusText = Self.statusText("running")
        case "phase":
            let phase = e["phase"] as? String ?? ""
            let note = e["note"] as? String
            if phase == "verdict" { d.statusText = L("Il giudice sta valutando…"); d.judging = true; break }
            if let i = d.phases.firstIndex(where: { $0.id == phase }) {
                if let note { d.phases[i].note = note }
            } else {
                // Le voci ancora in gioco ricevono una card in attesa.
                let active = note == nil ? activeIds(d) : []
                d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: note,
                                           cards: active.map { CardState(id: $0, title: title(for: $0, in: d)) },
                                           startedAt: .now))
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
            let error = e["error"] as? String ?? L("errore")
            if phase == "verdict" {
                d.statusText = L("Giudice non disponibile, provo un altro modello…")
            } else {
                upsert(&d, phase: phase, modelId: modelId) {
                    $0.error = error
                    $0.skipped = error.hasPrefix("ha saltato")
                }
            }
        case "done":
            let status = e["status"] as? String ?? "done"
            d.status = status
            d.judging = false
            d.finishedAt = .now
            d.statusText = status == "done" ? Self.statusText("done") : (e["error"] as? String ?? status)
            if let t = e["title"] as? String { d.title = t }
            if status == "done" { onVerdictReady?(d.displayTitle) }
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
        if let p = d.participants[modelId] { return p.letter.isEmpty ? p.label : String(format: L("%@ · Risposta %@"), p.label, p.letter) }
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
        if current?.id == id { stream?.cancel() } else { leaveCurrent() }
        // Due aperture ravvicinate: vale solo l'ultima richiesta, anche se risponde prima l'altra.
        openSeq += 1
        let seq = openSeq
        guard let data = try? await request("GET", "/api/debates/\(id)"), seq == openSeq else { return }
        let j = json(data)
        let status = j["status"] as? String ?? "done"
        let opts = j["options"] as? [String: Any]
        var d = DebateState(id: id, question: j["question"] as? String ?? "", rounds: opts?["rounds"] as? Int,
                            judgeLabel: nil, parentId: j["parent_id"] as? Int, status: status,
                            statusText: Self.statusText(status), startedAt: Self.date(j["created_at"]),
                            finishedAt: Self.date(j["finished_at"]))
        d.title = j["title"] as? String
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
        // Si pubblica una sola volta, a contenuto completo: uno stato intermedio vuoto farebbe
        // tornare in cima la vista del dibattito già aperto (riconnessione, Ricarica).
        if current?.id != id { current = d }
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
        leaveCurrent()
        openSeq += 1
        current = nil
        parent = nil
        startError = nil
        onCurrentChanged?(nil)
    }

    func deleted(_ id: Int) {
        watchers.removeValue(forKey: id)?.cancel()
        guard current?.id == id else { return }
        // Niente da seguire in background: la discussione non esiste più.
        stream?.cancel()
        current = nil
        newDiscussion()
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
        case "done": return L("Concluso")
        case "failed": return L("Non riuscito")
        case "cancelled": return L("Annullato")
        case "interrupted": return L("Interrotto (motore riavviato)")
        case "running": return L("Dibattito in corso…")
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
        metaItems(d).map(\.text).joined(separator: " · ")
    }

    /// Round, giudice e durata, ciascuno con il simbolo da mostrare nell'intestazione.
    func metaItems(_ d: DebateState) -> [(symbol: String, text: String)] {
        var parts: [(symbol: String, text: String)] = []
        if let r = d.rounds { parts.append(("arrow.triangle.2.circlepath", r == 0 ? L("senza round") : (r == 1 ? L("1 round") : String(format: L("%d round"), r)))) }
        if let j = d.judgeLabel { parts.append(("person.fill.checkmark", String(format: L("giudice %@"), j))) }
        if let s = d.startedAt {
            let end = d.finishedAt ?? (d.isRunning ? Date.now : nil)
            if let end {
                let secs = max(0, Int(end.timeIntervalSince(s)))
                let dur = secs >= 60 ? String(format: L("%d min %d s"), secs / 60, secs % 60) : String(format: L("%d s"), secs)
                parts.append(("clock", String(format: d.isRunning ? L("in corso da %@") : L("durata %@"), dur)))
            }
        }
        return parts
    }

    func exportMarkdown() -> (filename: String, text: String)? {
        guard let d = current else { return nil }
        var out = ["# \(d.displayTitle)", "", "> " + d.question.replacingOccurrences(of: "\n", with: "\n> "), "", "_\(meta(d))_", ""]
        if let v = d.verdict { out += ["## " + L("Verdetto"), "", v, ""] }
        for p in d.phases {
            out += ["## \(p.title)", ""]
            if let n = p.note { out += ["_\(n)_", ""] }
            for c in p.cards {
                out += ["### \(c.title)", ""]
                out.append(c.error.map { "_\($0)_" } ?? (c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                out.append("")
            }
        }
        let slug = d.displayTitle.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ((slug.isEmpty ? L("dibattito") : String(slug.prefix(60))) + ".md", out.joined(separator: "\n"))
    }
}

// MARK: - Fasi del dibattito (intestazioni dei round, passi, avanzamento)

enum StepState: Equatable {
    case done, current, pending, skipped, notRun, stopped
}

struct DebateStep: Identifiable, Equatable {
    let id: String            // initial / critique / revise / final / verdict
    let short: String         // nome breve per la riga dei passi
    let heading: String       // "Round 1 di 3 · Critica incrociata"
    let state: StepState
}

extension CouncilStore {
    static let phaseShortNames = [
        "initial": L("Risposte"), "critique": L("Critica"), "revise": L("Revisione"),
        "final": L("Posizione finale"), "verdict": L("Verdetto"),
    ]
    static let phaseNames = [
        "initial": L("Risposte iniziali"), "critique": L("Critica incrociata"), "revise": L("Revisione"),
        "final": L("Posizione finale"), "verdict": L("Verdetto"),
    ]
    static let phaseDescriptions = [
        "initial": L("Ogni modello risponde alla domanda da solo, senza vedere le risposte degli altri."),
        "critique": L("Ogni modello legge le risposte anonime degli altri e ne indica errori e punti deboli."),
        "revise": L("Ogni modello rivede la propria risposta tenendo conto delle critiche ricevute."),
        "final": L("Ogni modello confronta le risposte riviste e dichiara la sua posizione definitiva."),
        "verdict": L("Il giudice legge le posizioni finali e scrive il verdetto."),
    ]

    /// Numero di round del dibattito (0–3).
    func roundCount(_ d: DebateState) -> Int {
        d.rounds ?? max(0, d.phases.filter { $0.id != "initial" }.count)
    }

    /// Intestazione numerata della fase: "Apertura · Risposte iniziali", "Round 2 di 3 · Revisione".
    func phaseHeading(_ id: String, in d: DebateState) -> String {
        let name = Self.phaseNames[id] ?? id
        switch id {
        case "initial": return String(format: L("Apertura · %@"), name)
        case "verdict": return String(format: L("Chiusura · %@"), name)
        default:
            guard let i = Self.phaseOrder.firstIndex(of: id) else { return name }
            return String(format: L("Round %d di %d · %@"), i, max(roundCount(d), i), name)
        }
    }

    /// Riga sopra il nome della fase: "Apertura", "Round 2 di 3", "Chiusura".
    func phaseEyebrow(_ id: String, in d: DebateState) -> String {
        switch id {
        case "initial": return L("Apertura")
        case "verdict": return L("Chiusura")
        default:
            guard let i = Self.phaseOrder.firstIndex(of: id) else { return "" }
            return String(format: L("Round %d di %d"), i, max(roundCount(d), i))
        }
    }

    /// Stato di una fase già comparsa nel dibattito.
    func phaseState(_ p: PhaseState, in d: DebateState) -> StepState {
        if p.cards.isEmpty && p.note != nil { return .skipped }
        if p.cards.contains(where: \.waiting) { return d.isRunning ? .current : .stopped }
        return .done
    }

    /// Passi del dibattito in ordine: risposte, round previsti, verdetto.
    func steps(_ d: DebateState) -> [DebateStep] {
        let ids = ["initial"] + Array(Self.phaseOrder.dropFirst().prefix(roundCount(d))) + ["verdict"]
        var out: [DebateStep] = []
        for (k, id) in ids.enumerated() {
            let laterStarted = ids[(k + 1)...].contains { later in
                later == "verdict" ? (d.judging || d.verdict != nil) : d.phases.contains { $0.id == later }
            }
            let state: StepState
            if id == "verdict" {
                if d.verdict != nil { state = .done }
                else if d.isRunning { state = d.judging ? .current : .pending }
                else { state = d.status == "done" ? .done : .notRun }
            } else if let p = d.phases.first(where: { $0.id == id }) {
                state = phaseState(p, in: d)
            } else if laterStarted || d.status == "done" {
                state = .skipped
            } else {
                state = d.isRunning ? .pending : .notRun
            }
            out.append(DebateStep(id: id, short: Self.phaseShortNames[id] ?? id,
                                  heading: phaseHeading(id, in: d), state: state))
        }
        return out
    }

    /// Avanzamento complessivo: risposte arrivate (o concluse con errore) su risposte attese, verdetto compreso.
    func progress(_ d: DebateState) -> (done: Int, total: Int) {
        let active = activeCount(d)
        var done = 0, total = 0
        for s in steps(d) where s.id != "verdict" {
            if let p = d.phases.first(where: { $0.id == s.id }) {
                total += p.cards.count
                done += p.cards.filter { !$0.waiting }.count
            } else if s.state == .pending {
                total += active
            }
        }
        total += 1
        if d.verdict != nil { done += 1 }
        return (min(done, total), max(total, 1))
    }

    /// Partecipanti ancora in gioco (esclusi quelli che hanno fallito la risposta iniziale).
    func activeCount(_ d: DebateState) -> Int {
        let excluded = Set(d.phases.first { $0.id == "initial" }?.cards.filter { $0.error != nil }.map(\.id) ?? [])
        return d.participants.keys.filter { !excluded.contains($0) }.count
    }
}
