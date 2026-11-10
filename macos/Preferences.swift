// Preferenze della pagina Generale: lingua dell'interfaccia, apertura all'accesso
// e icona nella barra dei menu. Valori in UserDefaults; le viste li leggono con @AppStorage.

import AppKit
import ServiceManagement
import SwiftUI

/// Testo dell'interfaccia nella lingua scelta (Localizable.strings), per i contesti fuori da Text("…").
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Lingua dell'interfaccia. "Sistema" segue l'ordine delle lingue di macOS; il cambio vale al riavvio.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, it, en
    var id: String { rawValue }
    static let key = "AppLanguage"

    var title: String {
        switch self {
        case .system: L("Come il sistema")
        case .it: "Italiano"
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Lingua effettiva in uso adesso (quella caricata all'avvio).
    static var active: String { Bundle.main.preferredLocalizations.first ?? "it" }

    /// Locale per date e numeri, coerente con la lingua dell'interfaccia.
    static var locale: Locale { Locale(identifier: active == "en" ? "en_US" : "it_IT") }

    /// Salva la scelta: AppleLanguages dell'app decide la lingua al prossimo avvio.
    static func save(_ l: AppLanguage) {
        let d = UserDefaults.standard
        d.set(l.rawValue, forKey: key)
        if l == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([l.rawValue], forKey: "AppleLanguages") }
    }

    /// Scelta valida in questa esecuzione (letta una volta all'avvio).
    static let launched = current

    /// Riavvia l'app (apre una nuova istanza e chiude questa).
    static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

extension View {
    /// Ricrea la vista quando cambia il tema: i menu a comparsa (NSPopUpButton) altrimenti
    /// restano disegnati con i colori del tema precedente e il testo diventa invisibile.
    func rebuildOnAppearanceChange() -> some View { modifier(AppearanceRebuild()) }
}

private struct AppearanceRebuild: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    func body(content: Content) -> some View { content.id(appearance) }
}

/// Apertura automatica all'accesso (Elementi di login di macOS).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    /// macOS chiede l'approvazione in Impostazioni di Sistema ▸ Elementi di login.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Dimensione del testo di risposte e verdetto (Vista ▸ Ingrandisci / Riduci / Dimensioni reali).
enum TextZoom {
    static let key = "TextZoom"
    private static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75]

    static var value: Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v == 0 ? 1 : v
    }

    private static var index: Int {
        steps.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 1
    }

    static var canGrow: Bool { index < steps.count - 1 }
    static var canShrink: Bool { index > 0 }
    static var isDefault: Bool { value == 1 }

    static func step(_ by: Int) {
        UserDefaults.standard.set(steps[min(max(index + by, 0), steps.count - 1)], forKey: key)
    }

    static func reset() { UserDefaults.standard.set(1.0, forKey: key) }
}

private struct TextZoomKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    /// Ingrandimento del testo scelto dall'utente, letto dal renderer Markdown.
    var textZoom: Double {
        get { self[TextZoomKey.self] }
        set { self[TextZoomKey.self] = newValue }
    }
}

/// Icona nella barra dei menu: la mostra o la toglie l'AppDelegate quando cambia.
enum MenuBarPreference {
    static let key = "ShowInMenuBar"
    static let changed = Notification.Name("MenuBarPreferenceChanged")
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
