// Contenuto della finestra principale in SwiftUI nativo: composer (nuova domanda) e dibattito.
// Solo colori e controlli di sistema; nessun effetto vetro nel contenuto (linee guida macOS 26).

import AppKit
import SwiftUI

// MARK: - Radice

struct ContentRoot: View {
    @ObservedObject var store: CouncilStore
    var openSettings: () -> Void
    var openModels: () -> Void
    var saveFile: (_ filename: String, _ text: String) -> Void

    var body: some View {
        Group {
            if let d = store.current {
                DebateView(store: store, debate: d, saveFile: saveFile)
                    .id(d.id)
            } else {
                ComposerView(store: store, openSettings: openSettings, openModels: openModels)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Composer

struct ComposerView: View {
    @ObservedObject var store: CouncilStore
    var openSettings: () -> Void
    var openModels: () -> Void
    @FocusState private var focused: Bool

    private var hasOtherVoices: Bool { store.voices.contains { !$0.isClaude } }
    private var troubled: [VoiceInfo] { store.voices.filter { $0.problem != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let p = store.parent {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Text("Approfondimento di: \(p.question)")
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                        Button { store.parent = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Togli il collegamento al dibattito precedente")
                        .accessibilityLabel("Togli approfondimento")
                    }
                    .font(.callout)
                }

                composerBox

                if let err = store.startError {
                    Label(err, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !hasOtherVoices && store.engineReady {
                    Button("Aggiungi le chiavi API…", action: openSettings)
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
    }

    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            // a) Domanda: campo nativo che cresce col testo, placeholder di sistema
            TextField("Domanda", text: $store.question, prompt: Text("Fai una domanda al consiglio"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(3...10)
                .focused($focused)
                .accessibilityLabel("Domanda")

            Divider()

            // b) Partecipanti: pulsanti-interruttore di sistema, stato anche col segno di spunta
            VStack(alignment: .leading, spacing: 8) {
                Text("Partecipano").font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(store.voices) { v in
                        VoiceToggle(title: store.displayName(v), provider: v.provider, problem: v.problem,
                                    isOn: Binding(get: { store.selected.contains(v.id) },
                                                  set: { _ in store.toggle(v.id) }))
                    }
                    Button(action: openModels) {
                        Label("Aggiungi modelli…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 4)
                    .help(store.lockedCount > 0
                          ? "\(store.lockedCount) \(store.lockedCount == 1 ? "voce richiede" : "voci richiedono") una chiave API: apri la scheda Modelli delle Impostazioni"
                          : "Apri la scheda Modelli delle Impostazioni")
                }

                // Problemi dei modelli: simbolo + testo sempre visibile, con l'azione per risolverli
                if !troubled.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(troubled) { v in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .accessibilityHidden(true)
                                Text("\(store.displayName(v)): \(v.problem ?? "")")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button("Apri impostazioni…", action: openSettings)
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }

            Divider()

            // c) Opzioni e invio
            HStack(spacing: 16) {
                Picker("Round", selection: $store.rounds) {
                    ForEach([0, 1, 2, 3], id: \.self) { r in
                        Text(CouncilStore.roundsTitles[r] ?? "\(r)").tag(r)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Giudice", selection: judgeBinding) {
                    Section("Abbonamento Claude") {
                        ForEach(store.claudeModels, id: \.self) { m in
                            Text("Claude \(m.capitalized)").tag("claude:\(m)")
                        }
                    }
                    let others = store.voices.filter { !$0.isClaude }
                    if !others.isEmpty {
                        Section("Altri modelli") {
                            ForEach(others) { v in Text(v.label).tag("voice:\(v.id)") }
                        }
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer(minLength: 8)

                Button { Task { await store.start() } } label: {
                    Label {
                        Text("Avvia")
                    } icon: {
                        if store.starting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(!store.canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Avvia il dibattito (⌘↩)")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
        )
    }

    /// Valore unico del menu Giudice: "claude:<modello>" oppure "voice:<id>".
    private var judgeBinding: Binding<String> {
        Binding(
            get: { store.judge == "claude" ? "claude:\(store.claudeModel)" : "voice:\(store.judge)" },
            set: { tag in
                if tag.hasPrefix("claude:") {
                    store.claudeModel = String(tag.dropFirst(7))
                    store.judge = "claude"
                } else if tag.hasPrefix("voice:") {
                    store.judge = String(tag.dropFirst(6))
                }
            }
        )
    }
}

/// Partecipante: interruttore a pulsante di sistema (stato "selezionato" per VoiceOver e tastiera).
private struct VoiceToggle: View {
    let title: String
    let provider: String
    let problem: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").imageScale(.small) }
                Text(title)
                if problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .imageScale(.small)
                }
            }
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .help(problem.map { "\(title) — \($0)" } ?? provider)
        .accessibilityLabel(title)
        .accessibilityValue(problem.map { "problema: \($0)" } ?? "")
    }
}

// MARK: - Layout che va a capo

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Dibattito

struct DebateView: View {
    @ObservedObject var store: CouncilStore
    let debate: DebateState
    var saveFile: (_ filename: String, _ text: String) -> Void

    @State private var expanded: [String: Bool] = [:]
    @State private var copied = false
    /// Dibattito seguito dal vivo: i round restano aperti anche quando arriva il verdetto,
    /// così la posizione di lettura non cambia.
    @State private var watchedLive: Bool
    /// true finché si segue il dibattito dal vivo (l'utente non ha scorso in su per rileggere).
    @State private var following = true
    @State private var userScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: CouncilStore, debate: DebateState, saveFile: @escaping (_ filename: String, _ text: String) -> Void) {
        self.store = store
        self.debate = debate
        self.saveFile = saveFile
        _watchedLive = State(initialValue: debate.isRunning)
    }

    private var steps: [DebateStep] { store.steps(debate) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if !debate.phases.isEmpty || debate.isRunning {
                        StepsRow(steps: steps, reduceMotion: reduceMotion) { id in
                            let target = id == "verdict" && debate.verdict != nil ? "phase-verdict" : "phase-\(id)"
                            if reduceMotion { proxy.scrollTo(target, anchor: .top) }
                            else { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) } }
                        }
                        .padding(.top, 16)
                    }

                    if debate.isRunning { progressBar.padding(.top, 14) }

                    if !debate.phases.isEmpty && !debate.isRunning && !watchedLive { courseHeading.padding(.top, 32) }

                    ForEach(debate.phases) { p in
                        Divider().padding(.vertical, 16)   // 32 pt tra un round e l'altro
                        phaseSection(p).id("phase-\(p.id)")
                    }

                    // Il verdetto chiude sempre il dibattito, in fondo, come l'ultima risposta in una chat.
                    if let v = debate.verdict {
                        Divider().padding(.vertical, 16)
                        verdictBlock(v)
                    }

                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Si segue il dibattito come in una chat: a ogni nuovo round (e al verdetto) la vista
            // scende all'inizio della nuova sezione, così si legge dall'inizio. Se l'utente scorre
            // in su per rileggere, l'inseguimento si ferma finché non torna in fondo o preme il
            // pulsante "Vai al round in corso". Solo lo scorrimento dell'utente cambia `following`:
            // la crescita del contenuto non lo spegne.
            .onScrollPhaseChange { _, new, context in
                userScrolling = new == .interacting || new == .decelerating
                let g = context.geometry
                if new == .idle, g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 120 { following = true }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                if userScrolling, new < old - 2 { following = false }
            }
            .onChange(of: sectionKey) {
                guard watchedLive, following else { return }
                Task { @MainActor in
                    // Si attende il layout della nuova sezione prima di scorrere.
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToLatest(proxy)
                }
            }
            .overlay(alignment: .bottom) {
                if debate.isRunning && !following {
                    Button {
                        following = true
                        scrollToLatest(proxy)
                    } label: {
                        Label(debate.judging ? "Vai al verdetto" : "Vai al round in corso", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .shadow(radius: 4, y: 1)
                    .padding(.bottom, 18)
                    .transition(.opacity)
                }
            }
        }
    }

    private static let endID = "debate-end"

    /// Cambia a ogni nuovo round, all'inizio del giudizio e all'arrivo del verdetto.
    private var sectionKey: String {
        "\(debate.phases.count)-\(debate.judging)-\(debate.verdict != nil)"
    }

    /// Porta all'inizio della sezione più recente: verdetto, round in corso o fondo pagina.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        let target: String
        let anchor: UnitPoint
        if debate.verdict != nil { target = "phase-verdict"; anchor = .top }
        else if debate.judging { target = Self.endID; anchor = .bottom }
        else if let last = debate.phases.last { target = "phase-\(last.id)"; anchor = .top }
        else { target = Self.endID; anchor = .bottom }
        if reduceMotion { proxy.scrollTo(target, anchor: anchor) }
        else { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: anchor) } }
    }

    private func verdictBlock(_ v: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            actions
            verdictBox(v).id("phase-verdict")
        }
        .padding(.top, 20)
    }

    // MARK: Intestazione: domanda, meta, stato

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(debate.question)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if debate.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in Text(store.meta(debate)) }
                } else {
                    Text(store.meta(debate))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if !debate.isRunning { finalStatus.padding(.top, 2) }
        }
    }

    /// Esito del dibattito a parole, con simbolo (mai solo colore).
    @ViewBuilder private var finalStatus: some View {
        switch debate.status {
        case "done":
            StatusLabel(text: "Completato", symbol: "checkmark.circle.fill", tint: .green)
        case "cancelled":
            StatusLabel(text: "Interrotto", symbol: "stop.circle", tint: .secondary)
        case "interrupted":
            StatusLabel(text: "Interrotto: il motore è stato riavviato", symbol: "exclamationmark.triangle.fill", tint: .orange)
        default:
            VStack(alignment: .leading, spacing: 4) {
                StatusLabel(text: "Non riuscito", symbol: "xmark.octagon.fill", tint: .red)
                if debate.statusText != CouncilStore.statusText(debate.status) {
                    Text(debate.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Avanzamento determinato e Interrompi

    private var progressBar: some View {
        let pr = store.progress(debate)
        let current = steps.first { $0.state == .current }
        let label = debate.judging || current?.id == "verdict" ? debate.statusText : (current?.heading ?? debate.statusText)
        return HStack(alignment: .center, spacing: 16) {
            ProgressView(value: Double(pr.done), total: Double(pr.total)) {
                Text(label).font(.callout.weight(.medium))
            } currentValueLabel: {
                Text("\(pr.done) di \(pr.total) risposte").monospacedDigit()
            }
            .progressViewStyle(.linear)
            .accessibilityValue("\(label), \(pr.done) di \(pr.total) risposte")

            Button { Task { await store.cancel() } } label: {
                Label("Interrompi", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(".", modifiers: .command)
            .help("Interrompi il dibattito (⌘.). Le risposte già arrivate restano salvate.")
        }
    }

    // MARK: Azioni sul verdetto

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                guard let v = debate.verdict else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(v, forType: .string)
                copied = true
                AccessibilityNotification.Announcement("Verdetto copiato").post()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copiato" : "Copia verdetto", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            Button {
                if let e = store.exportMarkdown() { saveFile(e.filename, e.text) }
            } label: {
                Label("Esporta come Markdown…", systemImage: "square.and.arrow.up")
            }
            Button {
                store.deepen()
            } label: {
                Label("Approfondisci…", systemImage: "arrow.turn.down.right")
            }
            .help("Nuova domanda che parte da questo dibattito")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: Verdetto: unico riquadro evidenziato

    private func verdictBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Verdetto del consiglio").font(.title3.weight(.semibold))
                if let by = debate.verdictBy, !by.isEmpty {
                    Text("di \(by)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            MarkdownView(text)
                .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    // MARK: Svolgimento (dibattito concluso)

    private var courseHeading: some View {
        let answers = debate.phases.reduce(0) { $0 + $1.cards.filter { $0.text != nil }.count }
        let rounds = store.roundCount(debate)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Svolgimento").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(rounds == 0 ? "Solo risposte iniziali" : "Risposte iniziali e \(rounds) round") · \(answers) \(answers == 1 ? "risposta" : "risposte")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Espandi tutti") { setAll(true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .help("Apri tutti i round (⌥⌘→)")
            Button("Comprimi tutti") { setAll(false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .help("Chiudi tutti i round (⌥⌘←)")
        }
        .buttonStyle(.borderless)
    }

    private func setAll(_ open: Bool) {
        for p in debate.phases { setExpanded(p.id, open) }
    }

    // MARK: Round

    private func isExpanded(_ id: String) -> Bool {
        expanded[id] ?? store.expandedPhases[debate.id]?[id] ?? (watchedLive || debate.verdict == nil)
    }

    private func setExpanded(_ id: String, _ open: Bool) {
        expanded[id] = open
        store.expandedPhases[debate.id, default: [:]][id] = open
    }

    private func phaseSection(_ p: PhaseState) -> some View {
        let binding = Binding<Bool>(get: { isExpanded(p.id) }, set: { setExpanded(p.id, $0) })
        let state = store.phaseState(p, in: debate)
        return DisclosureGroup(isExpanded: binding) {
            if !p.cards.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(p.cards) { c in
                        CardView(card: c, running: debate.isRunning, since: p.startedAt)
                    }
                }
                .padding(.top, 10)
            }
        } label: {
            PhaseHeader(heading: store.phaseHeading(p.id, in: debate),
                        description: CouncilStore.phaseDescriptions[p.id],
                        note: p.note, state: state, meta: phaseMeta(p, state),
                        reduceMotion: reduceMotion)
                .contentShape(Rectangle())
                .onTapGesture { binding.wrappedValue.toggle() }
        }
    }

    /// "3 di 5 risposte" durante la fase; "5 risposte · fino a 41 s" a fase chiusa.
    private func phaseMeta(_ p: PhaseState, _ state: StepState) -> String? {
        if p.cards.isEmpty { return nil }
        let arrived = p.cards.filter { !$0.waiting }.count
        if state == .current { return "\(arrived) di \(p.cards.count) risposte" }
        let answered = p.cards.filter { $0.text != nil }.count
        var parts = ["\(answered) \(answered == 1 ? "risposta" : "risposte")"]
        let missing = p.cards.count - answered
        if missing > 0 { parts.append("\(missing) senza risposta") }
        if let longest = p.cards.compactMap(\.seconds).max() { parts.append("fino a \(Int(longest.rounded())) s") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Intestazione di un round

private struct PhaseHeader: View {
    let heading: String
    let description: String?
    let note: String?
    let state: StepState
    let meta: String?
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                PhaseStatusLabel(state: state, reduceMotion: reduceMotion)
                if let meta {
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel([heading, PhaseStatusLabel.text(state), meta].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Stato di un round a parole con simbolo: il colore è solo una seconda codifica.
private struct PhaseStatusLabel: View {
    let state: StepState
    let reduceMotion: Bool

    static func text(_ s: StepState) -> String {
        switch s {
        case .done: return "Completato"
        case .current: return "In corso"
        case .pending: return "In attesa"
        case .skipped: return "Saltato"
        case .notRun: return "Non svolto"
        case .stopped: return "Interrotto"
        }
    }

    static func symbol(_ s: StepState) -> String {
        switch s {
        case .done: return "checkmark.circle.fill"
        case .current: return "ellipsis.circle"
        case .pending: return "circle.dashed"
        case .skipped: return "forward.circle"
        case .notRun: return "minus.circle"
        case .stopped: return "stop.circle"
        }
    }

    var body: some View {
        Label {
            Text(Self.text(state))
        } icon: {
            Image(systemName: Self.symbol(state))
                .foregroundStyle(state == .done ? AnyShapeStyle(Color.green)
                                 : state == .current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, isActive: state == .current && !reduceMotion)
        }
        .font(.subheadline.weight(.medium))
    }
}

/// Esito del dibattito: testo in colore primario, simbolo colorato.
private struct StatusLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout.weight(.medium))
    }
}

// MARK: - Riga dei passi (Risposte › Critica › … › Verdetto)

private struct StepsRow: View {
    let steps: [DebateStep]
    let reduceMotion: Bool
    let go: (String) -> Void

    private var currentIndex: Int {
        steps.firstIndex { $0.state == .current }
            ?? steps.lastIndex { $0.state == .done || $0.state == .skipped }
            ?? 0
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            compact
        }
    }

    private var full: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                stepButton(s)
            }
        }
        .fixedSize()
    }

    private var compact: some View {
        let s = steps.isEmpty ? nil : steps[min(currentIndex, steps.count - 1)]
        return Group {
            if let s {
                Button { go(s.id) } label: {
                    Label("Fase \(currentIndex + 1) di \(steps.count) · \(s.short)", systemImage: symbol(s.state))
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .help("Vai alla fase")
            }
        }
    }

    @ViewBuilder private func stepButton(_ s: DebateStep) -> some View {
        let reachable = s.state != .pending && s.state != .notRun && !(s.id == "verdict" && s.state != .done)
        let label = Label(s.short, systemImage: symbol(s.state))
            .font(s.state == .current ? .callout.weight(.semibold) : .callout)
            .foregroundStyle(s.state == .current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .accessibilityLabel("\(s.short), \(PhaseStatusLabel.text(s.state))")
        if reachable {
            Button { go(s.id) } label: { label }
                .buttonStyle(.plain)
                .help("Vai a: \(s.heading)")
        } else {
            label
        }
    }

    private func symbol(_ s: StepState) -> String {
        switch s {
        case .done: return "checkmark.circle.fill"
        case .current: return "circle.inset.filled"
        case .pending: return "circle"
        case .skipped: return "forward.circle"
        case .notRun: return "minus.circle"
        case .stopped: return "stop.circle"
        }
    }
}

// MARK: - Card di un modello

private struct CardView: View {
    let card: CardState
    let running: Bool
    let since: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title).font(.headline)
                    Spacer(minLength: 6)
                    if let s = card.seconds {
                        Text(String(format: "%.1f s", s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let m = card.usedModel {
                    Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)

            if let r = card.replaced {
                Label {
                    Text("Ha risposto \(card.usedModel ?? "un modello di riserva") al posto di \(r), che non ha risposto in tempo.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.fill.quaternary))
            }

            if let text = card.text {
                MarkdownView(text)
            } else if let err = card.error {
                if card.skipped {
                    Label {
                        Text("Ha saltato questo round e rientra nel prossimo: \(Self.reason(err))")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "forward")
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Non ha risposto").fontWeight(.semibold)
                            Text(err).foregroundStyle(.secondary)
                            Text("Il dibattito continua senza questo modello.").foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "xmark.octagon").foregroundStyle(.red)
                    }
                    .font(.body)
                    .textSelection(.enabled)
                }
            } else if running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = since.map { max(0, Int(ctx.date.timeIntervalSince($0))) }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(secs.map { "In attesa · \($0) s" } ?? "In attesa")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(secs.map { "\(card.title), in attesa da \($0) secondi" } ?? "\(card.title), in attesa")
                }
            } else {
                Label("Nessuna risposta: il dibattito si è fermato prima.", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .contextMenu {
            if let text = card.text {
                Button("Copia risposta") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    /// L'errore del motore è "ha saltato questo round (<motivo>)": si mostra solo il motivo.
    static func reason(_ err: String) -> String {
        guard err.hasPrefix("ha saltato"), let open = err.firstIndex(of: "("), err.hasSuffix(")") else { return err }
        return String(err[err.index(after: open)..<err.index(before: err.endIndex)])
    }
}
