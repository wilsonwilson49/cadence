import AppKit
import SwiftUI

// For things you'd rather put off. A task set to Persistent, Pushy or Strict keeps after you until it's checked off:
// - Persistent: the reminder comes back every few minutes.
// - Pushy: a window opens in the middle of the screen, again and again.
// - Strict: the window covers every screen, putting it off asks why, and while it's open the distracting apps
//   (Screen Time list) and blocked websites (Settings) are blocked.
// The blocker also runs during focus and study sessions if Settings › Tough love says so.

@MainActor
final class NagEngine: ObservableObject {
    private unowned let model: AppModel
    private var timer: Timer?
    private var ticks = 0
    /// When each item (by occurrence id) comes back next, how many times it has, and why it was put off.
    private var next: [String: Date] = [:]
    private var counts: [String: Int] = [:]
    private(set) var putOff: [String: [(at: Date, reason: String)]] = [:]
    private var day = Date().startOfDay

    /// What's on screen now (one at a time).
    @Published private(set) var showing: Occurrence?
    /// The first open strict item past its start: blocking stays on until it's done.
    @Published private(set) var strictItem: Occurrence?

    /// A preview from Settings or the task editor: not a real item, so it isn't closed for "no longer due".
    private var isPreview = false
    private var panel: NSWindow?
    private var covers: [NSWindow] = []
    let blocker: DistractionBlocker

    init(model: AppModel) {
        self.model = model
        blocker = DistractionBlocker(model: model)
    }

    func start() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func count(_ occ: Occurrence) -> Int { counts[occ.id] ?? 0 }

    private func tick() {
        ticks += 1
        let now = Date()
        if !now.isSameDay(day) { day = now.startOfDay; counts = [:]; putOff = [:] }
        // Blocking is checked every 2 seconds; reminders every 6.
        updateBlocking()
        blocker.check()
        guard ticks % 3 == 0 else { return }
        let items = model.store.nagging(now: now)
        strictItem = items.first { $0.task.nagLevel == .strict }
        if let s = showing, !isPreview, !items.contains(where: { $0.id == s.id }) { dismiss() }
        guard showing == nil, !LaunchOptions.has("-noNag") else { return }
        for occ in items {
            let due = next[occ.id] ?? model.store.nagStart(occ, now: now)
            guard now >= due else { continue }
            next[occ.id] = now.addingTimeInterval(Double(occ.task.nagMinutes * 60))
            counts[occ.id, default: 0] += 1
            fire(occ)
            break
        }
    }

    private func updateBlocking() {
        let s = model.store.settings
        if let st = strictItem ?? model.store.nagging().first(where: { $0.task.nagLevel == .strict }) {
            blocker.reason = "until you finish “\(st.task.title)”"
        } else if s.blockDuringFocus && model.focus.running {
            blocker.reason = "during your focus session"
        } else if s.blockDuringFocus, let r = model.study.run, !r.paused {
            blocker.reason = "during your study session"
        } else if let until = blocker.testUntil, until > Date() {
            blocker.reason = "for this one-minute test"
        } else {
            blocker.reason = nil
        }
    }

    private func fire(_ occ: Occurrence) {
        let n = count(occ)
        switch occ.task.nagLevel {
        case .normal: return
        case .persistent:
            model.notifier.deliver(AlertContent(kind: .task, title: "Still not done: \(occ.task.title)",
                                                body: n == 1 ? "This one keeps reminding you until it's checked off." : "Reminder \(n). It'll keep coming back every \(occ.task.nagMinutes) min until it's checked off.",
                                                symbol: NagLevel.persistent.symbol, tint: .orange, occurrence: occ),
                                   channels: [.notification, .banner, .sound])
        case .pushy: showPanel(occ)
        case .strict: showCovers(occ)
        }
    }

    // MARK: Actions from the windows

    /// "Not now": back in `minutes`. Strict items need a reason, which is kept for the day.
    func snooze(_ occ: Occurrence, minutes: Int, reason: String? = nil) {
        next[occ.id] = Date().addingTimeInterval(Double(minutes * 60))
        if let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { putOff[occ.id, default: []].append((Date(), r)) }
        dismiss()
    }

    /// Check it off: the reflection opens in the main window. If it's still open in 5 minutes, it comes back.
    func checkOff(_ occ: Occurrence) {
        next[occ.id] = Date().addingTimeInterval(5 * 60)
        dismiss()
        model.beginReflection(occ)
    }

    func openCadence(_ occ: Occurrence) {
        next[occ.id] = Date().addingTimeInterval(Double(occ.task.nagMinutes * 60))
        dismiss()
        model.openChecklist()
    }

    /// For trying it out from Settings.
    func preview(_ level: NagLevel) {
        let t = PlanTask(title: "Example: finish the essay", startDate: Date().startOfDay, channels: [], nag: level.rawValue)
        let occ = Occurrence(task: t, day: Date().startOfDay)
        counts[occ.id] = 3
        level == .strict ? showCovers(occ, preview: true) : showPanel(occ, preview: true)
        isPreview = true
    }

