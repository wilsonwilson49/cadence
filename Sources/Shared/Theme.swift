import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The house style, shared by the Mac and iPhone apps (the web app's tokens in app.css match it):
// dark by default, one typeface throughout (Verdana unless changed), headings over hairline rules, square boxes, one blue for links and actions.

/// Dark (the default), light, or whatever the system is set to. Stored per device.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : self == .light ? "Light" : "Match the system" }
    var colorScheme: ColorScheme? { self == .dark ? .dark : self == .light ? .light : nil }
    static let key = "appearance"
    static var current: AppearanceMode { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }

    #if os(macOS)
    /// Applies to every window, panel and menu at once.
    func apply() {
        NSApp.appearance = self == .dark ? NSAppearance(named: .darkAqua) : self == .light ? NSAppearance(named: .aqua) : nil
    }
    #endif
}

/// The app's typeface, chosen in Settings › Appearance (stored per device; Verdana unless changed).
/// "System" means the system font; anything else is a font family name, so any installed font works.
enum AppFont {
    static let key = "appFont"
    static let system = "System"
    static let defaultFamily = "Verdana"
    /// The short list offered first. More fonts are a menu away.
    static let presets: [(family: String, label: String)] = [
        ("Verdana", "Verdana"), (system, "System"), ("Helvetica Neue", "Helvetica"), ("Georgia", "Georgia"), ("Menlo", "Menlo"),
    ]
    static var family: String { UserDefaults.standard.string(forKey: key) ?? defaultFamily }
    /// Wide faces (Verdana, Menlo) run large, so they're set a little smaller than the system sizes.
    static var scale: CGFloat { ["Verdana", "Menlo", "Tahoma"].contains(family) ? 0.92 : 1 }
    static func label(_ f: String) -> String { presets.first { $0.family == f }?.label ?? f }
}

extension Font {
    /// The app's font at the size of a system text style, scaling with the text size setting on iPhone.
    /// Used everywhere text would otherwise use a system style.
    static func app(_ style: Font.TextStyle) -> Font {
        let family = AppFont.family
        if family == AppFont.system { return .system(style) }
        #if os(macOS)
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 26, .title: 22, .title2: 17, .title3: 15, .headline: 13, .body: 13,
                                                .callout: 12.5, .subheadline: 11.5, .footnote: 10.5, .caption: 10.5, .caption2: 10]
        #else
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 33, .title: 27, .title2: 21, .title3: 19, .headline: 17, .body: 17,
                                                .callout: 16, .subheadline: 14.5, .footnote: 13, .caption: 12, .caption2: 11]
        #endif
        let f = Font.custom(family, size: ((sizes[style] ?? 13) * AppFont.scale * 2).rounded() / 2, relativeTo: style)
        return style == .headline ? f.weight(.bold) : f
    }
}

/// Puts the chosen font on everything inside, and redraws it all when the font changes.
struct AppFontScope: ViewModifier {
    @AppStorage(AppFont.key) private var family = AppFont.defaultFamily
    func body(content: Content) -> some View { content.font(.app(.body)).id(family) }
}

enum Theme {
    /// Links, selection, focus rings: a soft blue on dark, a reference-page blue on light.
    static let accent = adaptive(dark: (0.51, 0.66, 0.94), light: (0.20, 0.40, 0.80))
    /// Filled buttons and "today" markers: the deeper navy blue.
    static let solid = adaptive(dark: (0.23, 0.38, 0.68), light: (0.16, 0.31, 0.61))
    /// Hairline rules under headings.
    static let rule = Color.primary.opacity(0.14)
    static let radius: CGFloat = 4

    /// Headings, in the app's font. Wide faces are scaled down a little.
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let family = AppFont.family
        if family == AppFont.system { return .system(size: size, weight: weight) }
        return .custom(family, size: (size * (AppFont.scale < 1 ? 0.88 : 0.96)).rounded()).weight(weight)
    }

    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { a in
            let d = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: d.0, green: d.1, blue: d.2, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { t in
            let d = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: d.0, green: d.1, blue: d.2, alpha: 1)
        })
        #endif
    }
}
