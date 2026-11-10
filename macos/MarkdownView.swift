// MarkdownView.swift — rendering nativo (SwiftUI) del Markdown prodotto dai modelli.
// Parser a blocchi scritto a mano: titoli, paragrafi, elenchi (un livello di annidamento),
// tabelle, citazioni, blocchi di codice, righe orizzontali. L'inline (grassetto, corsivo,
// codice, link) passa da AttributedString(markdown:) con i link limitati a http/https.
// L'HTML non viene mai interpretato: solo <br> diventa un a capo, il resto resta testo.

import AppKit
import SwiftUI

// MARK: - Modello dei blocchi

struct MarkdownListItem: Equatable {
    var level: Int        // 0 = primo livello, 1 = annidato
    var marker: String    // "•" oppure "1." / "1)"
    var ordered: Bool
    var text: String
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case table(header: [String], rows: [[String]])
    case quote([MarkdownBlock])
    case code(language: String, text: String)
    case rule
}

// MARK: - Parser

/// Funzione pura: divide il testo Markdown in blocchi. Non va mai in crash.
func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    if text.isEmpty { return [] }
    let normalized = text.contains("\r")
        ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        : text
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    return MarkdownParser.parse(lines, depth: 0)
}

private enum MarkdownParser {
    static let maxQuoteDepth = 3
    static let maxTableColumns = 32

    static func parse(_ lines: [String], depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Blocco di codice recintato
            if let fence = fenceOpening(line) {
                flushParagraph()
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if isFenceClosing(lines[i], char: fence.char, count: fence.count) { i += 1; break }
                    body.append(stripIndent(lines[i], upTo: fence.indent))
                    i += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            // Titolo
            if let h = heading(line) {
                flushParagraph()
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // Riga orizzontale (prima degli elenchi: "* * *" non è un punto elenco)
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Tabella (riga con | seguita da riga separatrice)
            if isTableStart(lines, i) {
                flushParagraph()
                let header = splitRow(lines[i])
                let cols = min(max(header.count, 1), maxTableColumns)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") || fenceOpening(l) != nil { break }
                    rows.append(normalizeRow(splitRow(l), cols))
                    i += 1
                }
                blocks.append(.table(header: normalizeRow(header, cols), rows: rows))
                continue
            }

            // Citazione
            if quoteContent(line) != nil {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count, let c = quoteContent(lines[i]) {
                    inner.append(c)
                    i += 1
                }
                if depth >= maxQuoteDepth {
                    let joined = inner.map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    blocks.append(.quote(joined.isEmpty ? [] : [.paragraph(joined)]))
                } else {
                    blocks.append(.quote(parse(inner, depth: depth + 1)))
                }
                continue
            }

            // Elenco
            if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if let item = listItem(l) {
                        items.append(item)
                        i += 1
                        continue
                    }
                    if t.isEmpty {
                        // Riga vuota: l'elenco continua solo se segue un altro punto.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        if j < lines.count, listItem(lines[j]) != nil { i = j; continue }
                        break
                    }
                    if startsBlock(lines, i) { break }
                    // Riga di continuazione del punto precedente
                    if !items.isEmpty { items[items.count - 1].text += "\n" + t }
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }

            // Paragrafo
            paragraph.append(trimTrailing(trimLeading(line)))
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Riconoscimento righe

    static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func trimLeading(_ s: String) -> String {
        guard let idx = s.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        return String(s[idx...])
    }

    static func trimTrailing(_ s: String) -> String {
        guard let idx = s.lastIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        return String(s[...idx])
    }

    static func stripIndent(_ s: String, upTo n: Int) -> String {
        if n == 0 { return s }
        var removed = 0
        var idx = s.startIndex
        while idx < s.endIndex, removed < n, s[idx] == " " {
            removed += 1
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    struct Fence { var char: Character; var count: Int; var indent: Int; var language: String }

    static func fenceOpening(_ line: String) -> Fence? {
        let indent = leadingSpaces(line)
        if indent > 12 { return nil }
        let t = trimLeading(line)
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        let count = t.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let rest = t.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`" && rest.contains("`") { return nil }
        let lang = rest.split(separator: " ").first.map(String.init) ?? ""
        return Fence(char: first, count: count, indent: indent, language: String(lang.prefix(40)))
    }

    static func isFenceClosing(_ line: String, char: Character, count: Int) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.first == char else { return false }
        let n = t.prefix(while: { $0 == char }).count
        return n >= count && n == t.count
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let t = trimLeading(line)
        guard t.first == "#" else { return nil }
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard hashes <= 6 else { return nil }
        let rest = t.dropFirst(hashes)
        if let c = rest.first, c != " " && c != "\t" { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Toglie i # di chiusura facoltativi ("## Titolo ##")
        if text.hasSuffix("#") {
            let stripped = String(text.reversed().drop(while: { $0 == "#" }).reversed())
            if stripped.isEmpty || stripped.hasSuffix(" ") || stripped.hasSuffix("\t") {
                text = trimTrailing(stripped)
            }
        }
        return (min(hashes, 4), text)
    }

    static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else if ch != " " && ch != "\t" { return false }
        }
        return count >= 3
    }

    static func quoteContent(_ line: String) -> String? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let t = trimLeading(line)
        guard t.first == ">" else { return nil }
        var rest = t.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = leadingSpaces(line)
        if indent > 16 { return nil }
        let t = trimLeading(line)
        guard let first = t.first else { return nil }
        let level = indent >= 2 ? 1 : 0

        if first == "-" || first == "*" || first == "+" || first == "•" {
            let rest = t.dropFirst()
            guard let c = rest.first, c == " " || c == "\t" else { return nil }
            let body = rest.trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(level: level, marker: level == 0 ? "•" : "◦", ordered: false,
                                    text: trimTrailing(body))
        }
        if first.isASCII, first.isNumber {
            let digits = t.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count <= 9 else { return nil }
            let afterDigits = t.dropFirst(digits.count)
            guard let delim = afterDigits.first, delim == "." || delim == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard let c = rest.first, c == " " || c == "\t" else { return nil }
            let body = rest.trimmingCharacters(in: .whitespaces)
            return MarkdownListItem(level: level, marker: String(digits) + String(delim), ordered: true,
                                    text: trimTrailing(body))
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|"), t.contains("-") else { return false }
        for ch in t where ch != "|" && ch != "-" && ch != ":" && ch != " " && ch != "\t" { return false }
        return true
    }

    static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].contains("|") else { return false }
        return isTableSeparator(lines[i + 1])
    }

    static func startsBlock(_ lines: [String], _ i: Int) -> Bool {
        let line = lines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        return fenceOpening(line) != nil || heading(line) != nil || isRule(t)
            || quoteContent(line) != nil || isTableStart(lines, i)
    }

    /// Divide una riga di tabella sulle "|" non precedute da "\".
    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in t {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                if cells.count >= maxTableColumns * 4 { break }
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func normalizeRow(_ row: [String], _ cols: Int) -> [String] {
        if row.count == cols { return row }
        if row.count > cols { return Array(row.prefix(cols)) }
        return row + Array(repeating: "", count: cols - row.count)
    }
}