    // MARK: Windows

    private func dismiss() {
        panel?.orderOut(nil); panel = nil
        covers.forEach { $0.orderOut(nil) }; covers = []
        showing = nil
        isPreview = false
    }

    private func view(_ occ: Occurrence, strict: Bool, preview: Bool) -> some View {
        NagView(occ: occ, strict: strict, count: count(occ), putOff: putOff[occ.id] ?? [], preview: preview,
                onCheckOff: { [weak self] in preview ? self?.dismiss() : self?.checkOff(occ) },
                onSnooze: { [weak self] m, r in preview ? self?.dismiss() : self?.snooze(occ, minutes: m, reason: r) },
                onOpen: { [weak self] in preview ? self?.dismiss() : self?.openCadence(occ) })
            .environmentObject(model.store)
            .tint(Theme.accent)
            .font(.verdana(.body))
    }

    private func showPanel(_ occ: Occurrence, preview: Bool = false) {
        dismiss()
        showing = occ
        let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: view(occ, strict: false, preview: preview))
        w.center()
        panel = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSSound(named: "Funk")?.play()
    }

    private func showCovers(_ occ: Occurrence, preview: Bool = false) {
        dismiss()
        showing = occ
        let main = NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // Above everything, including full-screen apps and the menu bar.
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.97)
            w.isOpaque = false
            if screen == main {
                w.contentViewController = NSHostingController(rootView: view(occ, strict: true, preview: preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark))
            } else {
                w.contentViewController = NSHostingController(rootView: Text("Still not done: \(occ.task.title)")
                    .font(Theme.heading(28)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark))
            }
            w.setFrame(screen.frame, display: true)
            covers.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        covers.forEach { $0.orderFrontRegardless() }
        covers.first { $0.screen == main }?.makeKey()
        NSSound(named: "Sosumi")?.play()
    }
}

/// Borderless windows can't take typing unless they say so (the reason field needs it).
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The pop-up (Pushy) and the full-screen cover (Strict).
struct NagView: View {
    let occ: Occurrence
    let strict: Bool
    let count: Int
    let putOff: [(at: Date, reason: String)]
    var preview = false
    let onCheckOff: () -> Void
    let onSnooze: (Int, String?) -> Void
    let onOpen: () -> Void
    @State private var reason = ""
    @State private var minutes = 15

    private var t: PlanTask { occ.task }
    private var reasonWords: Int { countWords(reason) }
    private let wordsNeeded = 4

    private var since: String {
        if occ.day < Date().startOfDay { return "Overdue since \(occ.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))" }
        if let s = occ.start { return "Was due at \(timeString(s))" }
        if let d = t.dueDate { return "Due \(d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))" }
        return "On today's list"
    }

