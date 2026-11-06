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
        .background(BrandBackground())
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
        case 5..<13: return "Buongiorno"
        case 13..<18: return "Buon pomeriggio"
        case 18..<24: return "Buonasera"
        default: return "Ciao, nottambulo"
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
                .font(.system(size: 34, weight: .regular, design: .serif))
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
            Text("Approfondimento di: \(p.question)")
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            IconButton("Togli approfondimento", symbol: "xmark",
                       help: "Togli il collegamento al dibattito precedente") { store.parent = nil }
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
                .focused($focused)
                .accessibilityLabel("Domanda")

            HStack(alignment: .bottom, spacing: 12) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    IconButton("Aggiungi modelli…", symbol: "plus",
                               help: store.lockedCount > 0
                                   ? "Aggiungi modelli: \(store.lockedCount) \(store.lockedCount == 1 ? "voce richiede" : "voci richiedono") una chiave API"
                                   : "Aggiungi modelli (scheda Modelli delle Impostazioni)",
                               action: openModels)
                    ForEach(store.voices) { v in
                        Toggle(store.displayName(v), isOn: Binding(get: { store.selected.contains(v.id) },
                                                                    set: { _ in store.toggle(v.id) }))
                            .toggleStyle(VoiceChipStyle(problem: v.problem, provider: v.provider))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Partecipano")

                sendButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
        .help("Avvia il dibattito (⌘↩)")
        .accessibilityLabel("Avvia il dibattito")
    }

    // MARK: Opzioni sotto il riquadro: menu leggeri e stima

    private var optionsRow: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Round", selection: $store.rounds) {
                    ForEach([0, 1, 2, 3], id: \.self) { r in
                        Text(CouncilStore.roundsTitles[r] ?? "\(r)").tag(r)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(store.rounds == 0 ? "Solo risposte" : "\(store.rounds) round",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Round di critica tra i modelli")
            .accessibilityLabel("Round")

            Menu {
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
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Giudice: \(store.judgeLabel)", systemImage: "checkmark.seal")
            }
            .help("Chi emette il verdetto")
            .accessibilityLabel("Giudice")

            Spacer(minLength: 8)
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
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(store.hint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Problemi dei modelli: simbolo + testo sempre visibile, con l'azione per risolverli
            if !troubled.isEmpty {
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
        .help(problem.map { "Problema: \($0)" } ?? provider)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityValue(problem.map { "problema: \($0)" } ?? (on ? "partecipa" : "escluso"))
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
        verdictBox(v).id("phase-verdict")
            .padding(.top, 20)
    }

    // MARK: Intestazione: domanda, meta, stato

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(debate.question)
                .font(.system(.title2, design: .serif).weight(.semibold))
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

            IconButton("Interrompi", symbol: "stop.circle",
                       help: "Interrompi (⌘.). Le risposte già arrivate restano salvate.") {
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
    private var actions: some View {
        HStack(spacing: 2) {
            IconButton(copied ? "Copiato" : "Copia verdetto", help: copied ? "Copiato" : "Copia verdetto") {
                guard let v = debate.verdict else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(v, forType: .string)
                copied = true
                AccessibilityNotification.Announcement("Verdetto copiato").post()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? AnyShapeStyle(Brand.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            IconButton("Esporta come Markdown…", symbol: "square.and.arrow.up") {
                if let e = store.exportMarkdown() { saveFile(e.filename, e.text) }
            }
            IconButton("Approfondisci…", symbol: "arrow.turn.down.right",
                       help: "Approfondisci: nuova domanda che parte da questo dibattito") {
                store.deepen()
            }
        }
    }

    // MARK: Verdetto: unico riquadro evidenziato

    private func verdictBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Brand.accent)
                        .accessibilityHidden(true)
                    Text("Verdetto del consiglio")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                    if let by = debate.verdictBy, !by.isEmpty {
                        Text("di \(by)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)
                actions
            }

            MarkdownView(text)
                .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceBox(radius: 16, stroke: Brand.accent.opacity(0.35), shadow: true)
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
            HStack(spacing: 2) {
                IconButton("Espandi tutti", symbol: "rectangle.expand.vertical",
                           help: "Espandi tutti i round (⌥⌘→)") { setAll(true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                IconButton("Comprimi tutti", symbol: "rectangle.compress.vertical",
                           help: "Comprimi tutti i round (⌥⌘←)") { setAll(false) }
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
                                 : state == .current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
