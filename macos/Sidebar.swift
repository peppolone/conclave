// Barra laterale nativa (NSSplitViewController → Liquid Glass su macOS 26):
// ricerca nativa e cronologia delle discussioni, raggruppata per data.

import AppKit
import SwiftUI

struct DebateSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let question: String
    let status: String
    let created_at: String
    let parent_id: Int?
}

@MainActor
final class SidebarModel: ObservableObject {
    @Published var items: [DebateSummary] = []
    @Published var query = ""
    @Published var selected: Int?
    /// Discussione per cui è aperta la conferma di eliminazione.
    @Published var pendingDelete: DebateSummary?
    /// true dopo il primo caricamento riuscito: prima non si mostra lo stato vuoto.
    @Published var loaded = false

    let port: () -> Int
    var onOpen: ((Int) -> Void)?
    var onDeleted: ((Int) -> Void)?
    var onExport: ((Int) -> Void)?
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

    func focusSearch() {
        guard let f = searchField else { return }
        f.window?.makeFirstResponder(f)
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
        f.locale = Locale(identifier: "it_IT")
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
            if days <= 0 { title = "Oggi" }
            else if days == 1 { title = "Ieri" }
            else if days < 7 { title = "Ultimi 7 giorni" }
            else if days < 30 { title = "Ultimi 30 giorni" }
            else if date == .distantPast { title = "Precedenti" }
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
        f.placeholderString = "Cerca nelle discussioni"
        f.sendsSearchStringImmediately = true
        f.target = context.coordinator
        f.action = #selector(Coordinator.changed(_:))
        f.setAccessibilityLabel("Cerca nelle discussioni")
        model.searchField = f
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: SidebarModel
        init(model: SidebarModel) { self.model = model }

        @objc func changed(_ sender: NSSearchField) {
            guard sender.stringValue != model.query else { return }
            model.query = sender.stringValue
            model.queryChanged()
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarSearchField(model: model)
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
                            DebateRow(debate: d) { model.requestDelete(d.id) }
                                .tag(d.id)
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
        guard let q = model.pendingDelete?.question else { return "Eliminare la discussione?" }
        let short = q.count > 60 ? String(q.prefix(60)) + "…" : q
        return "Eliminare la discussione «\(short)»?"
    }
}

/// Riga della cronologia: domanda su due righe e, sotto, ora o stato in testo.
/// Al passaggio del mouse compare anche il pulsante ✕ (scorciatoia, non l'unico modo).
struct DebateRow: View {
    let debate: DebateSummary
    let onDelete: () -> Void
    @State private var hovering = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// Seconda riga: "In corso", oppure ora (o data) più eventuale stato e "Approfondimento".
    private var detail: String {
        if debate.status == "running" { return "In corso" }
        var parts: [String] = []
        if let date = SidebarModel.date(debate.created_at) {
            let cal = Calendar.current
            parts.append(cal.isDateInToday(date) || cal.isDateInYesterday(date)
                         ? Self.time.string(from: date) : Self.dayTime.string(from: date))
        }
        switch debate.status {
        case "failed": parts.append("Non riuscito")
        case "cancelled": parts.append("Annullato")
        case "interrupted": parts.append("Interrotto")
        default: break
        }
        if debate.parent_id != nil { parts.append("Approfondimento") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(debate.question).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if debate.status == "running" {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("In corso")
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
