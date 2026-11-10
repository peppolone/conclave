// Avviso di aggiornamento: l'app chiede a GitHub qual è l'ultima versione pubblicata e, se è più
// recente, propone di aprire la pagina del download. Niente installazione automatica: l'app è
// firmata ad-hoc e sostituirla da sola farebbe scattare Gatekeeper.
// È l'unica richiesta di rete che l'app fa di sua iniziativa: si disattiva in Impostazioni ▸ Generale.

import AppKit

enum UpdateCheck {
    static let enabledKey = "UpdateCheckEnabled"
    private static let nextKey = "UpdateCheckNext"
    private static let skippedKey = "UpdateSkippedVersion"
    /// Controllo automatico al massimo una volta a settimana.
    private static let interval: TimeInterval = 7 * 24 * 3600
    private static let api = URL(string: "https://api.github.com/repos/peppolone/conclave/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/peppolone/conclave/releases")!

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// Confronto numerico per componenti ("0.10.0" > "0.9.1"); i suffissi come "-beta" si ignorano.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in
            s.split(separator: "-")[0].split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Legge la risposta di GitHub. La pagina da aprire si accetta solo se è su github.com in https:
    /// un indirizzo arrivato dalla rete non deve poter aprire altro.
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.first?.isNumber == true else { return nil }
        var page = releasesPage
        if let s = j["html_url"] as? String, let u = URL(string: s), u.scheme == "https", u.host == "github.com" { page = u }
        return Release(version: version, notes: j["body"] as? String ?? "", page: page)
    }

    /// Ultima versione pubblicata; nil se non ce n'è ancora nessuna.
    static func latest() async throws -> Release? {
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Conclave", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    /// Controllo automatico (all'avvio, se è passata una settimana) o richiesto dal menu.
    /// Quello automatico non disturba mai: parla solo se c'è una versione nuova non saltata.
    /// L'avviso automatico è un foglio sulla finestra principale, mai una finestra modale a sé:
    /// non deve comparire sopra le Impostazioni del primo avvio o mentre si scrive altrove.
    @MainActor
    static func run(manual: Bool, over window: NSWindow?) async {
        let d = UserDefaults.standard
        if !manual {
            // Mai durante le prove (COUNCIL_DATA) né con una build senza versione.
            guard enabled, currentVersion != nil, (ProcessInfo.processInfo.environment["COUNCIL_DATA"] ?? "").isEmpty,
                  Date().timeIntervalSince1970 >= d.double(forKey: nextKey) else { return }
        }
        let current = currentVersion ?? "0"
        let release: Release?
        do { release = try await latest() } catch {
            // Senza rete non si rimanda di una settimana: si riprova al prossimo avvio.
            if manual { inform(L("Impossibile controllare gli aggiornamenti"), error.localizedDescription) }
            return
        }
        if !manual {
            // Finestra principale non visibile o già con un foglio aperto: si riprova al prossimo avvio.
            guard let window, window.isVisible, window.attachedSheet == nil else { return }
            d.set(Date().addingTimeInterval(interval).timeIntervalSince1970, forKey: nextKey)
        }
        guard let release, isNewer(release.version, than: current) else {
            if manual { inform(L("Conclave è aggiornato"), String(format: L("La versione %@ è la più recente."), current)) }
            return
        }
        if !manual, d.string(forKey: skippedKey) == release.version { return }

        let alert = NSAlert()
        alert.messageText = String(format: L("È disponibile Conclave %@"), release.version)
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = String(format: L("Hai la versione %@."), current)
            + (notes.isEmpty ? "" : "\n\n" + (notes.count > 600 ? String(notes.prefix(600)) + "…" : notes))
        alert.addButton(withTitle: L("Scarica"))
        alert.addButton(withTitle: L("Più tardi"))
        alert.addButton(withTitle: L("Salta questa versione"))
        let handle = { (r: NSApplication.ModalResponse) in
            switch r {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(release.page)
            case .alertThirdButtonReturn: d.set(release.version, forKey: skippedKey)
            default: break
            }
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    @MainActor
    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