// MARK: - Inline

/// Sostituisce <br>, <br/>, <br /> (qualsiasi maiuscola) con un a capo.
func replaceHTMLLineBreaks(_ s: String) -> String {
    guard s.range(of: "<br", options: .caseInsensitive) != nil else { return s }
    var out = ""
    out.reserveCapacity(s.count)
    var idx = s.startIndex
    while idx < s.endIndex {
        guard let r = s.range(of: "<br", options: .caseInsensitive, range: idx..<s.endIndex) else {
            out += s[idx...]
            break
        }
        out += s[idx..<r.lowerBound]
        var j = r.upperBound
        while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
        if j < s.endIndex, s[j] == "/" { j = s.index(after: j) }
        while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) }
        if j < s.endIndex, s[j] == ">" {
            out += "\n"
            idx = s.index(after: j)
        } else {
            out += s[r]
            idx = r.upperBound
        }
    }
    return out
}

private final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()
    final class BlocksBox { let value: [MarkdownBlock]; init(_ v: [MarkdownBlock]) { value = v } }
    final class InlineBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    let blocks: NSCache<NSString, BlocksBox> = { let c = NSCache<NSString, BlocksBox>(); c.countLimit = 300; return c }()
    let inline: NSCache<NSString, InlineBox> = { let c = NSCache<NSString, InlineBox>(); c.countLimit = 5000; return c }()
}

/// Blocchi memorizzati per testo: il parsing non si ripete a ogni render.
func cachedMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    let key = text as NSString
    if let hit = MarkdownCache.shared.blocks.object(forKey: key) { return hit.value }
    let parsed = parseMarkdownBlocks(text)
    MarkdownCache.shared.blocks.setObject(.init(parsed), forKey: key)
    return parsed
}

/// Testo inline con grassetto, corsivo, codice e link (solo http/https). Mai in errore.
func renderInlineMarkdown(_ raw: String) -> AttributedString {
    let key = raw as NSString
    if let hit = MarkdownCache.shared.inline.object(forKey: key) { return hit.value }
    let s = replaceHTMLLineBreaks(raw)
    var result: AttributedString
    if s.count > 20_000 {
        result = AttributedString(s)   // troppo lungo: testo semplice
    } else {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: s, options: options) {
            result = parsed
            var unsafe: [Range<AttributedString.Index>] = []
            for (link, range) in result.runs[\.link] {
                guard let url = link else { continue }
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme != "http" && scheme != "https" { unsafe.append(range) }
            }
            for range in unsafe { result[range].link = nil }
            // Le immagini non vengono caricate: resta solo il testo alternativo.
            result.imageURL = nil
        } else {
            result = AttributedString(s)
        }
    }
    MarkdownCache.shared.inline.setObject(.init(result), forKey: key)
    return result
}

// MARK: - Vista

struct MarkdownView: View {
    let text: String
    var baseFont: Font = .body
    private let blocks: [MarkdownBlock]
    @AppStorage(TextZoom.key) private var zoom = 1.0

