// Barra laterale nativa (NSSplitViewController → Liquid Glass su macOS 26):
// ricerca e cronologia dei dibattiti, raggruppata per data.

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

    let port: () -> Int
    var onOpen: ((Int) -> Void)?
    var onDeleted: ((Int) -> Void)?
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

    // Raggruppamento per data, come nelle app di sistema.
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func date(_ s: String) -> Date? { parser.date(from: s) }

    var groups: [(title: String, items: [DebateSummary])] {
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [DebateSummary]] = [:]
        for d in items {
            let date = Self.date(d.created_at) ?? .distantPast
            let title: String
            if cal.isDateInToday(date) { title = "Oggi" }
            else if cal.isDateInYesterday(date) { title = "Ieri" }
            else if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 { title = "Ultimi 7 giorni" }
            else { title = "Precedenti" }
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(d)
        }
        return order.map { ($0, map[$0]!) }
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @State private var confirmDelete: DebateSummary?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca", text: $model.query, prompt: Text("Cerca nelle discussioni"))
                    .textFieldStyle(.plain)
                    .onChange(of: model.query) { _, _ in model.queryChanged() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Cancella la ricerca")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            List(selection: Binding(get: { model.selected }, set: { id in
                model.selected = id
                if let id { model.onOpen?(id) }
            })) {
                if model.items.isEmpty {
                    Text(model.query.isEmpty ? "Ancora nessuna discussione" : "Nessun risultato")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { d in
                            DebateRow(debate: d) { confirmDelete = d }
                                .tag(d.id)
                                .contextMenu {
                                    Button("Elimina…", role: .destructive) { confirmDelete = d }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Convenzione Mac: ⌫ sulla discussione selezionata la elimina (con conferma).
            .onDeleteCommand {
                if let id = model.selected, let d = model.items.first(where: { $0.id == id }) { confirmDelete = d }
            }
        }
        .confirmationDialog("Eliminare questa discussione?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { d in
            Button("Elimina", role: .destructive) { model.delete(d.id) }
        } message: { d in
            Text(d.question.prefix(120) + (d.question.count > 120 ? "…" : ""))
        }
    }

}

/// Riga della cronologia: al passaggio del mouse compare il pulsante ✕ per eliminarla.
struct DebateRow: View {
    let debate: DebateSummary
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if debate.status == "running" {
                ProgressView().controlSize(.mini)
            } else if debate.parent_id != nil {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                    .help("Approfondimento di una discussione precedente")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(debate.question).lineLimit(2)
                if debate.status == "failed" || debate.status == "cancelled" || debate.status == "interrupted" {
                    Text(debate.status == "failed" ? "Non riuscito" : debate.status == "cancelled" ? "Annullato" : "Interrotto")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Elimina questa discussione")
            .accessibilityLabel("Elimina")
            // Sempre presente per l'accessibilità, visibile solo al passaggio del mouse.
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
