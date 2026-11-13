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
    var status: String        // running, done, failed, cancelled, interrupted
    var statusText: String
    var startedAt: Date?
    var finishedAt: Date?
    var phases: [PhaseState] = []
    var verdict: String?
    var verdictBy: String?
    var participants: [String: (label: String, letter: String)] = [:]
    var judging = false       // il giudice sta scrivendo il verdetto
    var attachments: [AttachmentMeta] = []
    var webSearch = false     // richiesta la ricerca sul web prima del dibattito
    /// Giudice della discussione (id della voce o "claude") e modello Claude scelto.
    var judgeId: String?
    var judgeModel: String?
    /// Turno: 0 = dibattito originale; 1, 2, … = domande di seguito nella stessa discussione.
    var turn = 0
    /// Solo turni ≥ 1: "quick" (risponde un modello) o "council" (il consiglio ridiscute).
    var mode: String?
    /// Risposta rapida del turno (modo "quick").
    var answer: CardState?
    /// Domande di seguito (turni ≥ 1), in ordine; solo nella discussione principale.
    var turns: [DebateState] = []
    var isRunning: Bool { status == "running" }
    var isQuick: Bool { mode == "quick" }
    /// true se il motore sta lavorando su questa discussione: dibattito originale o domanda di seguito.
    var busy: Bool { isRunning || turns.contains(where: \.isRunning) }

    static func == (a: DebateState, b: DebateState) -> Bool {
        a.id == b.id && a.status == b.status && a.phases == b.phases && a.verdict == b.verdict
            && a.statusText == b.statusText && a.question == b.question && a.title == b.title && a.finishedAt == b.finishedAt
            && a.judging == b.judging && a.attachments == b.attachments && a.webSearch == b.webSearch
            && a.verdictBy == b.verdictBy && a.turn == b.turn && a.mode == b.mode && a.answer == b.answer && a.turns == b.turns
    }
}

