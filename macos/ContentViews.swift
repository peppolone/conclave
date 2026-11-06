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
                    Text(err).font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.hint).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !hasOtherVoices && store.engineReady {
                    Button("Aggiungi le chiavi API", action: openSettings)
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
        VStack(alignment: .leading, spacing: 12) {
            // a) Domanda
            ZStack(alignment: .topLeading) {
                if store.question.isEmpty {
                    Text("Fai una domanda al consiglio…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 0)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.question)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 72, maxHeight: 200)
                    .accessibilityLabel("Domanda")
            }

            // b) Partecipanti
            VStack(alignment: .leading, spacing: 6) {
                Text("Partecipano").font(.callout).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(store.voices) { v in
                        VoiceChip(title: store.displayName(v), on: store.selected.contains(v.id),
                                  problem: v.problem, provider: v.provider) { store.toggle(v.id) }
                    }
                    AddModelsChip(lockedCount: store.lockedCount, action: openModels)
                }
            }

            Divider()

            // c) Controlli
            HStack(spacing: 16) {
                Picker("Round", selection: $store.rounds) {
                    ForEach([3, 2, 1, 0], id: \.self) { r in
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

                if store.starting { ProgressView().controlSize(.small) }

                Button { Task { await store.start() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(store.canStart ? Color.accentColor : Color.secondary.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!store.canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Avvia dibattito (⌘↩)")
                .accessibilityLabel("Avvia dibattito")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
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

private struct VoiceChip: View {
    let title: String
    let on: Bool
    let problem: String?
    let provider: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(title)
                if let problem {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help(problem)
                        .accessibilityLabel(problem)
                }
            }
            .font(.callout)
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(problem.map { "\(provider) — \($0)" } ?? provider)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "partecipa" : "non partecipa")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct AddModelsChip: View {
    let lockedCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Aggiungi modelli", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(lockedCount > 0
              ? "\(lockedCount) \(lockedCount == 1 ? "voce richiede" : "voci richiedono") una chiave API"
              : "Apri la scheda Modelli delle Impostazioni")
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

    private var failed: Bool { ["failed", "cancelled", "interrupted"].contains(debate.status) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if debate.verdict != nil { actions }
                if let v = debate.verdict { verdictBox(v) }
                ForEach(debate.phases) { p in phaseSection(p) }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // Domanda, meta e stato
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(debate.question)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if debate.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(store.meta(debate)).foregroundStyle(.secondary)
                }
            } else {
                Text(store.meta(debate)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if debate.isRunning { ProgressView().controlSize(.small) }
                Text(debate.statusText)
                    .foregroundStyle(debate.status == "done" ? Color.green : (failed ? Color.red : Color.secondary))
                if debate.isRunning {
                    Button("Annulla") { Task { await store.cancel() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .font(.callout)
        }
    }

    // Copia, esporta, approfondisci
    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                guard let v = debate.verdict else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(v, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copiato" : "Copia verdetto", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button {
                if let e = store.exportMarkdown() { saveFile(e.filename, e.text) }
            } label: {
                Label("Esporta Markdown…", systemImage: "square.and.arrow.down")
            }
            Button {
                store.deepen()
            } label: {
                Label("Approfondisci", systemImage: "arrow.turn.down.right")
            }
            .help("Nuova domanda che parte da questo dibattito")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func verdictBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Verdetto del consiglio").font(.headline).foregroundStyle(Color.accentColor)
                if let by = debate.verdictBy, !by.isEmpty {
                    Text("di \(by)").foregroundStyle(.secondary)
                }
            }
            MarkdownView(text)
        }
        .padding(.vertical, 14)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func phaseSection(_ p: PhaseState) -> some View {
        let binding = Binding<Bool>(
            get: { expanded[p.id] ?? (debate.verdict == nil) },
            set: { expanded[p.id] = $0 }
        )
        return DisclosureGroup(isExpanded: binding) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(p.cards) { c in CardView(card: c) }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.title).font(.headline)
                if let n = p.note { Text(n).font(.callout).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .onTapGesture { binding.wrappedValue.toggle() }
        }
    }
}

private struct CardView: View {
    let card: CardState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title).fontWeight(.semibold)
                Spacer(minLength: 6)
                if let s = card.seconds {
                    Text(String(format: "%.1f s", s)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let m = card.usedModel {
                Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let r = card.replaced {
                Label {
                    Text("Ha risposto \(card.usedModel ?? "un modello di riserva") al posto di \(r), che non ha risposto in tempo.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            }

            if let text = card.text {
                MarkdownView(text, baseFont: .callout)
            } else if let err = card.error {
                if card.skipped {
                    Text("Ha saltato questo round e rientra nel prossimo: \(Self.reason(err))")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Escluso dal dibattito: \(err)")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("sta scrivendo…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// L'errore del motore è "ha saltato questo round (<motivo>)": si mostra solo il motivo.
    static func reason(_ err: String) -> String {
        guard err.hasPrefix("ha saltato"), let open = err.firstIndex(of: "("), err.hasSuffix(")") else { return err }
        return String(err[err.index(after: open)..<err.index(before: err.endIndex)])
    }
}