    var body: some View {
        VStack(spacing: strict ? 18 : 12) {
            if preview { Text("Preview — this is what it looks like").font(.verdana(.caption)).foregroundStyle(.secondary) }
            Image(systemName: strict ? "lock.fill" : "exclamationmark.bubble.fill")
                .font(.system(size: strict ? 40 : 28)).foregroundStyle(strict ? Color.red : .orange)
            Text("STILL NOT DONE").font(.verdana(.caption).weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(t.title).font(Theme.heading(strict ? 40 : 26)).multilineTextAlignment(.center).lineLimit(3)
            Text("\(since) · reminder \(max(1, count))\(count > 1 ? ", every \(t.nagMinutes) min" : "")")
                .font(.verdana(.callout)).foregroundStyle(.secondary)
            if !putOff.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Put off \(putOff.count) time\(putOff.count == 1 ? "" : "s") today:").font(.verdana(.caption).weight(.semibold))
                    ForEach(Array(putOff.suffix(3).enumerated()), id: \.offset) { _, p in
                        Text("\(timeString(p.at)) — “\(p.reason)”").font(.verdana(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(8).frame(maxWidth: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.primary.opacity(0.06)))
            }
            if strict {
                Text("Your distracting apps and blocked websites stay blocked until this is done.")
                    .font(.verdana(.callout)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { onCheckOff() } label: { Label("Check it off…", systemImage: "checkmark.circle") .padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button("Open Cadence") { onOpen() }.controlSize(.large)
                if !strict {
                    Menu("Not now") {
                        ForEach([5, 10, 30, 60], id: \.self) { m in Button(m == 60 ? "In 1 hour" : "In \(m) minutes") { onSnooze(m, nil) } }
                    }
                    .controlSize(.large).fixedSize()
                }
            }
            if strict {
                VStack(spacing: 8) {
                    Text("Not now? Say why, in a few words.").font(.verdana(.callout).weight(.semibold))
                    HStack {
                        TextField("e.g. at dinner with family, back at 8", text: $reason)
                            .textFieldStyle(.roundedBorder).frame(width: 340)
                        Picker("", selection: $minutes) {
                            ForEach([10, 15, 30, 60], id: \.self) { m in Text(m == 60 ? "1 hour" : "\(m) min").tag(m) }
                        }
                        .labelsHidden().fixedSize()
                        Button("Put it off") { onSnooze(minutes, reason) }.disabled(reasonWords < wordsNeeded)
                    }
                    if reasonWords < wordsNeeded {
                        Text("\(wordsNeeded - reasonWords) more word\(wordsNeeded - reasonWords == 1 ? "" : "s")").font(.verdana(.caption)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(strict ? 40 : 24)
        .frame(minWidth: strict ? nil : 460)
    }
}

/// Hides distracting apps and sends blocked websites to a "blocked" page while there's a reason to.
@MainActor
final class DistractionBlocker {
    private unowned let model: AppModel
    /// Why blocking is on ("until you finish “Essay”"), or nil when it's off.
    var reason: String? { didSet { if reason == nil { hideHUD() } } }
    /// Settings › Tough love › Try it: one minute of blocking.
    var testUntil: Date?
    private var hud: NSPanel?
    private var hudTimer: Timer?
    private var observer: NSObjectProtocol?
    /// Browsers that said no to being controlled (System Settings › Privacy & Security › Automation).
    private var denied: Set<String> = []
    private var warnedDenied: Set<String> = []

    /// Browsers whose current tab can be read and redirected with AppleScript (Firefox can't).
    private static let browsers: [String: Bool] = [   // bundle id → uses Safari's "current tab" wording
        "com.apple.Safari": true, "com.apple.SafariTechnologyPreview": true,
        "com.google.Chrome": false, "com.google.Chrome.canary": false, "com.brave.Browser": false,
        "com.microsoft.edgemac": false, "company.thebrowser.Browser": false, "com.vivaldi.Vivaldi": false,
        "com.operasoftware.Opera": false, "org.chromium.Chromium": false,
    ]

    init(model: AppModel) {
        self.model = model
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    var isOn: Bool { reason != nil }

    func check() {
        guard let reason, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let name = app.localizedName ?? ""
        if model.screenTime.isDistracting(name) {
            app.hide()
            showHUD("\(name) is blocked \(reason).")
            return
        }
        guard let id = app.bundleIdentifier, let safari = Self.browsers[id], !denied.contains(id) else { return }
        let sites = model.store.settings.blockedSites.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !sites.isEmpty else { return }
        let tab = safari ? "current tab of front window" : "active tab of front window"
        guard let url = run("tell application id \"\(id)\" to if (count of windows) > 0 then get URL of \(tab)", browser: id),
              let host = URL(string: url)?.host?.lowercased() else { return }
        guard let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) || host == "www." + $0 }) else { return }
        let page = blockedPage(site: site, reason: reason)
        _ = run("tell application id \"\(id)\" to set URL of \(tab) to \"\(page)\"", browser: id)
        showHUD("\(site) is blocked \(reason).")
    }

    private func blockedPage(site: String, reason: String) -> String {
        var base = model.sync.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://cadenceplanner.vercel.app" }
        if !base.hasPrefix("http") { base = "https://" + base }
        var c = URLComponents(string: base.hasSuffix("/") ? String(base.dropLast()) + "/blocked" : base + "/blocked")
        c?.queryItems = [URLQueryItem(name: "site", value: site), URLQueryItem(name: "why", value: reason)]
        return (c?.url?.absoluteString ?? "about:blank").replacingOccurrences(of: "\"", with: "%22")
    }

    private func run(_ source: String, browser: String) -> String? {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) == -1743 {
            denied.insert(browser)
            if warnedDenied.insert(browser).inserted {
                model.notifier.deliver(AlertContent(kind: .nudge, title: "Cadence can't block sites in this browser",
                                                    body: "Allow it in System Settings › Privacy & Security › Automation › Cadence.",
                                                    symbol: "lock.slash", tint: .orange), channels: [.notification, .banner])
            }
            return nil
        }
        return out?.stringValue
    }

    // A small notice in the middle of the screen, gone after a few seconds.
    private func showHUD(_ text: String) {
        hideHUD()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 110), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: VStack(spacing: 6) {
            Label("Blocked", systemImage: "lock.fill").font(.verdana(.headline)).foregroundStyle(.red)
            Text(text).font(.verdana(.callout)).multilineTextAlignment(.center)
            Button("Open Cadence") { [weak self] in self?.hideHUD(); self?.model.openChecklist() }.controlSize(.small)
        }
        .padding(16).frame(width: 420)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color.red.opacity(0.5)))
        .preferredColorScheme(.dark))
        p.center()
        p.orderFrontRegardless()
        hud = p
        hudTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hideHUD() } }
    }

    private func hideHUD() { hudTimer?.invalidate(); hud?.orderOut(nil); hud = nil }
}