    init(_ text: String, baseFont: Font = .body) {
        self.text = text
        self.baseFont = baseFont
        self.blocks = cachedMarkdownBlocks(text)
    }

    var body: some View {
        MarkdownBlocksStack(blocks: blocks, baseFont: zoom == 1 ? baseFont : .system(size: NSFont.systemFontSize * zoom))
            .environment(\.textZoom, zoom)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocksStack: View {
    let blocks: [MarkdownBlock]
    let baseFont: Font

    var body: some View {
        // Mai pigra: dentro la pila pigra del dibattito una seconda pila pigra sbaglia le altezze.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, baseFont: baseFont)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseFont: Font
    @Environment(\.textZoom) private var zoom

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(renderInlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 4 : 0)

        case let .paragraph(text):
            Text(renderInlineMarkdown(text))
                .font(baseFont)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .list(items):
            MarkdownListView(items: items, baseFont: baseFont)

        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows, baseFont: baseFont)

        case let .quote(inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 2)
                AnyView(MarkdownBlocksStack(blocks: inner, baseFont: baseFont))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)

        case let .code(_, text):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: text)
                    .font(baseFont.monospaced())
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        // Con il testo ingrandito i titoli crescono nella stessa proporzione (17, 15 e 13 pt di base).
        if zoom != 1, level <= 3 { return .system(size: [17, 15, 13][max(level, 1) - 1] * zoom, weight: .semibold) }
        switch level {
        case 1: return .title2.weight(.semibold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return baseFont.weight(.semibold)
        }
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let baseFont: Font

    var body: some View {
        let hasOrdered = items.contains { $0.ordered }
        let longest = items.filter { $0.ordered }.map { $0.marker.count }.max() ?? 1
        let markerWidth: CGFloat = hasOrdered ? CGFloat(max(longest, 2)) * 8 + 4 : 12
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.marker)
                        .font(baseFont)
                        .monospacedDigit()
                        .foregroundStyle(item.ordered ? .primary : .secondary)
                        .frame(width: markerWidth, alignment: item.ordered ? .trailing : .center)
                    Text(renderInlineMarkdown(item.text))
                        .font(baseFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.level) * 20)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let baseFont: Font
    @Environment(\.textZoom) private var zoom

    /// Larghezza stimata di ogni colonna in base al contenuto (min 60, max 280 pt, in proporzione
    /// al testo ingrandito: altrimenti le parole andrebbero a capo a metà).
    private var columnWidths: [CGFloat] {
        (0..<header.count).map { col in
            var longest = 0
            for row in [header] + rows where col < row.count {
                for part in replaceHTMLLineBreaks(row[col]).split(separator: "\n") {
                    longest = max(longest, part.count)
                }
            }
            return min(max(CGFloat(longest) * 7 * zoom + 16, 60 * zoom), 280 * zoom)
        }
    }

    /// Larghezza disponibile, misurata dal contenitore.
    @State private var available: CGFloat = 0

    /// Colonne ridotte in proporzione per stare nella larghezza disponibile (il testo va a capo);
    /// solo se non bastano 90 pt per colonna la tabella scorre in orizzontale.
    private func fitted(_ widths: [CGFloat]) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard available > 0, total > available else { return widths }
        let minimum: CGFloat = 90
        let free = available - minimum * CGFloat(widths.count)
        guard free > 0 else { return widths.map { max($0 * available / total, minimum) } }
        let extra = widths.map { max($0 - minimum, 0) }
        let extraTotal = max(extra.reduce(0, +), 1)
        return extra.map { (minimum + $0 * free / extraTotal).rounded(.down) }
    }

    var body: some View {
        let widths = fitted(columnWidths)
        Group {
            if available > 0, widths.reduce(0, +) > available + 1 {
                ScrollView(.horizontal) {
                    table(widths).padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
            } else {
                table(widths)
            }
        }
        // minWidth 0: la cornice prende la larghezza offerta dalla card, non quella della tabella,
        // così la misura è quella disponibile e la tabella non esce dal riquadro.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    private func table(_ widths: [CGFloat]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { col, cell in
                    cellView(cell, width: widths[col], header: true)
                }
            }
            .background(.fill.quaternary)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Rectangle().fill(Color(nsColor: .gridColor)).frame(height: 0.5)
                    .gridCellUnsizedAxes(.horizontal)   // il divisore non allarga la tabella
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                        cellView(cell, width: widths[min(col, widths.count - 1)], header: false)
                    }
                }
                .background(rowBackground(i))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .gridColor), lineWidth: 0.5))
    }

    /// Righe alternate (colori di sistema) solo per tabelle lunghe, dove aiutano a seguire la riga.
    private func rowBackground(_ i: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        guard rows.count > 4, colors.count > 1 else { return .clear }
        return Color(nsColor: colors[i % 2])
    }

    private func cellView(_ text: String, width: CGFloat, header: Bool) -> some View {
        Text(renderInlineMarkdown(text))
            .font(baseFont)
            .fontWeight(header ? .semibold : nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Ogni cella riempie l'altezza della riga: sfondi di riga uniformi.
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
