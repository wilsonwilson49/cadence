import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The house style, shared by the Mac and iPhone apps (the web app's tokens in app.css match it):
// dark by default, serif headings over hairline rules, square boxes, one blue for links and actions.

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

enum Theme {
    /// Links, selection, focus rings: a soft blue on dark, a reference-page blue on light.
    static let accent = adaptive(dark: (0.51, 0.66, 0.94), light: (0.20, 0.40, 0.80))
    /// Filled buttons and "today" markers: the deeper navy blue.
    static let solid = adaptive(dark: (0.23, 0.38, 0.68), light: (0.16, 0.31, 0.61))
    /// Hairline rules under headings.
    static let rule = Color.primary.opacity(0.14)
    static let radius: CGFloat = 4

    /// Book-serif headings.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }

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
