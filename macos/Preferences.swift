// Preferenze della pagina Generale: lingua dell'interfaccia, carattere, apertura all'accesso
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

    /// true se la scelta salvata non è ancora in uso: serve un riavvio.
    static var needsRestart: Bool { current != launched }

    /// Riavvia l'app (apre una nuova istanza e chiude questa).
    static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Carattere dell'interfaccia: San Francisco, la variante arrotondata o New York (serif).
enum AppFont: String, CaseIterable, Identifiable {
    case system, rounded, serif
    var id: String { rawValue }
    static let key = "AppFont"

    var title: String {
        switch self {
        case .system: L("Sistema (San Francisco)")
        case .rounded: L("Arrotondato (SF Rounded)")
        case .serif: L("Serif (New York)")
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}

extension View {
    /// Applica il carattere scelto nelle Impostazioni (aggiornamento immediato).
    func appFont() -> some View { modifier(AppFontModifier()) }

    /// Ricrea la vista quando cambia il tema: i menu a comparsa (NSPopUpButton) altrimenti
    /// restano disegnati con i colori del tema precedente e il testo diventa invisibile.
    func rebuildOnAppearanceChange() -> some View { modifier(AppearanceRebuild()) }
}

private struct AppearanceRebuild: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    func body(content: Content) -> some View { content.id(appearance) }
}

private struct AppFontModifier: ViewModifier {
    @AppStorage(AppFont.key) private var font = AppFont.system.rawValue

    // Con "Sistema" non si imposta nulla: i titoli in serif scelti dalle viste restano tali.
    func body(content: Content) -> some View {
        let f = AppFont(rawValue: font) ?? .system
        content.fontDesign(f == .system ? nil : f.design)
    }
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
