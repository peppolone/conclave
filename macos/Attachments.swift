// Allegati del composer: lettura del testo dai file (PDF con PDFKit, testo con rilevamento della
// codifica, immagini e PDF senza testo con l'OCR di Vision) e gettoni per mostrarli.
// Il motore riceve solo testo: l'estrazione avviene sempre qui, in background.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Dati

/// Limiti concordati con il motore (contratto web + allegati). Lunghezze in unità UTF-16,
/// come le conta JavaScript (`text.length`).
enum AttachmentLimits {
    static let maxFiles = 5
    static let maxChars = 40_000
    static let maxTotal = 60_000
    static let maxName = 200
    static let maxQuestion = 20_000
    /// Oltre questa soglia il contatore della domanda diventa visibile.
    static let questionWarning = 15_000
}

enum AttachmentKind: String {
    case pdf, text, image

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        }
    }

    var label: String {
        switch self {
        case .pdf: return L("PDF")
        case .text: return L("Testo")
        case .image: return L("Immagine (testo riconosciuto)")
        }
    }
}

/// Allegato nel composer: in lettura, pronto (con il testo) o non leggibile (con il motivo).
struct AttachmentItem: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var kind: AttachmentKind
    var text: String?
    var error: String?
    var truncated = false
    var loading: Bool { text == nil && error == nil }
    var chars: Int { text?.utf16.count ?? 0 }
}

/// Allegato di una discussione salvata: solo i metadati (il testo resta al motore).
struct AttachmentMeta: Equatable {
    let name: String
    let kind: AttachmentKind
    let chars: Int
}

/// Numero con i separatori delle migliaia della lingua dell'interfaccia ("15.234").
func formatCount(_ n: Int) -> String {
    n.formatted(.number.locale(AppLanguage.locale))
}

/// "12.345 caratteri".
func charsText(_ n: Int) -> String {
    n == 1 ? L("1 carattere") : String(format: L("%@ caratteri"), formatCount(n))
}

// MARK: - Lettura del testo

enum AttachmentReader {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Estensioni di testo accettate anche quando il sistema non ne conosce il tipo.
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "ini", "log",
        "html", "htm", "css", "js", "mjs", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "java",
        "kt", "c", "h", "cpp", "hpp", "m", "cs", "php", "sh", "zsh", "sql", "r", "tex", "srt", "vtt",
    ]

    /// Tipo dell'allegato dal file, o nil se non è supportato.
    static func kind(of url: URL) -> AttachmentKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        if let t = type {
            if t.conforms(to: .pdf) { return .pdf }
            if t.conforms(to: .image) { return .image }
            if t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json) { return .text }
        }
        return textExtensions.contains(url.pathExtension.lowercased()) ? .text : nil
    }

    /// Legge il testo di un file. Lento (OCR, PDF grandi): da chiamare fuori dal thread principale.
    static func read(_ url: URL, kind: AttachmentKind) throws -> String {
        switch kind {
        case .pdf: return try readPDF(url)
        case .text: return try readText(url)
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { throw Failure(message: L("Immagine non leggibile.")) }
            return try ocr([img])
        }
    }

    /// Testo riconosciuto in un'immagine incollata (dati PNG/TIFF degli appunti).
    static func readImage(_ data: Data) throws -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw Failure(message: L("Immagine non leggibile.")) }
        return try ocr([img])
    }

    private static func readText(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 20_000_000 else { throw Failure(message: L("File troppo grande (oltre 20 MB).")) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure(message: L("File non leggibile.")) }
        // Un byte nullo nelle prime righe = file binario, non testo.
        if data.prefix(8192).contains(0) { throw Failure(message: L("Il file non contiene testo.")) }
        var converted: NSString?
        var lossy: ObjCBool = false
        let enc = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.utf8.rawValue, String.Encoding.windowsCP1252.rawValue,
                                     String.Encoding.isoLatin1.rawValue, String.Encoding.utf16.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if enc != 0, let s = converted as String? { return s }
        if let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) { return s }
        throw Failure(message: L("Codifica del testo non riconosciuta."))
    }

    /// Testo del PDF; se non ne ha (scansione), OCR delle pagine (al massimo 30).
    private static func readPDF(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw Failure(message: L("PDF non leggibile.")) }
        if doc.isLocked { throw Failure(message: L("PDF protetto da password.")) }
        if let s = doc.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        var images: [CGImage] = []
        for i in 0..<min(doc.pageCount, 30) {
            guard let page = doc.page(at: i), let img = render(page) else { continue }
            images.append(img)
        }
        return try ocr(images)
    }

    /// Pagina del PDF come immagine a ~200 dpi, per l'OCR.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200.0 / 72.0
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// OCR con Vision (accurato, italiano e inglese); le immagini sono pagine in ordine.
    private static func ocr(_ images: [CGImage]) throws -> String {
        var pages: [String] = []
        for img in images {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["it-IT", "en-US"]
            req.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: L("Nessun testo riconosciuto."))
        }
        return text
    }

    /// Taglia a `max` unità UTF-16 senza spezzare un carattere.
    static func truncate(_ s: String, to max: Int) -> String {
        guard s.utf16.count > max else { return s }
        // Gli indici di String vengono arrotondati al confine del carattere precedente.
        return String(s[..<String.Index(utf16Offset: max, in: s)])
    }
}

