// Barra laterale nativa (NSSplitViewController → Liquid Glass su macOS 26):
// in cima "Nuova discussione" e la ricerca, poi la cronologia per data,
// in fondo una barra fissa con il marchio e il pulsante Impostazioni.

import AppKit
import SwiftUI

struct DebateSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let question: String
    let title: String?
    let status: String
    let created_at: String
    let parent_id: Int?
    var displayTitle: String { debateTitle(title, question: question) }
}

@MainActor
final class SidebarModel: ObservableObject {
    @Published var items: [DebateSummary] = []
    @Published var query = ""
    /// Campo di ricerca mostrato in cima alla barra laterale (si apre dalla lente nella toolbar o con ⌘F).
    @Published var searchVisible = false
    @Published var selected: Int?
    /// Discussione per cui è aperta la conferma di eliminazione.
    @Published var pendingDelete: DebateSummary?
    /// true dopo il primo caricamento riuscito: prima non si mostra lo stato vuoto.
    @Published var loaded = false

    let port: () -> Int
    var onOpen: ((Int) -> Void)?
    var onDeleted: ((Int) -> Void)?
    var onExport: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Campo di ricerca nativo, per portarci il fuoco con ⌘F.
    weak var searchField: NSSearchField?
    private var searchTask: Task<Void, Never>?

    init(port: @escaping () -> Int) { self.port = port }

    private func url(_ path: String) -> URL? {
        let p = port()
        return p > 0 ? URL(string: "http://127.0.0.1:\(p)\(path)") : nil
    }

    func reload() {
        searchTask?.cancel()
        searchTask = Task {
            let q = query.trimmingCharacters(in: .whitespaces)
            var path = "/api/debates"
            if !q.isEmpty, let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { path += "?q=\(enc)" }
            guard let u = url(path),
                  let (data, _) = try? await URLSession.shared.data(from: u),
                  !Task.isCancelled,
                  let list = try? JSONDecoder().decode([DebateSummary].self, from: data) else { return }
            items = list
            loaded = true
        }
    }

    /// Ricerca con breve attesa, per non interrogare il motore a ogni tasto.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// Chiede conferma per eliminare la discussione indicata (o quella selezionata).
    func requestDelete(_ id: Int? = nil) {
        guard let id = id ?? selected, let d = items.first(where: { $0.id == id }) else { return }
        pendingDelete = d
    }

    /// Mostra il campo di ricerca e ci porta il fuoco (il campo nasce al giro successivo).
    func focusSearch() {
        searchVisible = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard let f = searchField else { return }
            f.window?.makeFirstResponder(f)
        }
    }

    /// Lente della toolbar: apre la ricerca, o la richiude se è aperta e vuota.
    func toggleSearch() {
        if searchVisible && query.isEmpty { searchVisible = false } else { focusSearch() }
    }

    /// Chiude la ricerca solo se non c'è niente di scritto (la lista resta filtrata finché c'è testo).
    func closeSearchIfEmpty() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { searchVisible = false }
    }

    func delete(_ id: Int) {
        Task {
            guard let u = url("/api/debates/\(id)") else { return }
            var req = URLRequest(url: u)
            req.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: req)
            if selected == id { selected = nil }
            onDeleted?(id)
            reload()
        }
    }

    // Raggruppamento per data, come in Note e Mail.
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    static func date(_ s: String) -> Date? { parser.date(from: s) }

    var groups: [(title: String, items: [DebateSummary])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var order: [String] = []
        var map: [String: [DebateSummary]] = [:]
        for d in items {
            let date = Self.date(d.created_at) ?? .distantPast
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: today).day ?? .max
            let title: String
            if days <= 0 { title = L("Oggi") }
            else if days == 1 { title = L("Ieri") }
            else if days < 7 { title = L("Ultimi 7 giorni") }
            else if days < 30 { title = L("Ultimi 30 giorni") }
            else if date == .distantPast { title = L("Precedenti") }
            else { title = Self.monthFormatter.string(from: date) }
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(d)
        }
        return order.map { ($0, map[$0]!) }
    }
}

/// Campo di ricerca di sistema (NSSearchField): lente, pulsante di cancellazione, Esc per svuotare.
struct SidebarSearchField: NSViewRepresentable {
    @ObservedObject var model: SidebarModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = L("Cerca nelle discussioni")
        f.sendsSearchStringImmediately = true
        f.target = context.coordinator
        f.action = #selector(Coordinator.changed(_:))
        f.setAccessibilityLabel(L("Cerca nelle discussioni"))
        f.delegate = context.coordinator
        model.searchField = f
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: SidebarModel
        init(model: SidebarModel) { self.model = model }

        @objc func changed(_ sender: NSSearchField) {
            guard sender.stringValue != model.query else { return }
            model.query = sender.stringValue
            model.queryChanged()
        }

