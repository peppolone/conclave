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

// MARK: - Pezzi comuni ai due riquadri di scrittura (composer e domanda di seguito)

/// "15.234 / 20.000": compare vicino al limite; colore di avviso, di pericolo oltre il limite.
private struct QuestionCounter: View {
    let length: Int
    /// Spiegazione oltre il limite (dice cosa non si può fare finché la domanda è troppo lunga).
    let overHelp: String

    var body: some View {
        let n = length, max = AttachmentLimits.maxQuestion
        if n > AttachmentLimits.questionWarning {
            HStack {
                Spacer()
                Text(verbatim: "\(formatCount(n)) / \(formatCount(max))")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(n > max ? Brand.danger : Brand.warning)
                    .help(n > max ? overHelp : String(format: L("La domanda può avere al massimo %@ caratteri."), formatCount(max)))
                    .accessibilityLabel(String(format: L("%@ caratteri su %@"), formatCount(n), formatCount(max)))
            }
        }
    }
}

/// Pulsante rotondo d'invio con la freccia (⌘↩); rotella mentre si invia.
private struct SendButton: View {
    let enabled: Bool
    let busy: Bool
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(enabled ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.12)))
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Graffetta: sceglie i file da allegare (al massimo `AttachmentLimits.maxFiles`).
private struct AttachButton: View {
    let count: Int
    let add: ([URL]) -> Void

    var body: some View {
        IconButton(L("Allega file…"), symbol: "paperclip",
                   help: String(format: L("Allega PDF, file di testo o immagini (al massimo %d). Puoi anche trascinarli qui o incollarli."),
                                AttachmentLimits.maxFiles)) {
            chooseAttachments(add)
        }
        .disabled(count >= AttachmentLimits.maxFiles)
    }
}

/// Avvisi sugli allegati: limite raggiunto o file non supportato, e cosa impedisce l'invio.
private struct AttachmentWarnings: View {
    let notice: String?
    let items: [AttachmentItem]

