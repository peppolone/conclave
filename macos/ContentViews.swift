// Contenuto della finestra principale in SwiftUI nativo: composer (nuova domanda) e dibattito.
// Sfondo e riquadri con i token di Brand.swift; nessun effetto vetro nel contenuto (linee guida macOS 26).

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
        // Lo sfondo di marchio sta sotto tutta la finestra (main.swift): qui niente sfondo opaco.
        .tint(Brand.accent)
    }
}

// MARK: - Elementi comuni

/// Riquadro del contenuto: superficie del marchio, bordo sottile, angoli continui.
private struct SurfaceBox: ViewModifier {
    var radius: CGFloat = 12
    var stroke: Color = Brand.hairline
    var shadow = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? 0.08 : 0), radius: 14, y: 4)
    }
}

private extension View {
    func surfaceBox(radius: CGFloat = 12, stroke: Color = Brand.hairline, shadow: Bool = false) -> some View {
        modifier(SurfaceBox(radius: radius, stroke: stroke, shadow: shadow))
    }
}

/// Pulsante-icona secondario: area di clic 30 pt, sfondo leggero al passaggio del mouse,
/// tooltip e nome per VoiceOver sempre presenti.
private struct IconButton<Icon: View>: View {
    let label: String
    let help: String
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    init(_ label: String, help: String? = nil, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.label = label
        self.help = help ?? label
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            icon()
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverIconStyle())
        .help(help)
        .accessibilityLabel(label)
    }
}

extension IconButton where Icon == Image {
    init(_ label: String, symbol: String, help: String? = nil, action: @escaping () -> Void) {
        self.init(label, help: help, action: action) { Image(systemName: symbol) }
    }
}

