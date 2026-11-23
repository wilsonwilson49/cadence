import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The house style, shared by the Mac and iPhone apps (the web app's tokens in app.css match it):
// dark by default, Verdana throughout, headings over hairline rules, square boxes, one blue for links and actions.

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

extension Font {
    /// Verdana at the size of a system text style (a little smaller than SF, since Verdana runs large),
    /// scaling with the text size setting on iPhone. Used everywhere text used a system style.
    static func verdana(_ style: Font.TextStyle) -> Font {
        #if os(macOS)
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 24, .title: 20, .title2: 16, .title3: 14, .headline: 12, .body: 12,
                                                .callout: 11.5, .subheadline: 10.5, .footnote: 10, .caption: 10, .caption2: 9.5]
        #else
        let sizes: [Font.TextStyle: CGFloat] = [.largeTitle: 30, .title: 25, .title2: 20, .title3: 18, .headline: 15.5, .body: 15.5,
                                                .callout: 14.5, .subheadline: 13.5, .footnote: 12.5, .caption: 11.5, .caption2: 10.5]
        #endif
        let f = Font.custom("Verdana", size: sizes[style] ?? 12, relativeTo: style)
        return style == .headline ? f.weight(.bold) : f
    }
}

enum Theme {
    /// Links, selection, focus rings: a soft blue on dark, a reference-page blue on light.
    static let accent = adaptive(dark: (0.51, 0.66, 0.94), light: (0.20, 0.40, 0.80))
    /// Filled buttons and "today" markers: the deeper navy blue.
    static let solid = adaptive(dark: (0.23, 0.38, 0.68), light: (0.16, 0.31, 0.61))
    /// Hairline rules under headings.
    static let rule = Color.primary.opacity(0.14)
    static let radius: CGFloat = 4

    /// Headings, in Verdana like everything else. Verdana runs large, so sizes are scaled down a little.
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Verdana", size: (size * 0.88).rounded()).weight(weight) }

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