        // Esc con il campo vuoto chiude la ricerca (con del testo lo svuota, come di sistema).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.cancelOperation(_:)), model.query.isEmpty else { return false }
            model.searchVisible = false
            return true
        }

        func controlTextDidEndEditing(_ obj: Notification) { model.closeSearchIfEmpty() }
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                SidebarActionRow(title: L("Nuova discussione"), systemImage: "square.and.pencil",
                                 help: L("Inizia una nuova discussione (⌘N)")) { model.onNew?() }
                if model.searchVisible || !model.query.isEmpty {
                    SidebarSearchField(model: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.searchVisible)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            List(selection: Binding(get: { model.selected }, set: { id in
                // La lista riassegna la stessa selezione quando si aggiorna: va aperta solo
                // una discussione diversa, altrimenti quella in corso verrebbe ricaricata.
                guard id != model.selected else { return }
                model.selected = id
                if let id { model.onOpen?(id) }
            })) {
                ForEach(model.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { d in
                            DebateRow(debate: d, selected: model.selected == d.id) { model.requestDelete(d.id) }
                                .tag(d.id)
                                // Selezione nel colore del marchio al posto dell'accento di sistema.
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(model.selected == d.id ? Brand.selection : .clear)
                                        .padding(.horizontal, 10)
                                )
                                .background(SystemHighlightRemover())
                                // Solo le azioni più probabili, distruttive in fondo, niente scorciatoie.
                                .contextMenu {
                                    if d.status == "done" {
                                        Button("Esporta come Markdown…") { model.onExport?(d.id) }
                                        Divider()
                                    }
                                    Button("Elimina", role: .destructive) { model.requestDelete(d.id) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(Brand.accent)
            .overlay {
                if model.loaded && model.items.isEmpty {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Nessuna discussione", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Le discussioni avviate compaiono qui."))
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
            // Convenzione Mac: ⌫ sulla discussione selezionata la elimina (con conferma).
            .onDeleteCommand { model.requestDelete() }
        }
        // Barra fissa in fondo (come nelle app di chat): marchio a sinistra, Impostazioni a destra.
        // Nessuno sfondo opaco: resta sul vetro della barra laterale di sistema.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    CouncilLogo(size: 18)
                    Text("AI Council")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.onSettings?() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Impostazioni (⌘,)")
                    .accessibilityLabel("Impostazioni")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: model.pendingDelete) { d in
            Button("Elimina", role: .destructive) { model.delete(d.id) }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text("Non si può annullare.")
        }
    }

    private var deleteTitle: String {
        guard let q = model.pendingDelete?.displayTitle else { return L("Eliminare la discussione?") }
        let short = q.count > 60 ? String(q.prefix(60)) + "…" : q
        return String(format: L("Eliminare la discussione «%@»?"), short)
    }
}

/// Riga d'azione in cima alla barra laterale (icona + testo), evidenziata al passaggio del mouse.
struct SidebarActionRow: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(Brand.accent)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Riga della cronologia: domanda su una riga con l'ora piccola a destra; sotto, solo se serve,
/// lo stato in testo ("In corso", "Non riuscito", "Approfondimento").
/// Al passaggio del mouse l'ora lascia il posto al pulsante ✕ (scorciatoia, non l'unico modo).
struct DebateRow: View {
    let debate: DebateSummary
    var selected = false
    let onDelete: () -> Void
    @State private var hovering = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateFormat = "d MMM"
        return f
    }()

    /// Ora (oggi e ieri) o giorno, a destra del titolo.
    private var when: String {
        guard let date = SidebarModel.date(debate.created_at) else { return "" }
        let cal = Calendar.current
        return cal.isDateInToday(date) || cal.isDateInYesterday(date)
            ? Self.time.string(from: date) : Self.day.string(from: date)
    }

    /// Seconda riga facoltativa: stato non ordinario ed eventuale "Approfondimento".
    private var detail: String {
        var parts: [String] = []
        switch debate.status {
        case "running": parts.append(L("In corso"))
        case "failed": parts.append(L("Non riuscito"))
        case "cancelled": parts.append(L("Annullato"))
        case "interrupted": parts.append(L("Interrotto"))
        default: break
        }
        if debate.parent_id != nil { parts.append(L("Approfondimento")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(debate.displayTitle)
                    .fontWeight(selected ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                ZStack(alignment: .trailing) {
                    if debate.status == "running" {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel("In corso")
                            .opacity(hovering ? 0 : 1)
                    } else if !when.isEmpty {
                        Text(when)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 0 : 1)
                    }
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Elimina")
                    .accessibilityLabel("Elimina discussione")
                    // Sempre presente per l'accessibilità, visibile solo al passaggio del mouse.
                    .opacity(hovering ? 1 : 0)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(debate.question)
        .onHover { hovering = $0 }
    }
}

/// Toglie l'evidenziazione di sistema (accento blu) dalla tabella che contiene la riga:
/// la selezione resta funzionante (frecce, ⌫) ma la disegna la riga nel colore del marchio.
struct SystemHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var v: NSView? = superview
            while let cur = v, !(cur is NSTableView) { v = cur.superview }
            if let t = v as? NSTableView, t.selectionHighlightStyle != .none { t.selectionHighlightStyle = .none }
        }
    }
}
