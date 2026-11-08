// Identità visiva di Conclave: colori del marchio, logo nativo e sfondo dell'app.
// Il logo riprende l'icona (AppIcon.icon): tre membri del consiglio uniti da linee.
// Tutte le viste usano questi token, mai colori scritti a mano.

import AppKit
import SwiftUI

enum Brand {
    // Colori dei tre membri del logo.
    static let blue = Color(red: 0x6b / 255, green: 0x8c / 255, blue: 0xff / 255)
    static let green = Color(red: 0x47 / 255, green: 0xcd / 255, blue: 0x89 / 255)
    static let amber = Color(red: 0xf5 / 255, green: 0xb5 / 255, blue: 0x44 / 255)

    /// Colore d'accento dell'app (pulsanti principali, selezioni del marchio): azzurro
    /// polvere, tenue ma leggibile su chiaro e su scuro.
    static let accent = Color(nsColor: NSColor(name: "BrandAccent") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9d / 255, green: 0xbb / 255, blue: 0xec / 255, alpha: 1)
            : NSColor(srgbRed: 0x52 / 255, green: 0x7e / 255, blue: 0xcc / 255, alpha: 1)
    })

    // Colori di stato, pastello e in tinta col logo (mai i verdi/rossi accesi di sistema).
    /// Riuscito, funziona, gratuito.
    static let success = Color(nsColor: NSColor(name: "BrandSuccess") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x8c / 255, green: 0xd4 / 255, blue: 0xae / 255, alpha: 1)
            : NSColor(srgbRed: 0x3f / 255, green: 0x9a / 255, blue: 0x70 / 255, alpha: 1)
    })
    /// Avviso, attesa, a pagamento.
    static let warning = Color(nsColor: NSColor(name: "BrandWarning") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xf0 / 255, green: 0xc9 / 255, blue: 0x80 / 255, alpha: 1)
            : NSColor(srgbRed: 0xc0 / 255, green: 0x86 / 255, blue: 0x2c / 255, alpha: 1)
    })
    /// Errore, non riuscito.
    static let danger = Color(nsColor: NSColor(name: "BrandDanger") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xf0 / 255, green: 0xa0 / 255, blue: 0x9c / 255, alpha: 1)
            : NSColor(srgbRed: 0xc4 / 255, green: 0x5c / 255, blue: 0x58 / 255, alpha: 1)
    })

    /// Tinte morbide dei tre membri del logo, per aloni e filo del verdetto.
    static let softBlue = Color(red: 0xa9 / 255, green: 0xc0 / 255, blue: 0xf2 / 255)
    static let softGreen = Color(red: 0xa6 / 255, green: 0xdd / 255, blue: 0xc0 / 255)
    static let softAmber = Color(red: 0xf4 / 255, green: 0xd3 / 255, blue: 0x9b / 255)

    /// Fondo del contenuto: carta leggermente fredda in chiaro, blu notte in scuro.
    static let canvas = Color(nsColor: NSColor(name: "BrandCanvas") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x12 / 255, green: 0x16 / 255, blue: 0x24 / 255, alpha: 1)
            : NSColor(srgbRed: 0xf7 / 255, green: 0xf8 / 255, blue: 0xfc / 255, alpha: 1)
    })

    /// Superficie dei riquadri (composer, card, verdetto) sopra il fondo.
    static let surface = Color(nsColor: NSColor(name: "BrandSurface") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1b / 255, green: 0x21 / 255, blue: 0x33 / 255, alpha: 1)
            : .white
    })

    /// Fondo della riga selezionata (barra laterale, elenchi): accento del marchio, tenue.
    static let selection = Color(nsColor: NSColor(name: "BrandSelection") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9d / 255, green: 0xbb / 255, blue: 0xec / 255, alpha: 0.22)
            : NSColor(srgbRed: 0x52 / 255, green: 0x7e / 255, blue: 0xcc / 255, alpha: 0.13)
    })

    /// Fondo tenue del verdetto: superficie appena tinta dell'accento.
    static let verdictSurface = Color(nsColor: NSColor(name: "BrandVerdictSurface") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1e / 255, green: 0x26 / 255, blue: 0x3d / 255, alpha: 1)
            : NSColor(srgbRed: 0xfb / 255, green: 0xfc / 255, blue: 1, alpha: 1)
    })

    // Raggi comuni (pt).
    enum Radius {
        static let control: CGFloat = 8, card: CGFloat = 12, panel: CGFloat = 16, composer: CGFloat = 20
    }

    /// Bordo sottile dei riquadri.
    static let hairline = Color(nsColor: NSColor(name: "BrandHairline") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(srgbRed: 0x14 / 255, green: 0x1b / 255, blue: 0x2e / 255, alpha: 0.10)
    })
}

/// Logo del consiglio disegnato in SwiftUI (nitido a ogni dimensione, segue chiaro/scuro).
struct CouncilLogo: View {
    var size: CGFloat = 40

    var body: some View {
        Canvas { ctx, s in
            let u = s.width / 1024
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            var lines = Path()
            lines.move(to: p(512, 390)); lines.addLine(to: p(350, 610))
            lines.move(to: p(512, 390)); lines.addLine(to: p(674, 610))
            lines.move(to: p(380, 660)); lines.addLine(to: p(644, 660))
            ctx.stroke(lines, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 26 * u, lineCap: .round))
            for (x, y, c) in [(512.0, 340.0, Brand.blue), (330, 660, Brand.green), (694, 660, Brand.amber)] {
                let r = 104 * u
                ctx.fill(Path(ellipseIn: CGRect(x: x * u - r, y: y * u - r, width: r * 2, height: r * 2)), with: .color(c))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sfondo dell'app: tinta del marchio con tre aloni molto tenui nei colori del logo.
/// Statico (nessuna animazione) e senza vetro: resta nel livello del contenuto.
struct BrandBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let o = scheme == .dark ? 0.16 : 0.10
        GeometryReader { g in
            let r = max(g.size.width, g.size.height)
            ZStack {
                Brand.canvas
                RadialGradient(colors: [Brand.softBlue.opacity(o), .clear], center: UnitPoint(x: 0.85, y: 0), startRadius: 0, endRadius: r * 0.6)
                RadialGradient(colors: [Brand.softGreen.opacity(o * 0.8), .clear], center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: r * 0.5)
                RadialGradient(colors: [Brand.softAmber.opacity(o * 0.7), .clear], center: UnitPoint(x: 1, y: 1), startRadius: 0, endRadius: r * 0.4)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Tema scelto nelle Impostazioni (Sistema / Chiaro / Scuro), salvato in UserDefaults.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    static let key = "AppAppearance"

    var title: String {
        switch self {
        case .system: L("Sistema")
        case .light: L("Chiaro")
        case .dark: L("Scuro")
        }
    }

    var symbol: String {
        switch self {
        case .system: "desktopcomputer"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Applica il tema a tutta l'app; da chiamare all'avvio e a ogni cambio.
    static func apply(_ a: AppAppearance = current) {
        UserDefaults.standard.set(a.rawValue, forKey: key)
        switch a {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