    var body: some View {
        if let n = notice {
            Label(n, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Brand.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let p = CouncilStore.problem(of: items), !items.contains(where: \.loading) {
            Label(p, systemImage: "exclamationmark.circle")
                .foregroundStyle(Brand.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Riquadro di scrittura: superficie con ombra, bordo d'accento con il fuoco o con file trascinati
/// sopra, e rilascio dei file come allegati.
private struct ComposerSurface: ViewModifier {
    let focused: Bool
    @Binding var dropTargeted: Bool
    let add: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .surfaceBox(radius: Brand.Radius.composer,
                        stroke: dropTargeted ? Brand.accent : focused ? Brand.accent.opacity(0.45) : Brand.hairline, shadow: true)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Brand.Radius.composer, style: .continuous)
                        .fill(Brand.accent.opacity(0.06))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                add(files)
                return true
            } isTargeted: { dropTargeted = $0 }
    }
}

private extension View {
    func composerSurface(focused: Bool, dropTargeted: Binding<Bool>, add: @escaping ([URL]) -> Void) -> some View {
        modifier(ComposerSurface(focused: focused, dropTargeted: dropTargeted, add: add))
    }
}

// MARK: - Composer

struct ComposerView: View {
    @ObservedObject var store: CouncilStore
    var openSettings: () -> Void
    var openModels: () -> Void
    @FocusState private var focused: Bool
    /// File trascinati sopra il riquadro della domanda.
    @State private var dropTargeted = false
    @State private var pasteMonitor = AttachmentPasteMonitor()

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
        .onAppear {
            focused = true
            pasteMonitor.start { [store] urls, image in
                if let image { store.addPastedImage(image) } else { store.addAttachments(urls) }
            }
        }
        .onDisappear { pasteMonitor.stop() }
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

            if !store.attachments.isEmpty {
                AttachmentChips(items: store.attachments) { store.removeAttachment($0) }
            }

            QuestionCounter(length: store.questionLength,
                            overHelp: String(format: L("La domanda supera il limite di %@ caratteri: accorciala per avviare il dibattito."),
                                             formatCount(AttachmentLimits.maxQuestion)))

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

                AttachButton(count: store.attachments.count) { store.addAttachments($0) }

                SendButton(enabled: store.canStart, busy: store.starting, label: L("Avvia il dibattito"),
                           help: store.questionTooLong
                               ? String(format: L("La domanda supera il limite di %@ caratteri: accorciala per avviare il dibattito."), formatCount(AttachmentLimits.maxQuestion))
                               : store.attachmentProblem ?? L("Avvia il dibattito (⌘↩)")) {
                    Task { await store.start() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .composerSurface(focused: focused, dropTargeted: $dropTargeted) { store.addAttachments($0) }
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
                Label(CouncilStore.roundsLabel(store.rounds), systemImage: "arrow.triangle.2.circlepath")
            }
            .help(L("Velocità: quanti round di critica tra i modelli prima del verdetto"))
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

            Toggle(isOn: $store.webSearch) {
                Label(L("Cerca sul web"), systemImage: "globe")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!store.webSearchAvailable)
            .help(store.webSearchHelp)
            .accessibilityLabel(L("Cerca sul web"))
            .accessibilityHint(store.webSearchHelp)

            Spacer(minLength: 8)

            if store.canEstimate {
                Label(String(format: L("%d chiamate + 1 verdetto"), store.estimatedCalls)
                        + (store.estimatedTime.map { " · " + $0 } ?? ""),
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
            AttachmentWarnings(notice: store.attachmentNotice, items: store.attachments)
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
    /// Verdetto appena copiato ("verdict" o "turn-<n>"), per la spunta sul pulsante.
    @State private var copiedKey: String?
    /// Domande di seguito viste dal vivo: le loro fasi restano aperte anche a turno concluso.
    @State private var liveTurns: Set<Int>
    /// Domanda lunga mostrata per intero nell'intestazione.
    @State private var questionExpanded = false
    /// Dibattito seguito dal vivo: i round restano aperti anche quando arriva il verdetto,
    /// così la posizione di lettura non cambia.
    @State private var watchedLive: Bool
    /// true finché si segue il dibattito dal vivo (l'utente non ha scorso in su per rileggere).
    @State private var following = true
    @State private var userScrolling = false
    /// true quando la vista è lontana dal fondo (più di 300 punti). Solo un booleano: cambia di
    /// rado, mentre la distanza cambierebbe a ogni scatto e ricalcolerebbe tutta la vista.
    @State private var awayFromBottom = false
    /// Agganciato in fondo (dibattito concluso), come `isPinned` della chat di Claude: finché vale,
    /// ogni cambio di altezza del contenuto riporta subito in fondo ("resnap"). Serve perché la
    /// pila pigra stima le altezze delle righe non ancora costruite e il primo salto può sbagliare.
    @State private var pinnedBottom = false
    /// Larghezza della colonna del contenuto: decide le card per riga.
    @State private var contentWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: CouncilStore, debate: DebateState, saveFile: @escaping (_ filename: String, _ text: String) -> Void) {
        self.store = store
        self.debate = debate
        self.saveFile = saveFile
        _watchedLive = State(initialValue: debate.isRunning)
        _liveTurns = State(initialValue: Set(debate.turns.filter(\.isRunning).map(\.turn)))
    }

    /// Domanda di seguito in corso, se c'è.
    private var runningTurn: Int? { debate.turns.last(where: \.isRunning)?.turn }

    private var steps: [DebateStep] { store.steps(debate) }

    var body: some View {
        ScrollViewReader { proxy in
          // Come la chat di Claude: il contenuto scorre sopra, il campo della domanda di seguito
          // resta fisso sotto (fuori dalla vista che scorre).
          VStack(spacing: 0) {
            ScrollView {
                // Pila pigra, come la chat di Claude: si costruiscono solo le righe vicine alla parte
                // visibile. Ogni fase si scompone in righe (intestazione e una riga per coppia di
                // card), così anche un round lungo non va misurato tutto insieme.
                LazyVStack(alignment: .leading, spacing: 0) {
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
                        verdictBox(v, by: debate.verdictBy, confidence: debate.confidence).id("phase-verdict")
                            .padding(.top, 24)
                            .transition(.opacity)
                    } else if debate.isRunning && debate.judging {
                        // Segnaposto al posto del verdetto: la vista dal vivo sale qui mentre il giudice scrive.
                        judgingPlaceholder
                            .id("phase-verdict")
                            .padding(.top, 24)
                    }

                    if !debate.phases.isEmpty {
                        courseHeading.padding(.top, debate.verdict != nil ? 40 : 28)
                            .padding(.bottom, 16)
                        ForEach(Array(debate.phases.enumerated()), id: \.element.id) { i, p in
                            phaseRows(p, number: i + 1, last: i == debate.phases.count - 1)
                        }
                    }

                    // Domande di seguito, in ordine, dopo il dibattito originale.
                    ForEach(debate.turns, id: \.turn) { t in
                        turnRows(t)
                    }

                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Si segue il dibattito come in una chat: a ogni nuovo round (e al verdetto) la vista
            // scende all'inizio della nuova sezione, così si legge dall'inizio. Lo stato
            // "agganciato" segue le regole della chat di Claude: basta scorrere in su di 2 punti
            // per sganciarsi e rileggere, e si torna agganciati appena l'utente riporta la vista in
            // fondo (nessuna soglia ampia, nessuna attesa della fine dello scorrimento). Solo lo
            // scorrimento dell'utente cambia `following`: la crescita del contenuto e gli
            // scorrimenti del programma non lo toccano.
            .onScrollPhaseChange { _, new in
                userScrolling = new == .interacting || new == .decelerating
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(offset: g.contentOffset.y,
                              distance: max(0, g.contentSize.height - g.visibleRect.maxY),
                              height: g.contentSize.height)
            } action: { old, new in
                let away = new.distance > 300
                if away != awayFromBottom { awayFromBottom = away }
                if userScrolling {
                    if new.offset < old.offset - 2 { following = false; pinnedBottom = false }
                    else if new.distance <= 2 { following = true; pinnedBottom = true }
                } else if pinnedBottom, !debate.isRunning, new.distance > 2 || new.height != old.height {
                    // Resnap di Claude: agganciati in fondo, si resta in fondo anche quando le
                    // righe appena costruite hanno un'altezza diversa da quella stimata.
                    proxy.scrollTo(Self.endID, anchor: .bottom)
                }
            }
            .onChange(of: sectionKey) {
                guard watchedLive, following else { return }
                // Si va al verdetto in cima, non in fondo: niente resnap al termine del dibattito.
                if debate.verdict != nil || debate.judging { pinnedBottom = false }
                Task { @MainActor in
                    // Si attende il layout della nuova sezione prima di scorrere.
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToLatest(proxy)
                }
            }
            // Come nella chat di Claude: un pulsante rotondo con la freccia, in basso al centro,
            // compare quando non si è in fondo (dal vivo: quando ci si è sganciati).
            .overlay(alignment: .bottom) {
                let live = debate.isRunning
                let show = live ? !following : awayFromBottom
                ZStack {
                if show {
                    let up = live && debate.judging
                    let title = live ? (up ? L("Vai al verdetto") : L("Vai al round in corso")) : L("Vai in fondo")
                    Button {
                        if live {
                            following = true
                            scrollToLatest(proxy)
                        } else {
                            // Come `scrollToBottom` di Claude: salto immediato e aggancio.
                            pinnedBottom = true
                            proxy.scrollTo(Self.endID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: up ? "arrow.up" : "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .background(Circle().fill(.background))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .help(title)
                    .accessibilityLabel(title)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: show)
            }

            if store.canFollowUp(debate) {
                FollowupBar(store: store, debate: debate)
            }
          }
          // Inviata una domanda di seguito: si va in fondo e si resta agganciati mentre arriva la
          // risposta (resnap di `pinnedBottom`), come nella chat di Claude.
          .onChange(of: debate.turns.count) { old, new in
              guard new > old, runningTurn != nil else { return }
              pinnedBottom = true
              Task { @MainActor in
                  try? await Task.sleep(for: .milliseconds(60))
                  proxy.scrollTo(Self.endID, anchor: .bottom)
              }
          }
          .onChange(of: runningTurn) { old, n in
              if let n { liveTurns.insert(n) }
              // Turno del consiglio concluso mentre lo si seguiva (agganciati in fondo): si sale al suo
              // verdetto, poi le fasi sotto si comprimono. Comprimere dopo lo scorrimento tocca solo
              // righe sotto il verdetto, quindi ciò che si sta leggendo non si sposta.
              guard n == nil, let o = old, pinnedBottom,
                    let t = debate.turns.first(where: { $0.turn == o }), !t.isQuick, t.verdict != nil else { return }
              pinnedBottom = false
              if reduceMotion { proxy.scrollTo("turn-\(o)-verdict", anchor: .top) }
              else { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("turn-\(o)-verdict", anchor: .top) } }
              Task { @MainActor in
                  try? await Task.sleep(for: .milliseconds(500))
                  liveTurns.remove(o)
              }
          }
          // Dibattito concluso mentre lo si seguiva: la vista è già sul verdetto (in cima allo
          // svolgimento); a scorrimento finito le fasi sotto si comprimono, come in un dibattito
          // aperto dalla cronologia. Chi stava rileggendo un round (sganciato) lo ritrova aperto.
          .onChange(of: debate.isRunning) { was, now in
              guard was, !now, watchedLive, following, debate.verdict != nil else { return }
              pinnedBottom = false
              Task { @MainActor in
                  try? await Task.sleep(for: .milliseconds(500))
                  guard following else { return }
                  watchedLive = false
              }
          }
        }
    }

    private static let endID = "debate-end"

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat
        var distance: CGFloat
        var height: CGFloat
    }

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

            if !debate.attachments.isEmpty {
                AttachmentTags(items: debate.attachments)
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
    private func actions(_ verdict: String, key: String) -> some View {
        let copied = copiedKey == key
        return HStack(spacing: 2) {
            IconButton(copied ? L("Copiato") : L("Copia verdetto")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(verdict, forType: .string)
                copiedKey = key
                AccessibilityNotification.Announcement(L("Verdetto copiato")).post()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if copiedKey == key { copiedKey = nil }
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
        }
    }

    /// Segnaposto mentre il giudice scrive il verdetto.
    private var judgingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("Il giudice sta scrivendo il verdetto…"))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceBox(radius: Brand.Radius.panel, stroke: Brand.accent.opacity(0.28))
    }

    // MARK: Verdetto: scheda protagonista

    private func verdictBox(_ text: String, by verdictBy: String?, confidence: String?, key: String = "verdict") -> some View {
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
                    if let by = verdictBy, !by.isEmpty {
                        Text(String(format: L("Giudice: %@"), by))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let c = CouncilStore.confidenceText(confidence) {
                    // Affidabilità secondo il giudice: testo e simbolo, il colore è solo una seconda codifica.
                    StatusBadge(text: c,
                                symbol: confidence == "alta" ? "checkmark.shield.fill"
                                    : confidence == "media" ? "exclamationmark.shield.fill" : "xmark.shield.fill",
                                tint: confidence == "alta" ? Brand.success : confidence == "media" ? Brand.warning : Brand.danger)
                        .fixedSize()
                        .help(L("Quanto il giudice ritiene affidabile la risposta: accordo tra i modelli, solidità degli argomenti e punti da verificare."))
                }

                Spacer(minLength: 8)
                actions(text, key: key)
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
        let answers = debate.phases.filter { $0.id != "research" }.reduce(0) { $0 + $1.cards.filter { $0.text != nil }.count }
        let rounds = store.roundCount(debate)
        let scope = rounds == 0 ? L("Solo risposte iniziali") : (rounds == 1 ? L("Risposte iniziali e 1 round") : String(format: L("Risposte iniziali e %d round"), rounds))
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

    /// Fase aperta? Scelta dell'utente o, in mancanza, aperta dal vivo o finché manca il risultato.
    private func isExpanded(_ key: String, in t: DebateState? = nil) -> Bool {
        let fallback = t.map { liveTurns.contains($0.turn) || $0.isRunning || ($0.verdict == nil && $0.answer?.text == nil) }
            ?? (watchedLive || debate.verdict == nil)
        return expanded[key] ?? store.expandedPhases[debate.id]?[key] ?? fallback
    }

    private func setExpanded(_ id: String, _ open: Bool) {
        expanded[id] = open
        store.expandedPhases[debate.id, default: [:]][id] = open
    }

    /// Tappa del percorso: numero su una linea verticale, intestazione cliccabile, card sotto.
    /// Restituisce più righe (intestazione + una riga per coppia di card) perché la pila pigra
    /// costruisca solo quelle visibili; la linea del percorso è disegnata riga per riga.
    /// `t`: turno di una domanda di seguito (nil = dibattito originale); le sue righe hanno
    /// identità e stato di apertura propri ("turn-<n>-…").
    @ViewBuilder
    private func phaseRows(_ p: PhaseState, number: Int, last: Bool, in t: DebateState? = nil) -> some View {
        let d = t ?? debate
        let prefix = t.map { "turn-\($0.turn)-" } ?? ""
        let key = prefix + p.id
        let open = isExpanded(key, in: t)
        let state = store.phaseState(p, in: d)
        let toggle = {
            if reduceMotion { setExpanded(key, !open) }
            else { withAnimation(.easeOut(duration: 0.18)) { setExpanded(key, !open) } }
        }
        // Card per riga: due se la colonna delle card (contenuto meno numero e spazio) è larga.
        // La ricerca ha una sola card (il dossier): sempre a tutta larghezza.
        let cols = p.id != "research" && contentWidth - 42 >= 652 ? 2 : 1
        let rows = open && !p.cards.isEmpty
            ? stride(from: 0, to: p.cards.count, by: cols).map { Array(p.cards[$0..<min($0 + cols, p.cards.count)]) }
            : []
        let gap: CGFloat = last ? 0 : 22

        TimelineRow(line: !last, lineTop: 34, bottom: rows.isEmpty ? gap : 0) {
            StepMarker(number: number, state: state, reduceMotion: reduceMotion)
        } content: {
            Button(action: toggle) {
                // Fase chiusa e non in corso: una sola riga con il riassunto (es. "Round 2 — Revisione:
                // A cambiamenti sostanziali, B nessun cambiamento").
                PhaseHeader(eyebrow: store.phaseEyebrow(p.id, in: d),
                            name: CouncilStore.phaseNames[p.id] ?? p.title,
                            description: CouncilStore.phaseDescriptions[p.id],
                            note: p.note, state: state, meta: phaseMeta(p, state),
                            expanded: open, canExpand: !p.cards.isEmpty,
                            reduceMotion: reduceMotion,
                            compact: open || state == .current ? nil
                                : (title: compactTitle(p), summary: store.phaseSummary(p, in: d)))
            }
            .buttonStyle(PhaseHeaderStyle())
            .disabled(p.cards.isEmpty)
            .accessibilityValue(p.cards.isEmpty ? "" : open ? L("espanso") : L("compresso"))
            .help(p.cards.isEmpty ? "" : open ? L("Comprimi la fase") : L("Espandi la fase"))
        }
        .id("\(prefix)phase-\(p.id)")

        // Identità che cambia con le colonne: passando da 1 a 2 card per riga la pila pigra non
        // deve riusare l'altezza misurata per la riga a card singola (il testo uscirebbe dalla card).
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
            TimelineRow(line: !last, lineTop: 0, top: i == 0 ? 10 : 12, bottom: i == rows.count - 1 ? gap : 0) {
                Color.clear.frame(width: 28, height: 0)
            } content: {
                CardsRow(cards: row, cols: cols, running: d.isRunning, since: p.startedAt)
            }
            .id("\(prefix)\(p.id)-\(cols)-\(i)")
            .transition(.opacity)
        }
    }

    /// Nome della fase nella riga compressa: "Risposte iniziali", "Round 2 — Revisione".
    private func compactTitle(_ p: PhaseState) -> String {
        let name = CouncilStore.phaseNames[p.id] ?? p.title
        guard let i = CouncilStore.phaseOrder.firstIndex(of: p.id), i > 0 else { return name }
        return String(format: L("Round %d — %@"), i, name)
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

extension DebateView {
    // MARK: Domande di seguito

    /// Un turno di seguito come righe della pila pigra: domanda, eventuale ricerca, poi la risposta
    /// rapida o le fasi del consiglio con il verdetto. Ogni riga ha un'identità con il turno.
    @ViewBuilder
    fileprivate func turnRows(_ t: DebateState) -> some View {
        let n = t.turn
        TurnQuestion(turn: t)
            .id("turn-\(n)-question")
            .padding(.top, 40)
            .padding(.bottom, 16)

        if t.isQuick {
            ForEach(Array(t.phases.enumerated()), id: \.element.id) { i, p in
                phaseRows(p, number: i + 1, last: i == t.phases.count - 1, in: t)
            }
            if let a = t.answer {
                CardView(card: a, running: t.isRunning, since: t.startedAt)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(format: L("Risposta alla domanda di seguito %d"), n))
                    .id("turn-\(n)-answer")
                    .padding(.top, t.phases.isEmpty ? 0 : 20)
            } else {
                turnStatus(t).id("turn-\(n)-status")
            }
        } else {
            // Turno del consiglio: come il dibattito originale, il verdetto (o il segnaposto mentre il
            // giudice scrive) viene subito dopo la domanda, lo svolgimento sotto.
            let gap: CGFloat = t.phases.isEmpty ? 0 : 28
            if let v = t.verdict {
                verdictBox(v, by: t.verdictBy, confidence: t.confidence, key: "turn-\(n)")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(format: L("Verdetto della domanda di seguito %d"), n))
                    .id("turn-\(n)-verdict")
                    .padding(.bottom, gap)
            } else if t.isRunning && t.judging {
                judgingPlaceholder.id("turn-\(n)-verdict").padding(.bottom, gap)
            } else if !t.isRunning || t.phases.isEmpty {
                turnStatus(t).id("turn-\(n)-status").padding(.bottom, gap)
            }
            ForEach(Array(t.phases.enumerated()), id: \.element.id) { i, p in
                phaseRows(p, number: i + 1, last: i == t.phases.count - 1, in: t)
            }
        }
    }

    /// Stato del turno senza risultato: in attesa (con la rotella) o fermato, con il motivo.
    fileprivate func turnStatus(_ t: DebateState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if t.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: t.status == "failed" ? "xmark.octagon" : "stop.circle")
                    .foregroundStyle(t.status == "failed" ? AnyShapeStyle(Brand.danger) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            Text(t.isRunning ? t.statusText : (t.status == "done" ? L("Nessuna risposta.") : t.statusText))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceBox(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Domanda di seguito: fumetto a destra come nella chat di Claude, con gli allegati del turno.
private struct TurnQuestion: View {
    let turn: DebateState

    private var kind: String {
        turn.isQuick ? L("Domanda di seguito · risposta rapida") : L("Domanda di seguito · il consiglio ridiscute")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Label(kind, systemImage: turn.isQuick ? "bolt" : "person.3")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(turn.question)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous).fill(Brand.selection))
                .accessibilityLabel(L("Domanda") + ": " + turn.question)
            if !turn.attachments.isEmpty {
                AttachmentTags(items: turn.attachments)
            }
        }
        .frame(maxWidth: 640, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: L("Domanda di seguito %d"), turn.turn) + (turn.isQuick ? "" : ", " + L("il consiglio ridiscute")))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Campo della domanda di seguito (fisso in fondo alla discussione)

private struct FollowupBar: View {
    @ObservedObject var store: CouncilStore
    let debate: DebateState
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var pasteMonitor = AttachmentPasteMonitor()

    /// Una domanda di seguito è in corso: il campo aspetta e c'è il pulsante per fermare.
    private var running: Bool { debate.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            box
            VStack(alignment: .leading, spacing: 4) {
                AttachmentWarnings(notice: store.followupNotice, items: store.followupAttachments)
                if store.followupMode == "council" && store.councilModels(debate).count < 2 {
                    Label(L("Per rilanciare il consiglio servono almeno 2 partecipanti della discussione ancora disponibili."),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(Brand.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let e = store.followupError {
                    Label(e, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Brand.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear {
            pasteMonitor.start { [store] urls, image in
                if let image { store.addPastedImage(image, to: .followup) } else { store.addAttachments(urls, to: .followup) }
            }
        }
        .onDisappear { pasteMonitor.stop() }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Domanda di seguito", text: $store.followup,
                      prompt: running ? Text("Attendi la risposta…") : Text("Chiedi ancora qualcosa su questa discussione…"),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .lineSpacing(2)
                .focused($focused)
                .disabled(running || store.sendingFollowup)
                .accessibilityLabel(L("Domanda di seguito"))

            if !store.followupAttachments.isEmpty {
                AttachmentChips(items: store.followupAttachments) { store.removeAttachment($0, from: .followup) }
            }

            QuestionCounter(length: store.followupLength,
                            overHelp: String(format: L("La domanda supera il limite di %@ caratteri: accorciala per inviarla."),
                                             formatCount(AttachmentLimits.maxQuestion)))

            HStack(spacing: 12) {
                AttachButton(count: store.followupAttachments.count) { store.addAttachments($0, to: .followup) }
                    .disabled(running)

                Toggle(isOn: $store.followupWebSearch) {
                    Label(L("Cerca sul web"), systemImage: "globe")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!store.webSearchAvailable || running)
                .help(webHelp)
                .accessibilityLabel(L("Cerca sul web"))
                .accessibilityHint(webHelp)

                Spacer(minLength: 8)

                responderMenu

                if running {
                    Button { Task { await store.cancel() } } label: {
                        ZStack {
                            Circle().fill(Brand.accent)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Interrompi (⌘.). Le risposte già arrivate restano salvate."))
                    .accessibilityLabel(L("Interrompi"))
                } else {
                    SendButton(enabled: store.canSendFollowup, busy: store.sendingFollowup, label: L("Invia la domanda"),
                               help: store.followupProblem(debate) ?? L("Invia la domanda (⌘↩)")) {
                        Task { await store.sendFollowup() }
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .composerSurface(focused: focused, dropTargeted: $dropTargeted) { store.addAttachments($0, to: .followup) }
    }

    private var webHelp: String {
        store.webSearchAvailable
            ? L("Prima di rispondere un modello cerca sul web informazioni aggiornate.")
            : L("Ricerca sul web non disponibile: nessun modello configurato può cercare sul web.")
    }

    private var roundsText: String {
        let r = debate.rounds ?? store.rounds
        return r == 0 ? L("senza round") : (r == 1 ? L("1 round") : String(format: L("%d round"), r))
    }

    /// Chi risponde: risposta rapida di un modello (predefinito il giudice) o tutto il consiglio.
    private var responderMenu: some View {
        let council = store.followupMode == "council"
        let label = council ? L("Rilancia il consiglio")
            : String(format: L("Risposta rapida: %@"), store.quickResponder(debate).label)
        return Menu {
            Picker("Chi risponde", selection: whoBinding) {
                Section("Risposta rapida") {
                    Text(String(format: L("Giudice della discussione (%@)"), store.discussionJudge(debate).label)).tag("quick|")
                    ForEach(store.claudeModels, id: \.self) { m in
                        Text(verbatim: "Claude \(m.capitalized)").tag("quick|claude:\(m)")
                    }
                    ForEach(store.voices.filter { !$0.isClaude }) { v in
                        Text(v.label).tag("quick|voice:\(v.id)")
                    }
                }
                Section("Tutto il consiglio") {
                    Text(L("Rilancia il consiglio") + " · " + String(format: L("%d modelli"), store.councilModels(debate).count)
                         + " · " + roundsText).tag("council")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(label, systemImage: council ? "person.3" : "bolt")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(running)
        .help(council
              ? L("Il consiglio ridiscute la domanda con gli stessi partecipanti e round, poi il giudice emette un nuovo verdetto.")
              : L("Un solo modello risponde subito, tenendo conto del dibattito."))
        .accessibilityLabel(L("Chi risponde"))
        .accessibilityValue(label)
    }

    /// Valore unico del menu: "council" oppure "quick|" + scelta del modello ("" = giudice).
    private var whoBinding: Binding<String> {
        Binding(
            get: {
                guard store.followupMode != "council" else { return "council" }
                let r = store.responder
                let valid = r.hasPrefix("claude:") ? store.claudeModels.contains(String(r.dropFirst(7)))
                    : r.hasPrefix("voice:") ? store.voices.contains { $0.id == String(r.dropFirst(6)) } : false
                return "quick|" + (valid ? r : "")
            },
            set: { tag in
                if tag == "council" {
                    store.followupMode = "council"
                } else {
                    store.followupMode = "quick"
                    store.responder = String(tag.dropFirst(6))
                }
            }
        )
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
    /// Fase compressa: titolo e riassunto in una riga al posto dell'intestazione completa.
    var compact: (title: String, summary: String?)? = nil

    var body: some View {
        if let compact { compactBody(compact) } else { fullBody }
    }

    private func compactBody(_ c: (title: String, summary: String?)) -> some View {
        var line = AttributedString(c.title)
        line.font = .headline
        if let s = c.summary, !s.isEmpty {
            var rest = AttributedString(": " + s)
            rest.font = .callout
            rest.foregroundColor = .secondary
            line += rest
        }
        return HStack(alignment: .center, spacing: 12) {
            Text(line)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            // Il segno di completato è implicito; gli altri stati restano scritti.
            if state != .done {
                PhaseStatusLabel(state: state, reduceMotion: reduceMotion).fixedSize()
            }
            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 22)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel([c.title, state == .done ? nil : PhaseStatusLabel.text(state), c.summary].compactMap { $0 }.joined(separator: ", "))
    }

    private var fullBody: some View {
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

/// Riga del percorso: colonna con numero (o vuota) e linea verticale, contenuto a destra.
/// La linea copre anche i margini della riga, così le righe di una fase la rendono continua.
private struct TimelineRow<Marker: View, Content: View>: View {
    let line: Bool
    let lineTop: CGFloat
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    @ViewBuilder var marker: Marker
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            marker
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                // Altezza piena del contenuto: le card non devono finire sopra l'intestazione.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, top)
        .padding(.bottom, bottom)
        .background(alignment: .topLeading) {
            if line {
                Rectangle()
                    .fill(Brand.hairline)
                    .frame(width: 2)
                    .padding(.top, lineTop)
                    .padding(.leading, 13)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Una riga di card (due colonne, una se la finestra è stretta). Le card della stessa riga
/// hanno la stessa altezza: niente vuoti sotto la più corta.
private struct CardsRow: View {
    let cards: [CardState]
    let cols: Int
    let running: Bool
    let since: Date?

    var body: some View {
        // Grid e non HStack: misura il testo alla larghezza finale della colonna, mentre l'HStack
        // con fixedSize poteva stimare un'altezza più bassa e far uscire il testo dalla card.
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(cards) { c in
                    CardView(card: c, running: running, since: since)
                }
                if cards.count < cols {
                    Color.clear
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .gridCellUnsizedAxes(.vertical)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
                        Text(String(format: "%.1f s", locale: AppLanguage.locale, s))
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
                } else if card.id.hasPrefix("research") {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ricerca sul web non riuscita").fontWeight(.semibold)
                            Text(err).foregroundStyle(.secondary)
                            Text("Il dibattito continua senza i risultati della ricerca.").foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.warning)
                    }
                    .font(.body)
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