// MARK: - Gettoni

/// Allegato nel composer: icona del tipo, nome, caratteri (o stato) e ✕ per toglierlo.
struct AttachmentChip: View {
    let item: AttachmentItem
    let remove: () -> Void

    private var detail: String {
        if item.loading { return item.kind == .text ? L("lettura…") : L("riconoscimento del testo…") }
        if let e = item.error { return e }
        return charsText(item.chars) + (item.truncated ? " · " + L("troncato") : "")
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if item.loading {
                    ProgressView().controlSize(.mini)
                } else if item.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.danger)
                } else if item.truncated {
                    Image(systemName: "scissors").foregroundStyle(Brand.warning)
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(Brand.accent)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(item.error != nil ? AnyShapeStyle(Brand.danger) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .frame(maxWidth: 220, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Togli l'allegato"))
            .accessibilityLabel(String(format: L("Togli %@"), item.name))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
            .strokeBorder(item.error != nil ? Brand.danger.opacity(0.5) : item.truncated ? Brand.warning.opacity(0.6) : Brand.hairline, lineWidth: 1))
        .help(item.truncated
              ? String(format: L("Il file era più lungo di %@ caratteri: è stato troncato."), formatCount(AttachmentLimits.maxChars))
              : item.error ?? item.kind.label)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(item.kind.label), \(detail)")
    }
}

/// Allegato nell'intestazione di una discussione: icona del tipo, nome e caratteri.
struct AttachmentTag: View {
    let meta: AttachmentMeta

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: meta.kind.symbol)
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)
            Text(meta.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(charsText(meta.chars))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        .help(meta.kind.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("Allegato: %@, %@"), meta.name, charsText(meta.chars)))
    }
}

// MARK: - Incolla di file e immagini nel composer

/// Intercetta ⌘V nella finestra principale quando gli appunti contengono file o un'immagine
/// senza testo: diventano allegati invece del nome del file incollato nel campo.
@MainActor
final class AttachmentPasteMonitor {
    private var token: Any?

    func start(_ handle: @escaping (_ urls: [URL], _ image: Data?) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  // Solo nella finestra principale (non nelle Impostazioni) e non nel campo di ricerca.
                  let win = event.window, win.toolbar?.identifier.hasPrefix("MainToolbar") == true, win.attachedSheet == nil,
                  !((win.firstResponder as? NSTextView)?.delegate is NSSearchField)
            else { return event }
            let pb = NSPasteboard.general
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty { handle(urls, nil); return nil }
            // Immagine copiata (es. schermata) senza testo: si riconosce il testo con l'OCR.
            if pb.string(forType: .string) == nil, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
                handle([], data)
                return nil
            }
            return event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Finestra di scelta dei file da allegare (scelta multipla), come foglio della finestra.
@MainActor
func chooseAttachments(_ done: @escaping ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.pdf, .image, .text, .sourceCode, .json, .commaSeparatedText, .xml, .yaml]
    panel.prompt = L("Allega")
    panel.message = L("Scegli PDF, file di testo o immagini: il consiglio ne leggerà il testo.")
    let handler: (NSApplication.ModalResponse) -> Void = { r in
        if r == .OK { done(panel.urls) }
    }
    if let win = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: win, completionHandler: handler) }
    else { panel.begin(completionHandler: handler) }
}