/// Dove vanno gli allegati: composer (nuova discussione) o campo in fondo alla discussione.
enum DraftTarget { case composer, followup }

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
    @Published var webSearch = false { didSet { persist(webSearch, "council.webSearch") } }
    /// Ricerca sul web possibile (`GET /api/models` → `webSearch`) e chi la farebbe.
    @Published var webSearchAvailable = false
    @Published var webSearchVia: String?
    /// true mentre si allineano le scelte ai modelli disponibili: un modello che all'avvio
    /// non risponde ancora sparisce dalla scelta mostrata, ma non da quella salvata.
    private var syncing = false
    /// Voci predefinite del motore: la scelta iniziale quando l'utente non ne ha ancora salvata una.
    private var defaultIds: [String] = []
    @Published var claudeModels = ["sonnet", "opus", "haiku"]
    @Published var lockedCount = 0          // voci configurate ma senza chiave API
    @Published var checking = false
    @Published var question = ""
    @Published var startError: String?
    @Published var starting = false
    /// File allegati alla prossima domanda e ultimo avviso sugli allegati (limite, file non supportato).
    @Published var attachments: [AttachmentItem] = []
    @Published var attachmentNotice: String?

    // Domanda di seguito: campo fisso in fondo alla discussione (stile chat di Claude).
    @Published var followup = ""
    @Published var followupAttachments: [AttachmentItem] = []
    @Published var followupNotice: String?
    @Published var followupError: String?
    @Published var sendingFollowup = false
    /// "quick" (risposta rapida di un modello) o "council" (rilancia il consiglio).
    @Published var followupMode = "quick" { didSet { persist(followupMode, "council.followupMode") } }
    /// Chi dà la risposta rapida: "" = giudice della discussione, "claude:<modello>" o "voice:<id>".
    @Published var responder = "" { didSet { persist(responder, "council.responder") } }
    @Published var followupWebSearch = false { didSet { persist(followupWebSearch, "council.followupWebSearch") } }

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

    /// Fasi dei round: la posizione è il numero del round (0 = risposte iniziali).
    static let phaseOrder = ["initial", "critique", "revise", "final"]
    /// Ordine di visualizzazione: la ricerca sul web precede le risposte.
    static let phaseSort = ["research"] + phaseOrder
    static let phaseTitles = [
        "research": L("Ricerca sul web"),
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
        let ws = j["webSearch"] as? [String: Any]
        webSearchAvailable = ws?["available"] as? Bool ?? false
        webSearchVia = ws?["via"] as? String

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
        webSearch = defaults.bool(forKey: "council.webSearch")
        followupMode = defaults.string(forKey: "council.followupMode") == "council" ? "council" : "quick"
        responder = defaults.string(forKey: "council.responder") ?? ""
        followupWebSearch = defaults.bool(forKey: "council.followupWebSearch")
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
            && !questionTooLong && attachmentProblem == nil
    }

    /// Lunghezza della domanda come la conta il motore (unità UTF-16).
    var questionLength: Int { question.utf16.count }
    var questionTooLong: Bool { questionLength > AttachmentLimits.maxQuestion }

    /// Motivo per cui gli allegati impediscono l'avvio (nil se si può partire).
    var attachmentProblem: String? { Self.problem(of: attachments) }

    /// Motivo per cui gli allegati indicati impediscono l'invio (nil se vanno bene).
    static func problem(of items: [AttachmentItem]) -> String? {
        if items.contains(where: \.loading) { return L("Attendi la lettura degli allegati.") }
        if items.contains(where: { $0.error != nil }) { return L("Togli gli allegati che non si possono leggere.") }
        let total = items.reduce(0) { $0 + $1.chars }
        if total > AttachmentLimits.maxTotal {
            return String(format: L("Allegati troppo lunghi: %@ caratteri in tutto, al massimo %@. Togline qualcuno."),
                          formatCount(total), formatCount(AttachmentLimits.maxTotal))
        }
        return nil
    }

    /// Allegati pronti nel formato del motore, con i metadati da mostrare.
    private static func payload(_ items: [AttachmentItem]) -> (body: [[String: String]], meta: [AttachmentMeta]) {
        let sent = items.compactMap { a in a.text.map { (a, $0) } }
        return (sent.map { ["name": $0.0.name, "kind": $0.0.kind.rawValue, "text": $0.1] },
                sent.map { AttachmentMeta(name: $0.0.name, kind: $0.0.kind, chars: $0.0.chars) })
    }

    /// Ricerca sul web richiesta e possibile: è ciò che si invia al motore.
    var webSearchActive: Bool { webSearch && webSearchAvailable }

    /// Spiegazione dell'interruttore "Cerca sul web".
    var webSearchHelp: String {
        guard webSearchAvailable else {
            return L("Ricerca sul web non disponibile: nessun modello configurato può cercare sul web.")
        }
        let via = webSearchVia.map { String(format: L("La ricerca la fa %@"), $0) } ?? ""
        return L("Prima del dibattito un modello cerca sul web informazioni aggiornate e le passa a tutti i partecipanti.")
            + (via.isEmpty ? "" : " " + via + ".")
    }

    // MARK: Allegati

    /// Allegati e avviso del riquadro indicato (composer o campo della domanda di seguito).
    private func paths(_ t: DraftTarget) -> (items: ReferenceWritableKeyPath<CouncilStore, [AttachmentItem]>,
                                             notice: ReferenceWritableKeyPath<CouncilStore, String?>) {
        t == .composer ? (\.attachments, \.attachmentNotice) : (\.followupAttachments, \.followupNotice)
    }

    /// Aggiunge file come allegati e ne legge il testo in background.
    func addAttachments(_ urls: [URL], to target: DraftTarget = .composer) {
        let (items, notice) = paths(target)
        self[keyPath: notice] = nil
        var skipped: [String] = []
        for url in urls {
            guard self[keyPath: items].count < AttachmentLimits.maxFiles else {
                self[keyPath: notice] = String(format: L("Al massimo %d allegati: gli altri file non sono stati aggiunti."), AttachmentLimits.maxFiles)
                break
            }
            guard let kind = AttachmentReader.kind(of: url) else { skipped.append(url.lastPathComponent); continue }
            let item = AttachmentItem(name: String(url.lastPathComponent.prefix(AttachmentLimits.maxName)), kind: kind)
            self[keyPath: items].append(item)
            load(item.id, items) { try AttachmentReader.read(url, kind: kind) }
        }
        if !skipped.isEmpty, self[keyPath: notice] == nil {
            self[keyPath: notice] = String(format: L("Tipo di file non supportato: %@. Si possono allegare PDF, file di testo e immagini."),
                                           skipped.joined(separator: ", "))
        }
    }

    /// Immagine incollata dagli appunti: se ne riconosce il testo.
    func addPastedImage(_ data: Data, to target: DraftTarget = .composer) {
        let (items, notice) = paths(target)
        self[keyPath: notice] = nil
        guard self[keyPath: items].count < AttachmentLimits.maxFiles else {
            self[keyPath: notice] = String(format: L("Al massimo %d allegati: gli altri file non sono stati aggiunti."), AttachmentLimits.maxFiles)
            return
        }
        let item = AttachmentItem(name: L("Immagine incollata"), kind: .image)
        self[keyPath: items].append(item)
        load(item.id, items) { try AttachmentReader.readImage(data) }
    }

    func removeAttachment(_ id: UUID, from target: DraftTarget = .composer) {
        let (items, notice) = paths(target)
        self[keyPath: items].removeAll { $0.id == id }
        self[keyPath: notice] = nil
    }

    private func load(_ id: UUID, _ items: ReferenceWritableKeyPath<CouncilStore, [AttachmentItem]>,
                      _ read: @escaping @Sendable () throws -> String) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try read() } }.value
            guard let self, let i = self[keyPath: items].firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let text):
                let cut = AttachmentReader.truncate(text, to: AttachmentLimits.maxChars)
                self[keyPath: items][i].text = cut
                self[keyPath: items][i].truncated = cut.utf16.count < text.utf16.count
            case .failure(let e):
                self[keyPath: items][i].error = e.localizedDescription
            }
        }
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
        let sent = Self.payload(attachments)
        if !sent.body.isEmpty { body["attachments"] = sent.body }
        let web = webSearchActive
        if web { body["webSearch"] = true }
        do {
            let data = try await request("POST", "/api/debates", body: body)
            guard let id = json(data)["id"] as? Int else { throw URLError(.badServerResponse) }
            question = ""
            attachments = []
            attachmentNotice = nil
            var d = DebateState(id: id, question: q, rounds: rounds, judgeLabel: judgeLabel,
                                status: "running", statusText: Self.statusText("running"), startedAt: .now)
            d.attachments = sent.meta
            d.webSearch = web
            d.judgeId = judge
            d.judgeModel = claudeModel
            current = d
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
            guard !Task.isCancelled, self.current?.id == id, self.current?.busy == true else { return }
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
        if let d = current, d.busy { watch(d.id, title: d.displayTitle, turn: d.turns.last(where: \.isRunning)?.turn ?? 0) }
    }

    /// `turn`: turno in corso da attendere (0 = dibattito originale).
    private func watch(_ id: Int, title: String, turn: Int = 0) {
        guard watchers[id] == nil, let u = Engine.url(port(), "/api/debates/\(id)/events") else { return }
        watchers[id] = Task { [weak self] in
            var done: [String: Any]?
            // Il flusso può ripetere gli eventi dei turni già conclusi: conta solo la fine dell'ultimo.
            var lastTurn = turn
            if let (bytes, _) = try? await URLSession.shared.bytes(for: Engine.request(u, timeout: 3600)) {
                do {
                    for try await line in bytes.lines {
                        guard let e = Self.event(line) else { continue }
                        let n = e["turn"] as? Int ?? 0
                        if e["type"] as? String == "turn" { lastTurn = max(lastTurn, n) }
                        if e["type"] as? String == "done", n >= lastTurn { done = e; break }
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
    var hasRunning: Bool { current?.busy == true || !watchers.isEmpty }

    private func apply(_ e: [String: Any], debateId: Int) {
        guard var d = current, d.id == debateId, let type = e["type"] as? String else { return }
        let n = e["turn"] as? Int ?? 0
        if type == "turn" {
            // Inizio di una domanda di seguito: di solito il turno c'è già (aggiunto all'invio).
            guard n > 0, !d.turns.contains(where: { $0.turn == n }) else { return }
            d.turns.append(newTurn(d, n: n, question: e["question"] as? String ?? "",
                                   mode: e["mode"] as? String == "council" ? "council" : "quick"))
            d.turns.sort { $0.turn < $1.turn }
            current = d
            return
        }
        if n == 0 {
            // Eventi ripetuti di un dibattito originale già concluso: niente da aggiornare
            // (né notifiche doppie).
            guard d.isRunning else { return }
            applyEvent(type, e, to: &d)
            if type == "done" {
                if let t = e["title"] as? String { d.title = t }
                if d.status == "done" { onVerdictReady?(d.displayTitle) }
                onHistoryChanged?()
            }
        } else {
            if !d.turns.contains(where: { $0.turn == n }) {
                // Evento "turn" perso: il turno si ricostruisce dagli eventi che seguono.
                d.turns.append(newTurn(d, n: n, question: "", mode: e["phase"] as? String == "answer" ? "quick" : "council"))
                d.turns.sort { $0.turn < $1.turn }
            }
            guard let i = d.turns.firstIndex(where: { $0.turn == n }), d.turns[i].isRunning else { return }
            applyEvent(type, e, to: &d.turns[i])
            if type == "done" {
                if d.turns[i].status == "done" { onVerdictReady?(d.displayTitle) }
                onHistoryChanged?()
            }
        }
        current = d
    }

    /// Turno n di una discussione, appena iniziato.
    private func newTurn(_ d: DebateState, n: Int, question: String, mode: String) -> DebateState {
        var t = DebateState(id: d.id, question: question, rounds: mode == "council" ? d.rounds : nil,
                            judgeLabel: mode == "council" ? d.judgeLabel : nil, status: "running",
                            statusText: mode == "quick" ? L("Risposta in corso…") : Self.statusText("running"), startedAt: .now)
        t.turn = n
        t.mode = mode
        if mode == "council" { t.participants = d.participants }
        return t
    }

    /// Applica un evento del flusso al dibattito originale o a un turno di seguito.
    private func applyEvent(_ type: String, _ e: [String: Any], to d: inout DebateState) {
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
            if phase == "answer" {
                if d.answer == nil { d.answer = CardState(id: "answer", title: L("Risposta rapida")) }
                d.statusText = L("Risposta in corso…")
                break
            }
            if let i = d.phases.firstIndex(where: { $0.id == phase }) {
                if let note { d.phases[i].note = note }
            } else {
                // Le voci ancora in gioco ricevono una card in attesa; la ricerca ne ha una sola.
                let active = note != nil ? [] : phase == "research" ? ["research"] : activeIds(d)
                d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: note,
                                           cards: active.map { CardState(id: $0, title: title(for: $0, in: d)) },
                                           startedAt: .now))
                d.phases.sort { Self.sortIndex($0.id) < Self.sortIndex($1.id) }
            }
            d.statusText = "\(Self.phaseTitles[phase] ?? phase)…"
        case "message":
            let phase = e["phase"] as? String ?? ""
            let modelId = e["modelId"] as? String ?? ""
            let text = e["text"] as? String ?? ""
            if phase == "verdict" {
                d.verdict = text
                d.verdictBy = judgeName(modelId.replacingOccurrences(of: "judge:", with: ""), in: d)
            } else if phase == "answer" {
                setAnswer(&d, modelId: modelId) {
                    $0.text = text
                    $0.error = nil
                    $0.seconds = (e["ms"] as? Double).map { $0 / 1000 }
                    $0.usedModel = e["model"] as? String
                    $0.replaced = e["replaced"] as? String
                }
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
            } else if phase == "answer" {
                setAnswer(&d, modelId: modelId) { $0.error = error }
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
            d.statusText = status == "done" ? Self.statusText("done") : (e["error"] as? String ?? Self.statusText(status))
        default:
            break
        }
    }

    /// Aggiorna la risposta rapida del turno; il titolo dice chi ha risposto.
    private func setAnswer(_ d: inout DebateState, modelId: String, _ change: (inout CardState) -> Void) {
        let id = modelId.replacingOccurrences(of: "judge:", with: "")
        var card = d.answer ?? CardState(id: "answer", title: L("Risposta rapida"))
        if !id.isEmpty { card.title = String(format: L("Risposta rapida · %@"), judgeName(id, in: d)) }
        change(&card)
        d.answer = card
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
        if modelId == "research" { return L("Ricerca sul web") }
        if modelId.hasPrefix("research:") {
            let id = String(modelId.dropFirst(9))
            let name = id == "claude" ? "Claude" : d.participants[id]?.label ?? voices.first { $0.id == id }?.label ?? id
            return String(format: L("Ricerca sul web · %@"), name)
        }
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
        if ci == nil, phase == "research" {
            // La card in attesa della ricerca ("research") lascia il posto all'esito di chi l'ha fatta.
            d.phases[pi!].cards.removeAll { $0.waiting }
        }
        if ci == nil {
            d.phases[pi!].cards.append(CardState(id: modelId, title: title(for: modelId, in: d)))
            ci = d.phases[pi!].cards.count - 1
        }
        change(&d.phases[pi!].cards[ci!])
        d.phases.sort { Self.sortIndex($0.id) < Self.sortIndex($1.id) }
    }

    static func sortIndex(_ phase: String) -> Int { phaseSort.firstIndex(of: phase) ?? 9 }

    // MARK: Apertura, nuova discussione, annullamento

    func open(_ id: Int) async {
        if current?.id == id { stream?.cancel() } else { leaveCurrent() }
        // Due aperture ravvicinate: vale solo l'ultima richiesta, anche se risponde prima l'altra.
        openSeq += 1
        let seq = openSeq
        guard let data = try? await request("GET", "/api/debates/\(id)"), seq == openSeq else { return }
        let j = json(data)
        let status = j["status"] as? String ?? "done"
        let live = (j["live"] as? Bool) == true
        let opts = j["options"] as? [String: Any]
        var d = DebateState(id: id, question: j["question"] as? String ?? "", rounds: opts?["rounds"] as? Int,
                            judgeLabel: nil, status: status,
                            statusText: Self.statusText(status), startedAt: Self.date(j["created_at"]),
                            finishedAt: Self.date(j["finished_at"]))
        d.title = j["title"] as? String
        d.webSearch = opts?["webSearch"] as? Bool ?? false
        if let o = opts, let jid = o["judge"] as? String {
            d.judgeId = jid
            d.judgeModel = o["claudeModel"] as? String
            d.judgeLabel = jid == "claude" ? "Claude \((o["claudeModel"] as? String ?? "sonnet").capitalized)"
                : (voices.first { $0.id == jid }?.label ?? jid)
        }
        let messages = j["messages"] as? [[String: Any]] ?? []
        // Messaggi per turno: 0 = dibattito originale, poi le domande di seguito.
        let byTurn = Dictionary(grouping: messages) { $0["turn"] as? Int ?? 0 }
        let lastTurn = byTurn.keys.max() ?? 0
        if live && lastTurn == 0 {
            readMeta(byTurn[0] ?? [], into: &d)
            // Dibattito in corso: lo stream rimanda tutti gli eventi dall'inizio. Se lo si sta già
            // guardando si tiene quello che c'è (niente contenuto svuotato, lo scorrimento resta dov'è).
            if current?.id != id { switchDraft(to: id); current = d }
            onCurrentChanged?(id)
            listen(id)
            return
        }
        if live, current?.id == id, current?.turns.last?.turn == lastTurn, current?.turns.last?.isRunning == true {
            // Domanda di seguito già mostrata dal vivo: si riprende il flusso senza toccare la vista.
            onCurrentChanged?(id)
            listen(id)
            return
        }
        if lastTurn > 0 {
            // Con domande di seguito lo stato della discussione è quello dell'ultimo turno:
            // il dibattito originale si è concluso (con verdetto) o si era fermato prima.
            d.status = j["verdict"] as? String != nil ? "done" : "cancelled"
            d.statusText = Self.statusText(d.status)
        }
        // Si pubblica una sola volta, a contenuto completo: uno stato intermedio vuoto farebbe
        // tornare in cima la vista del dibattito già aperto (riconnessione, Ricarica).
        if current?.id != id { switchDraft(to: id); current = d }
        onCurrentChanged?(id)
        fill(&d, byTurn[0] ?? [])
        d.verdict = j["verdict"] as? String
        if lastTurn > 0 {
            for n in 1...lastTurn {
                guard let msgs = byTurn[n] else { continue }
                var t = newTurn(d, n: n, question: "", mode: "quick")
                t.participants = d.participants
                t.startedAt = Self.date(msgs.first?["created_at"])
                t.status = n < lastTurn ? (Self.hasResult(msgs) ? "done" : "failed") : (live ? "running" : status)
                t.statusText = t.isRunning ? t.statusText : Self.statusText(t.status)
                // Turno in corso: le risposte le rimanda il flusso, dalla cronologia solo domanda e opzioni.
                fill(&t, msgs, onlyHeader: t.isRunning)
                // Senza opzioni salvate il modo si riconosce dalle fasi.
                if t.answer == nil, t.verdict != nil || t.phases.contains(where: { $0.id != "research" }) {
                    t.mode = "council"
                }
                d.turns.append(t)
            }
        }
        current = d
        if live { listen(id) }
    }

    /// true se il turno ha almeno una risposta o un verdetto.
    private static func hasResult(_ msgs: [[String: Any]]) -> Bool {
        msgs.contains { m in
            let mid = m["model_id"] as? String ?? ""
            return !mid.hasPrefix("_") && (m["content"] as? String).map { !$0.isEmpty } == true
        }
    }

    /// Partecipanti, opzioni del turno e allegati dai messaggi tecnici (`_meta`, `_attachments`, `_user`).
    private func readMeta(_ msgs: [[String: Any]], into d: inout DebateState) {
        for m in msgs {
            let mid = m["model_id"] as? String ?? ""
            let content = m["content"] as? String ?? ""
            switch mid {
            case "_user":
                d.question = content
            case "_meta":
                guard let c = content.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: c) else { continue }
                if let parts = v as? [[String: Any]] {
                    for p in parts { if let pid = p["id"] as? String { d.participants[pid] = (p["label"] as? String ?? pid, p["letter"] as? String ?? "") } }
                } else if let o = v as? [String: Any], d.turn > 0 {
                    // Opzioni della domanda di seguito: {"mode","rounds","judge","webSearch"}.
                    d.mode = o["mode"] as? String == "council" ? "council" : "quick"
                    d.webSearch = o["webSearch"] as? Bool ?? false
                    if d.mode == "council" {
                        if d.isRunning { d.statusText = Self.statusText("running") }
                        if let r = o["rounds"] as? Int { d.rounds = r }
                        if let jid = o["judge"] as? String {
                            d.judgeLabel = jid == "claude" ? "Claude" : (voices.first { $0.id == jid }?.label ?? jid)
                        }
                    } else {
                        d.rounds = nil
                        d.judgeLabel = nil
                        d.statusText = d.isRunning ? L("Risposta in corso…") : d.statusText
                    }
                }
            case "_attachments":
                guard let c = content.data(using: .utf8),
                      let list = try? JSONSerialization.jsonObject(with: c) as? [[String: Any]] else { continue }
                d.attachments = list.compactMap { a in
                    guard let name = a["name"] as? String else { return nil }
                    return AttachmentMeta(name: name, kind: AttachmentKind(rawValue: a["kind"] as? String ?? "") ?? .text,
                                          chars: a["chars"] as? Int ?? 0)
                }
            default:
                break
            }
        }
    }

    /// Riempie un turno (o il dibattito originale) con i messaggi salvati.
    private func fill(_ d: inout DebateState, _ msgs: [[String: Any]], onlyHeader: Bool = false) {
        readMeta(msgs, into: &d)
        if onlyHeader { return }
        for m in msgs {
            let mid = m["model_id"] as? String ?? ""
            let phase = m["phase"] as? String ?? ""
            if ["_meta", "_attachments", "_user"].contains(mid) { continue }
            if mid == "_note" {
                if let i = d.phases.firstIndex(where: { $0.id == phase }) { d.phases[i].note = m["content"] as? String }
                else { d.phases.append(PhaseState(id: phase, title: Self.phaseTitles[phase] ?? phase, note: m["content"] as? String, cards: [])) }
                continue
            }
            let change: (inout CardState) -> Void = {
                $0.text = m["content"] as? String
                $0.error = m["error"] as? String
                $0.skipped = ($0.error ?? "").hasPrefix("ha saltato")
                $0.seconds = (m["ms"] as? Double).map { $0 / 1000 }
                $0.usedModel = m["model_used"] as? String
                $0.replaced = m["replaced"] as? String
            }
            if phase == "verdict" {
                if let v = m["content"] as? String {
                    d.verdictBy = judgeName(mid.replacingOccurrences(of: "judge:", with: ""), in: d)
                    // Il verdetto del dibattito originale arriva da `debates.verdict`.
                    if d.turn > 0 { d.verdict = v }
                }
                continue
            }
            if phase == "answer" {
                setAnswer(&d, modelId: mid, change)
                continue
            }
            upsert(&d, phase: phase, modelId: mid, change)
        }
        d.phases.sort { Self.sortIndex($0.id) < Self.sortIndex($1.id) }
    }

    func newDiscussion() {
        leaveCurrent()
        switchDraft(to: nil)
        openSeq += 1
        current = nil
        startError = nil
        onCurrentChanged?(nil)
    }

    func deleted(_ id: Int) {
        watchers.removeValue(forKey: id)?.cancel()
        drafts[id] = nil
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

    // MARK: Domanda di seguito (chat continua dopo il verdetto)

    /// Bozze del campo in fondo, per discussione: cambiando discussione non si perdono né si
    /// mandano alla discussione sbagliata.
    private var drafts: [Int: (text: String, attachments: [AttachmentItem])] = [:]

    /// Mette da parte la bozza della discussione mostrata e carica quella di `id`.
    private func switchDraft(to id: Int?) {
        if let old = current?.id {
            let ready = followupAttachments.filter { !$0.loading }
            drafts[old] = followup.isEmpty && ready.isEmpty ? nil : (followup, ready)
        }
        let next = id.flatMap { drafts[$0] }
        followup = next?.text ?? ""
        followupAttachments = next?.attachments ?? []
        followupNotice = nil
        followupError = nil
    }

    /// Si può continuare la discussione: dibattito originale concluso con un verdetto o almeno una risposta.
    func canFollowUp(_ d: DebateState) -> Bool {
        !d.isRunning && (d.verdict != nil || d.phases.contains { p in p.id != "research" && p.cards.contains { $0.text != nil } })
    }

    var followupLength: Int { followup.utf16.count }
    var followupTooLong: Bool { followupLength > AttachmentLimits.maxQuestion }
    var followupAttachmentProblem: String? { Self.problem(of: followupAttachments) }
    var followupWebSearchActive: Bool { followupWebSearch && webSearchAvailable }

    /// Partecipanti del dibattito originale ancora disponibili, per rilanciare il consiglio.
    func councilModels(_ d: DebateState) -> [String] {
        d.participants.keys.sorted { (d.participants[$0]?.letter ?? "") < (d.participants[$1]?.letter ?? "") }
            .filter { id in voices.contains { $0.id == id } }
    }

    /// Giudice della discussione, se ancora disponibile; altrimenti Claude.
    func discussionJudge(_ d: DebateState) -> (id: String, claudeModel: String, label: String) {
        let jid = d.judgeId ?? judge
        if jid != "claude", let v = voices.first(where: { $0.id == jid }) { return (v.id, claudeModel, v.label) }
        let m = jid == "claude" ? (d.judgeModel ?? claudeModel) : claudeModel
        return ("claude", m, "Claude \(m.capitalized)")
    }

    /// Chi dà la risposta rapida: scelta dell'utente o, in mancanza, il giudice della discussione.
    func quickResponder(_ d: DebateState) -> (id: String, claudeModel: String, label: String) {
        if responder.hasPrefix("claude:") {
            let m = String(responder.dropFirst(7))
            if claudeModels.contains(m) { return ("claude", m, "Claude \(m.capitalized)") }
        } else if responder.hasPrefix("voice:"), let v = voices.first(where: { $0.id == String(responder.dropFirst(6)) }) {
            return (v.id, claudeModel, v.label)
        }
        return discussionJudge(d)
    }

    /// Motivo per cui non si può inviare la domanda di seguito (nil se si può, o se manca solo il testo).
    func followupProblem(_ d: DebateState) -> String? {
        if followupTooLong {
            return String(format: L("La domanda supera il limite di %@ caratteri: accorciala per inviarla."), formatCount(AttachmentLimits.maxQuestion))
        }
        if let p = followupAttachmentProblem { return p }
        if followupMode == "council" && councilModels(d).count < 2 {
            return L("Per rilanciare il consiglio servono almeno 2 partecipanti della discussione ancora disponibili.")
        }
        return nil
    }

    var canSendFollowup: Bool {
        guard let d = current, engineReady, !sendingFollowup, !d.busy, canFollowUp(d), followupProblem(d) == nil else { return false }
        return !followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Invia la domanda di seguito: risposta rapida di un modello o nuovo giro del consiglio.
    func sendFollowup() async {
        guard canSendFollowup, let d = current else { return }
        let q = followup.trimmingCharacters(in: .whitespacesAndNewlines)
        let council = followupMode == "council"
        sendingFollowup = true
        followupError = nil
        defer { sendingFollowup = false }
        let who = quickResponder(d), judgeOf = discussionJudge(d)
        let rounds = d.rounds ?? self.rounds
        var body: [String: Any] = ["question": q, "mode": council ? "council" : "quick"]
        if council {
            body["models"] = councilModels(d)
            body["rounds"] = rounds
            body["judge"] = judgeOf.id
            body["claudeModel"] = judgeOf.claudeModel
        } else {
            body["responder"] = who.id
            body["claudeModel"] = who.claudeModel
        }
        let sent = Self.payload(followupAttachments)
        if !sent.body.isEmpty { body["attachments"] = sent.body }
        let web = followupWebSearchActive
        if web { body["webSearch"] = true }
        do {
            let data = try await request("POST", "/api/debates/\(d.id)/followups", body: body)
            guard let n = json(data)["turn"] as? Int else { throw URLError(.badServerResponse) }
            onHistoryChanged?()
            // Nel frattempo è stata aperta un'altra discussione: la bozza inviata era stata messa da
            // parte e il campo mostra quella dell'altra; questa si segue in background.
            guard var cur = current, cur.id == d.id else { drafts[d.id] = nil; watch(d.id, title: d.displayTitle, turn: n); return }
            followup = ""
            followupAttachments = []
            followupNotice = nil
            if !cur.turns.contains(where: { $0.turn == n }) {
                var t = newTurn(cur, n: n, question: q, mode: council ? "council" : "quick")
                t.attachments = sent.meta
                t.webSearch = web
                if council {
                    t.rounds = rounds
                    t.judgeLabel = judgeOf.label
                } else {
                    t.answer = CardState(id: who.id, title: String(format: L("Risposta rapida · %@"), who.label))
                }
                cur.turns.append(t)
                cur.turns.sort { $0.turn < $1.turn }
                current = cur
            }
            listen(d.id)
        } catch {
            let e = error as NSError
            if e.domain == "council", e.code == 409 {
                followupError = L("La discussione è ancora in corso: attendi che finisca, poi riprova.")
                if current?.id == d.id { await open(d.id) }
            } else {
                followupError = String(format: L("Domanda non inviata: %@"), error.localizedDescription)
            }
        }
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
        if d.webSearch { parts.append(("globe", L("con ricerca sul web"))) }
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
        var out = ["# \(d.displayTitle)", "", "> " + d.question.replacingOccurrences(of: "\n", with: "\n> "), ""]
        if !d.attachments.isEmpty {
            out += ["**" + L("Allegati") + ":** " + d.attachments.map { "\($0.name) (\(charsText($0.chars)))" }.joined(separator: ", "), ""]
        }
        out += ["_\(meta(d))_", ""]
        if let v = d.verdict { out += ["## " + L("Verdetto"), "", v, ""] }
        func card(_ c: CardState, _ h: String) {
            out += ["\(h) \(c.title)", ""]
            if let m = c.usedModel, c.replaced != nil { out += ["_" + String(format: L("Ha risposto %@ al posto di %@, che non ha risposto in tempo."), m, c.replaced ?? "") + "_", ""] }
            out.append(c.error.map { "_\($0)_" } ?? (c.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            out.append("")
        }
        func phases(_ list: [PhaseState], _ h: String) {
            for p in list {
                out += ["\(h) \(p.title)", ""]
                if let n = p.note { out += ["_\(n)_", ""] }
                for c in p.cards { card(c, h + "#") }
            }
        }
        phases(d.phases, "##")
        // Domande di seguito, in ordine: domanda, poi risposta rapida o nuovo giro del consiglio.
        for t in d.turns {
            out += ["---", "", "## " + String(format: L("Domanda di seguito %d"), t.turn), "",
                    "> " + t.question.replacingOccurrences(of: "\n", with: "\n> "), ""]
            if !t.attachments.isEmpty {
                out += ["**" + L("Allegati") + ":** " + t.attachments.map { "\($0.name) (\(charsText($0.chars)))" }.joined(separator: ", "), ""]
            }
            phases(t.phases, "###")
            if let a = t.answer { card(a, "###") }
            if let v = t.verdict {
                out += ["### " + L("Verdetto"), ""]
                if let by = t.verdictBy { out += ["_" + String(format: L("Giudice: %@"), by) + "_", ""] }
                out += [v, ""]
            }
            if t.answer == nil && t.verdict == nil && !t.isRunning { out += ["_\(t.statusText)_", ""] }
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
        "research": L("Ricerca"),
        "initial": L("Risposte"), "critique": L("Critica"), "revise": L("Revisione"),
        "final": L("Posizione finale"), "verdict": L("Verdetto"),
    ]
    static let phaseNames = [
        "research": L("Ricerca sul web"),
        "initial": L("Risposte iniziali"), "critique": L("Critica incrociata"), "revise": L("Revisione"),
        "final": L("Posizione finale"), "verdict": L("Verdetto"),
    ]
    static let phaseDescriptions = [
        "research": L("Prima del dibattito un modello cerca sul web informazioni aggiornate e le passa a tutti i partecipanti."),
        "initial": L("Ogni modello risponde alla domanda da solo, senza vedere le risposte degli altri."),
        "critique": L("Ogni modello legge le risposte anonime degli altri e ne indica errori e punti deboli."),
        "revise": L("Ogni modello rivede la propria risposta tenendo conto delle critiche ricevute."),
        "final": L("Ogni modello confronta le risposte riviste e dichiara la sua posizione definitiva."),
        "verdict": L("Il giudice legge le posizioni finali e scrive il verdetto."),
    ]

    /// Numero di round del dibattito (0–3).
    func roundCount(_ d: DebateState) -> Int {
        d.rounds ?? max(0, d.phases.filter { $0.id != "initial" && $0.id != "research" }.count)
    }

    /// Intestazione numerata della fase: "Apertura · Risposte iniziali", "Round 2 di 3 · Revisione".
    func phaseHeading(_ id: String, in d: DebateState) -> String {
        let name = Self.phaseNames[id] ?? id
        switch id {
        case "research": return String(format: L("Preparazione · %@"), name)
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
        case "research": return L("Preparazione")
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
        let research = d.webSearch || d.phases.contains { $0.id == "research" }
        let ids = (research ? ["research"] : []) + ["initial"] + Array(Self.phaseOrder.dropFirst().prefix(roundCount(d))) + ["verdict"]
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
                total += s.id == "research" ? 1 : active
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