private struct HoverIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration) }

    struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover && enabled ? 0.06 : 0))
                )
                .onHover { hover = $0 }
        }
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

    /// Saluto secondo l'ora del giorno.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<13: return L("Buongiorno")
        case 13..<18: return L("Buon pomeriggio")
        case 18..<24: return L("Buonasera")
        default: return L("Ciao, nottambulo")
        }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    welcome.padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 10) {
                        if let p = store.parent { parentBanner(p) }
                        composerBox
                        optionsRow.padding(.horizontal, 6)
                        messages.padding(.horizontal, 6)
                    }
                    .frame(maxWidth: 720)

                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .onAppear { focused = true }
    }

    // MARK: Benvenuto

    private var welcome: some View {
        VStack(spacing: 12) {
            CouncilLogo(size: 48)
            Text(greeting)
                .font(.system(size: 34, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Fai una domanda: più AI ne discutono e un giudice decide.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func parentBanner(_ p: ParentRef) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)
            Text(String(format: L("Approfondimento di: %@"), p.question))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            IconButton(L("Togli approfondimento"), symbol: "xmark",
                       help: L("Togli il collegamento al dibattito precedente")) { store.parent = nil }
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .surfaceBox(radius: 12)
    }

    // MARK: Riquadro della domanda

    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Domanda", text: $store.question, prompt: Text("Cosa vuoi chiedere al consiglio?"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(3...12)
                .lineSpacing(2)
                .focused($focused)
                .accessibilityLabel(L("Domanda"))

            Rectangle().fill(Brand.hairline).frame(height: 1).accessibilityHidden(true)

            Text(L("Partecipano"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, -6)
                .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 12) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    IconButton(L("Aggiungi modelli…"), symbol: "plus",
                               help: store.lockedCount > 0
                                   ? (store.lockedCount == 1 ? L("Aggiungi modelli: 1 voce richiede una chiave API")
                                      : String(format: L("Aggiungi modelli: %d voci richiedono una chiave API"), store.lockedCount))
                                   : L("Aggiungi modelli (scheda Modelli delle Impostazioni)"),
                               action: openModels)
                    ForEach(store.voices) { v in
                        Toggle(store.displayName(v), isOn: Binding(get: { store.selected.contains(v.id) },
                                                                    set: { _ in store.toggle(v.id) }))
                            .toggleStyle(VoiceChipStyle(problem: v.problem, provider: v.provider))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Partecipano"))

                sendButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .surfaceBox(radius: 20, stroke: focused ? Brand.accent.opacity(0.45) : Brand.hairline, shadow: true)
    }

    private var sendButton: some View {
        Button { Task { await store.start() } } label: {
            ZStack {
                Circle().fill(store.canStart ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                if store.starting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(store.canStart ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!store.canStart)
        .keyboardShortcut(.return, modifiers: .command)
        .help(L("Avvia il dibattito (⌘↩)"))
        .accessibilityLabel(L("Avvia il dibattito"))
    }

    // MARK: Opzioni sotto il riquadro: menu leggeri e stima

    private var optionsRow: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Round", selection: $store.rounds) {
                    ForEach([0, 1, 2, 3], id: \.self) { r in
                        Text(verbatim: CouncilStore.roundsTitles[r] ?? "\(r)").tag(r)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(store.rounds == 0 ? L("Solo risposte") : String(format: L("%d round"), store.rounds),
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .help(L("Round di critica tra i modelli"))
            .accessibilityLabel(L("Round"))

            Menu {
                Picker("Giudice", selection: judgeBinding) {
                    Section("Abbonamento Claude") {
                        ForEach(store.claudeModels, id: \.self) { m in
                            Text(verbatim: "Claude \(m.capitalized)").tag("claude:\(m)")
                        }
                    }
                    let others = store.voices.filter { !$0.isClaude }
                    if !others.isEmpty {
                        Section("Altri modelli") {
                            ForEach(others) { v in Text(v.label).tag("voice:\(v.id)") }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(String(format: L("Giudice: %@"), store.judgeLabel), systemImage: "checkmark.seal")
            }
            .help(L("Chi emette il verdetto"))
            .accessibilityLabel(L("Giudice"))

            Spacer(minLength: 8)

            if store.canEstimate {
                Label(String(format: L("%d chiamate + 1 verdetto"), store.estimatedCalls),
                      systemImage: "arrow.left.arrow.right")
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(store.hint)
                    .accessibilityLabel(store.hint)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: store.estimatedCalls)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = store.startError {
                Label(err, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Brand.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !store.canEstimate {
                Text(store.hint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Problemi dei modelli: simbolo + testo sempre visibile, con l'azione per risolverli
            if !troubled.isEmpty {
                ForEach(troubled) { v in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(store.displayName(v)): \(v.problem ?? "")")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Apri impostazioni…", action: openSettings)
                    .buttonStyle(.link)
            }

            if !hasOtherVoices && store.engineReady {
                Button("Aggiungi le chiavi API…", action: openSettings)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
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

/// Partecipante: chip compatta attivabile. Stato con colore del marchio **e** segno di spunta;
/// per VoiceOver resta un interruttore con tratto "selezionato".
private struct VoiceChipStyle: ToggleStyle {
    let problem: String?
    let provider: String

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                }
                configuration.label
                    .lineLimit(1)
                    .truncationMode(.tail)
                if problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .imageScale(.small)
                }
            }
            .font(.callout)
            .foregroundStyle(on ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(on ? Brand.accent.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(on ? Brand.accent.opacity(0.45) : Brand.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(problem.map { String(format: L("Problema: %@"), $0) } ?? provider)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(problem.map { String(format: L("problema: %@"), $0) } ?? (on ? L("partecipa") : L("escluso")))
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
            let size = fitted(s, maxWidth)
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

    /// Misura naturale, ristretta alla larghezza disponibile (il testo si tronca invece di uscire).
    private func fitted(_ s: LayoutSubview, _ maxWidth: CGFloat) -> CGSize {
        let natural = s.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, natural.width > maxWidth else { return natural }
        return s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = fitted(s, bounds.width)
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
    /// Domanda lunga mostrata per intero nell'intestazione.
    @State private var questionExpanded = false
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

                    // Il verdetto è il risultato: viene subito dopo l'intestazione, prima dello svolgimento.
                    if let v = debate.verdict {
                        verdictBox(v).id("phase-verdict")
                            .padding(.top, 24)
                            .transition(.opacity)
                    } else if debate.isRunning && debate.judging {
                        // Segnaposto al posto del verdetto: la vista dal vivo sale qui mentre il giudice scrive.
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L("Il giudice sta scrivendo il verdetto…"))
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surfaceBox(radius: Brand.Radius.panel, stroke: Brand.accent.opacity(0.28))
                        .id("phase-verdict")
                        .padding(.top, 24)
                    }

                    if !debate.phases.isEmpty {
                        courseHeading.padding(.top, debate.verdict != nil ? 40 : 28)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(debate.phases.enumerated()), id: \.element.id) { i, p in
                                phaseSection(p, number: i + 1, last: i == debate.phases.count - 1)
                                    .id("phase-\(p.id)")
                            }
                        }
                        .padding(.top, 16)
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
                        Label(debate.judging ? L("Vai al verdetto") : L("Vai al round in corso"), systemImage: debate.judging ? "arrow.up" : "arrow.down")
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
        if debate.verdict != nil || debate.judging { target = "phase-verdict"; anchor = .top }
        else if let last = debate.phases.last { target = "phase-\(last.id)"; anchor = .top }
        else { target = Self.endID; anchor = .bottom }
        if reduceMotion { proxy.scrollTo(target, anchor: anchor) }
        else { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: anchor) } }
    }

    // MARK: Intestazione: stato, domanda, dettagli, partecipanti

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBadge

            VStack(alignment: .leading, spacing: 6) {
                Text(debate.displayTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                questionText
            }

            Group {
                if debate.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in metaRow }
                } else {
                    metaRow
                }
            }

            if !participants.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(participants, id: \.letter) { p in
                        ParticipantTag(letter: p.letter, label: p.label)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Partecipanti") + ": " + participants.map(\.label).joined(separator: ", "))
            }

            if !debate.isRunning, !["done", "cancelled"].contains(debate.status),
               debate.statusText != CouncilStore.statusText(debate.status) {
                Text(debate.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Domande lunghe: tre righe e "Mostra tutto"; il testo intero resta nel tooltip.
    private var questionIsLong: Bool {
        debate.question.count > 240 || debate.question.filter(\.isNewline).count > 2
    }

    private var questionText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(debate.question)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(questionExpanded || !questionIsLong ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(questionIsLong && !questionExpanded ? debate.question : "")
                .accessibilityLabel(L("Domanda") + ": " + debate.question)
            if questionIsLong {
                Button(questionExpanded ? L("Mostra meno") : L("Mostra tutta la domanda")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { questionExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    /// Data, round, giudice e durata: voci separate con il proprio simbolo, su più righe se serve.
    private var metaRow: some View {
        FlowLayout(spacing: 18, lineSpacing: 8) {
            ForEach(headerMeta, id: \.symbol) { m in
                Label(m.text, systemImage: m.symbol)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var participants: [(letter: String, label: String)] {
        debate.participants.values.map { (letter: $0.letter, label: $0.label) }.sorted { $0.letter < $1.letter }
    }

    private static let headerDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Data, poi round, giudice e durata (es. "7 nov 2026, 10:24", "3 round", "giudice Claude Sonnet", "durata 1 min 34 s").
    private var headerMeta: [(symbol: String, text: String)] {
        let rest = store.metaItems(debate)
        guard let s = debate.startedAt else { return rest }
        return [(symbol: "calendar", text: Self.headerDate.string(from: s))] + rest
    }

    /// Esito del dibattito in una capsula: simbolo e testo, mai solo colore.
    @ViewBuilder private var statusBadge: some View {
        if debate.isRunning {
            StatusBadge(text: debate.judging ? L("Verdetto in scrittura") : L("In corso"),
                        symbol: "circle.dotted", tint: Brand.accent, pulse: !reduceMotion)
        } else {
            switch debate.status {
            case "done": StatusBadge(text: L("Completato"), symbol: "checkmark.circle.fill", tint: Brand.success)
            case "cancelled": StatusBadge(text: L("Interrotto"), symbol: "stop.circle.fill", tint: .secondary)
            case "interrupted": StatusBadge(text: L("Interrotto: il motore è stato riavviato"), symbol: "exclamationmark.triangle.fill", tint: Brand.warning)
            default: StatusBadge(text: L("Non riuscito"), symbol: "xmark.octagon.fill", tint: Brand.danger)
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
                Text(String(format: L("%d di %d risposte"), pr.done, pr.total)).monospacedDigit()
            }
            .progressViewStyle(.linear)
            .accessibilityValue(label + ", " + String(format: L("%d di %d risposte"), pr.done, pr.total))

            IconButton(L("Interrompi"), symbol: "stop.circle",
                       help: L("Interrompi (⌘.). Le risposte già arrivate restano salvate.")) {
                Task { await store.cancel() }
            }
            .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surfaceBox(radius: 12)
    }

    // MARK: Azioni sul verdetto

    /// Pulsanti-icona in alto a destra del verdetto, ciascuno con tooltip e nome per VoiceOver.
    private func actions(_ verdict: String) -> some View {
        HStack(spacing: 2) {
            IconButton(copied ? L("Copiato") : L("Copia verdetto")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(verdict, forType: .string)
                copied = true
                AccessibilityNotification.Announcement(L("Verdetto copiato")).post()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? AnyShapeStyle(Brand.success) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            IconButton(L("Esporta come Markdown…"), symbol: "arrow.down.doc") {
                if let e = store.exportMarkdown() { saveFile(e.filename, e.text) }
            }
            ShareLink(item: verdict, subject: Text(debate.displayTitle)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverIconStyle())
            .help(L("Condividi il verdetto"))
            .accessibilityLabel(L("Condividi il verdetto"))
            IconButton(L("Approfondisci…"), symbol: "arrow.turn.down.right",
                       help: L("Approfondisci: nuova domanda che parte da questo dibattito")) {
                store.deepen()
            }
        }
    }

    // MARK: Verdetto: scheda protagonista

    private func verdictBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Brand.selection))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Verdetto del consiglio"))
                        .font(.title3.weight(.semibold))
                    if let by = debate.verdictBy, !by.isEmpty {
                        Text(String(format: L("Giudice: %@"), by))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)
                actions(text)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Rectangle().fill(Brand.hairline).frame(height: 1).accessibilityHidden(true)

            MarkdownView(text)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).fill(Brand.verdictSurface))
        .overlay(alignment: .top) {
            // Filo d'accento in cima: distingue il verdetto dalle card dello svolgimento.
            UnevenRoundedRectangle(topLeadingRadius: Brand.Radius.panel, topTrailingRadius: Brand.Radius.panel, style: .continuous)
                .fill(LinearGradient(colors: [Brand.softBlue, Brand.softGreen, Brand.softAmber], startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
                .mask(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).padding(.bottom, -Brand.Radius.panel))
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).strokeBorder(Brand.accent.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
    }

    // MARK: Svolgimento (dibattito concluso)

    private var courseHeading: some View {
        let answers = debate.phases.reduce(0) { $0 + $1.cards.filter { $0.text != nil }.count }
        let rounds = store.roundCount(debate)
        let scope = rounds == 0 ? L("Solo risposte iniziali") : String(format: L("Risposte iniziali e %d round"), rounds)
        let count = answers == 1 ? L("1 risposta") : String(format: L("%d risposte"), answers)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Svolgimento")).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(scope + " · " + count)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(L("Espandi tutti"), symbol: "rectangle.expand.vertical",
                           help: L("Espandi tutti i round (⌥⌘→)")) { setAll(true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                IconButton(L("Comprimi tutti"), symbol: "rectangle.compress.vertical",
                           help: L("Comprimi tutti i round (⌥⌘←)")) { setAll(false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            }
        }
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

    /// Tappa del percorso: numero su una linea verticale, intestazione cliccabile, card sotto.
    private func phaseSection(_ p: PhaseState, number: Int, last: Bool) -> some View {
        let open = isExpanded(p.id)
        let state = store.phaseState(p, in: debate)
        let toggle = {
            if reduceMotion { setExpanded(p.id, !open) }
            else { withAnimation(.easeOut(duration: 0.18)) { setExpanded(p.id, !open) } }
        }
        return HStack(alignment: .top, spacing: 14) {
            StepMarker(number: number, state: state, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) {
                    PhaseHeader(eyebrow: store.phaseEyebrow(p.id, in: debate),
                                name: CouncilStore.phaseNames[p.id] ?? p.title,
                                description: CouncilStore.phaseDescriptions[p.id],
                                note: p.note, state: state, meta: phaseMeta(p, state),
                                expanded: open, canExpand: !p.cards.isEmpty,
                                reduceMotion: reduceMotion)
                }
                .buttonStyle(PhaseHeaderStyle())
                .disabled(p.cards.isEmpty)
                .accessibilityValue(p.cards.isEmpty ? "" : open ? L("espanso") : L("compresso"))
                .help(p.cards.isEmpty ? "" : open ? L("Comprimi la fase") : L("Espandi la fase"))

                if open && !p.cards.isEmpty {
                    CardsGrid(cards: p.cards, running: debate.isRunning, since: p.startedAt)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : 22)
            // Altezza piena del contenuto: nell'HStack le card non devono finire sopra l'intestazione.
            .fixedSize(horizontal: false, vertical: true)
        }
        // Linea del percorso: dal numero di questa tappa fino alla successiva.
        .background(alignment: .topLeading) {
            if !last {
                Rectangle()
                    .fill(Brand.hairline)
                    .frame(width: 2)
                    .padding(.top, 34)
                    .padding(.leading, 13)
                    .accessibilityHidden(true)
            }
        }
    }

    /// "3 di 5 risposte" durante la fase; "5 risposte · fino a 41 s" a fase chiusa.
    private func phaseMeta(_ p: PhaseState, _ state: StepState) -> String? {
        if p.cards.isEmpty { return nil }
        let arrived = p.cards.filter { !$0.waiting }.count
        if state == .current { return String(format: L("%d di %d risposte"), arrived, p.cards.count) }
        let answered = p.cards.filter { $0.text != nil }.count
        var parts = [answered == 1 ? L("1 risposta") : String(format: L("%d risposte"), answered)]
        let missing = p.cards.count - answered
        if missing > 0 { parts.append(String(format: L("%d senza risposta"), missing)) }
        if let longest = p.cards.compactMap(\.seconds).max() { parts.append(String(format: L("fino a %d s"), Int(longest.rounded()))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Intestazione di una fase

/// Fondo leggero al passaggio del mouse sull'intestazione cliccabile di una fase.
private struct PhaseHeaderStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HeaderBody(configuration: configuration) }

    struct HeaderBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.08 : hover ? 0.04 : 0)))
                // Il fondo sporge solo verso il percorso, a destra resta allineato alle card.
                .padding(.leading, -10)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Numero della tappa nel percorso: pieno se completata, contornato se in corso, tenue se saltata.
private struct StepMarker: View {
    let number: Int
    let state: StepState
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Brand.accent)
                Text("\(number)").foregroundStyle(.white)
            case .current:
                Circle().fill(Brand.surface)
                Circle().strokeBorder(Brand.accent, lineWidth: 2)
                Text("\(number)").foregroundStyle(Brand.accent)
            case .stopped:
                Circle().fill(Brand.surface)
                Circle().strokeBorder(Brand.warning, lineWidth: 1.5)
                Text("\(number)").foregroundStyle(Brand.warning)
            default:
                Circle().fill(Brand.surface)
                Circle().strokeBorder(Brand.hairline, lineWidth: 1.5)
                Text("\(number)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .frame(width: 28, height: 28)
        .padding(.top, 6)
        .symbolEffect(.pulse, isActive: state == .current && !reduceMotion)
        .accessibilityHidden(true)
    }
}

private struct PhaseHeader: View {
    let eyebrow: String
    let name: String
    let description: String?
    let note: String?
    let state: StepState
    let meta: String?
    let expanded: Bool
    let canExpand: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)

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
            .padding(.top, 2)

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 22)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel([eyebrow, name, PhaseStatusLabel.text(state), meta].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Stato di un round a parole con simbolo: il colore è solo una seconda codifica.
private struct PhaseStatusLabel: View {
    let state: StepState
    let reduceMotion: Bool

    static func text(_ s: StepState) -> String {
        switch s {
        case .done: return L("Completato")
        case .current: return L("In corso")
        case .pending: return L("In attesa")
        case .skipped: return L("Saltato")
        case .notRun: return L("Non svolto")
        case .stopped: return L("Interrotto")
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
                .foregroundStyle(state == .done ? AnyShapeStyle(Brand.success)
                                 : state == .current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, isActive: state == .current && !reduceMotion)
        }
        .font(.subheadline.weight(.medium))
    }
}

/// Esito del dibattito in una capsula: simbolo colorato e testo, fondo appena tinto.
private struct StatusBadge: View {
    let text: String
    let symbol: String
    let tint: Color
    var pulse = false

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: pulse)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Partecipante nell'intestazione: lettera anonima e nome del modello.
private struct ParticipantTag: View {
    let letter: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(letter)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.accent)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Brand.selection))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
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
                    Label(String(format: L("Fase %d di %d · %@"), currentIndex + 1, steps.count, s.short), systemImage: symbol(s.state))
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .help(L("Vai alla fase"))
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
                .help(String(format: L("Vai a: %@"), s.heading))
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

/// Card di un round su due colonne (una se la finestra è stretta). A differenza di LazyVGrid
/// le card della stessa riga hanno la stessa altezza: niente vuoti sotto la più corta.
private struct CardsGrid: View {
    let cards: [CardState]
    let running: Bool
    let since: Date?
    @State private var width: CGFloat = 0

    var body: some View {
        let cols = width >= 652 ? 2 : 1
        let rows = stride(from: 0, to: cards.count, by: cols).map { Array(cards[$0..<min($0 + cols, cards.count)]) }
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    ForEach(rows[i]) { c in
                        CardView(card: c, running: running, since: since)
                    }
                    if rows[i].count < cols {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

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
                    Text(String(format: L("Ha risposto %@ al posto di %@, che non ha risposto in tempo."), card.usedModel ?? L("un modello di riserva"), r))
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
                        Text(String(format: L("Ha saltato questo round e rientra nel prossimo: %@"), Self.reason(err)))
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
                        Image(systemName: "xmark.octagon").foregroundStyle(Brand.danger)
                    }
                    .font(.body)
                    .textSelection(.enabled)
                }
            } else if running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = since.map { max(0, Int(ctx.date.timeIntervalSince($0))) }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(secs.map { String(format: L("In attesa · %d s"), $0) } ?? L("In attesa"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(secs.map { String(format: L("%@, in attesa da %d secondi"), card.title, $0) } ?? String(format: L("%@, in attesa"), card.title))
                }
            } else {
                Label("Nessuna risposta: il dibattito si è fermato prima.", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        // maxHeight: nella griglia le card della stessa riga hanno la stessa altezza.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceBox(radius: 12)
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
