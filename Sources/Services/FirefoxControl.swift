import AppKit
import ApplicationServices

/// Firefox (and the browsers built on it) can't be scripted the way Safari and Chrome can: its AppleScript only
/// knows windows, not tabs or addresses. So Cadence reads the address bar through macOS Accessibility, the same
/// way screen readers do, and blocks a site by closing its tab and opening the "blocked" page instead.
/// That needs Cadence turned on in System Settings › Privacy & Security › Accessibility.
@MainActor
enum FirefoxControl {
    /// Firefox and its relatives (they share Firefox's address bar, so the same reading works).
    static let bundleIDs: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "io.gitlab.librewolf-community", "net.waterfox.waterfox", "one.ablaze.floorp",
    ]

    static func handles(_ bundleID: String?) -> Bool { bundleID.map(bundleIDs.contains) ?? false }

    /// Whether any of them is installed (Settings only mentions Firefox if so).
    static var installed: Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static var allowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "Cadence would like to control this computer using accessibility features" prompt,
    /// which leads to the switch in System Settings.
    static func askForAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading the address bar

    /// The address bar found for each window, so the window is only searched once.
    private static var cache: [(window: AXUIElement, bar: AXUIElement)] = []

    /// The site in the front window's address bar, or nil if there isn't one, or you're typing in it.
    static func currentHost(pid: pid_t) -> String? {
        guard allowed else { return nil }
        // Accessibility calls wait on Firefox; never let a busy Firefox hold Cadence up for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute),
              let bar = addressBar(in: window) else { return nil }
        // While the address bar has the cursor, its text is whatever you're typing, not the page you're on.
        if (value(bar, kAXFocusedAttribute) as? Bool) == true { return nil }
        guard let text = value(bar, kAXValueAttribute) as? String else { return nil }
        return host(ofAddress: text)
    }

    private static func addressBar(in window: AXUIElement) -> AXUIElement? {
        cache.removeAll { value($0.window, kAXRoleAttribute) == nil }   // closed windows
        if let hit = cache.first(where: { CFEqual($0.window, window) }) { return hit.bar }
        guard let bar = search(window) else { return nil }
        cache.append((window, bar))
        return bar
    }

    /// Breadth first through the window's toolbars. The address bar is the text field Firefox calls "urlbar-input"
    /// (or, failing that, the one whose label mentions an address). Web pages are skipped: they're big and never it.
    private static func search(_ window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var i = 0
        var fallback: AXUIElement?
        while i < queue.count, i < 2500 {
            let (e, depth) = queue[i]; i += 1
            let role = value(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea", depth > 1 { continue }
            if role == kAXTextFieldRole || role == kAXComboBoxRole {
                if (value(e, "AXDOMIdentifier") as? String) == "urlbar-input" { return e }
                let label = [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute]
                    .compactMap { value(e, $0) as? String }.joined(separator: " ").lowercased()
                if fallback == nil, label.contains("address") { fallback = e }
            }
            if depth < 40, let kids = value(e, kAXChildrenAttribute) as? [AXUIElement] {
                queue += kids.map { ($0, depth + 1) }
            }
        }
        return fallback
    }

    /// "youtube.com/watch?v=…" (Firefox hides https://), "https://www.reddit.com/r/…" → the host, lowercased.
    /// Searches, about: pages and the like give nil.
    nonisolated static func host(ofAddress text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
        } else if s.contains(":") && !s.contains(".") {
            return nil   // about:blank, about:newtab
        }
        guard let first = s.split(whereSeparator: { "/?#".contains($0) }).first else { return nil }
        var h = String(first)
        if h.contains(" ") { return nil }   // a search, not an address
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        h = h.lowercased()
        return h.contains(".") ? h : nil
    }

    // MARK: Blocking

    /// Closes the front tab (⌘W) and opens the blocked page in its place. Firefox has no way to change a tab's
    /// address from outside, short of typing into it. ⌘⇧T brings the tab back once blocking is over.
    static func replaceFrontTab(pid: pid_t, appURL: URL?, with page: URL) {
        press(13, command: true, pid: pid)   // W
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            if let appURL {
                NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: config)
            } else {
                NSWorkspace.shared.open(page)
            }
        }
    }

    private static func press(_ key: CGKeyCode, command: Bool, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            if command { e.flags = .maskCommand }
            e.postToPid(pid)
        }
    }

    // MARK: Accessibility helpers

    private static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(e, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: Debug (-firefoxProbe [pid])

    /// Prints whether Cadence may use Accessibility and, for a Firefox window, whether its address bar was found.
    /// Only the host is printed, never the full address.
    static func probe(pid: pid_t?) -> String {
        var lines = ["accessibility allowed: \(allowed)"]
        let apps = NSWorkspace.shared.runningApplications.filter { handles($0.bundleIdentifier) && (pid == nil || $0.processIdentifier == pid) }
        for a in apps {
            let app = AXUIElementCreateApplication(a.processIdentifier)
            let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
            let bar = window.flatMap(addressBar(in:))
            lines.append("\(a.bundleIdentifier ?? "?") pid \(a.processIdentifier): window \(window != nil), address bar \(bar != nil), host \(currentHost(pid: a.processIdentifier) ?? "-")")
        }
        if apps.isEmpty { lines.append("no Firefox running") }
        for (text, want) in [("youtube.com/watch?v=x", "youtube.com"), ("https://www.Reddit.com/r/a", "www.reddit.com"),
                             ("about:newtab", nil), ("how to cook rice", nil), ("http://user@x.example.org:8080/p", "x.example.org"),
                             ("view-source:https://news.ycombinator.com/", "news.ycombinator.com"), ("", nil)] as [(String, String?)] {
            let got = host(ofAddress: text)
            lines.append("parse \(got == want ? "ok" : "FAIL") \(text.debugDescription) → \(got ?? "nil")")
        }
        return lines.joined(separator: "\n")
    }
}
