import AppKit

// Cadence is only useful while it's running (reminders, nudges, check-ins, blocking), so it's hard to stop by accident:
// - Closing the window never quits it, and by default neither does ⌘Q: both just close the windows, and Cadence carries
//   on in the menu bar. "Quit completely" (menu bar icon, or ⌥⌘Q) really quits. Logging out and shutting down are never held up.
// - The Dock icon shows while a window is open (default), never (menu bar only), or always.
// - "Keep Cadence alive" puts it under launchd: it starts at login and comes back by itself if it crashes or is
//   force-quit. Only "Quit completely" stops it until the next login.
// Test copies (-dataDir) skip all of this, so they never touch the real app or the launch agent.

enum DockIconMode: String, CaseIterable, Identifiable {
    case window, never, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: return "While a window is open"
        case .never: return "Never (menu bar only)"
        case .always: return "Always"
        }
    }
}

@MainActor
enum StayRunning {
    /// Derived from the bundle ID, so a renamed test copy gets its own agent and messages.
    static var label: String { "\(Bundle.main.bundleIdentifier ?? "com.ryanpark.cadence").keepalive" }
    private static let dockKey = "dockIcon", quitKey = "quitClosesWindows", hintKey = "quitHintShown"
    /// Test copies (-dataDir) leave all of this alone, unless they're testing it (-stayRunningTest, with a renamed bundle ID).
    private static var isTest: Bool { LaunchOptions.has("-dataDir") && !LaunchOptions.has("-stayRunningTest") }

    /// Set right before a real quit (Quit completely, logout, shutdown, handing over to the launchd copy).
    static var allowQuit = false
    /// This copy took over from one that was already running, so it opens the window the user was looking at.
    static var tookOver = false

    static var dockMode: DockIconMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: dockKey), let m = DockIconMode(rawValue: raw) { return m }
            // The old "Run in the background" switch, turned off, meant "stay in the Dock".
            return UserDefaults.standard.object(forKey: "runInBackground") as? Bool == false ? .always : .window
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: dockKey); AppModel.shared.windows.updateDockIcon() }
    }

    static var quitClosesWindows: Bool {
        get { UserDefaults.standard.object(forKey: quitKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: quitKey) }
    }

    // MARK: Quitting

    /// ⌘Q, the Dock's Quit, or a quit request from another app: close the windows and keep running, unless it's a real quit.
    static func shouldTerminate() -> NSApplication.TerminateReply {
        if allowQuit || !quitClosesWindows || isTest { return .terminateNow }
        AppModel.shared.windows.closeAll()
        if !UserDefaults.standard.bool(forKey: hintKey) {
            UserDefaults.standard.set(true, forKey: hintKey)
            AppModel.shared.notifier.deliver(AlertContent(kind: .nudge, title: "Cadence is still running",
                body: "Cadence is still running in the menu bar, so reminders keep coming. To quit it completely, press ⌥⌘Q or use the menu bar icon.",
                symbol: "menubar.arrow.up.rectangle", tint: .blue), channels: [.banner])
        }
        return .terminateCancel
    }

    static func quitCompletely() {
        allowQuit = true
        NSApp.terminate(nil)
    }

    /// Logging out, restarting and shutting down always go through.
    static func watchForLogout() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { allowQuit = true }
        }
    }

    // MARK: One copy at a time

    private static var handoffNote: Notification.Name { Notification.Name("\(Bundle.main.bundleIdentifier ?? "cadence").handoff") }
    private static var showNote: Notification.Name { Notification.Name("\(Bundle.main.bundleIdentifier ?? "cadence").show") }

    /// launchd sets XPC_SERVICE_NAME to the agent's label for the processes it starts.
    static var isSupervised: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Runs before anything is loaded. launchd starts Cadence directly, so it can start a second copy next to one
    /// you opened yourself. The launchd copy (the one that gets restarted) wins: it asks the other to save and quit
    /// and waits for it. Any other second copy just brings the running one forward and leaves.
    static func ensureSingleInstance() {
        guard !isTest, let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard !others.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        guard isSupervised else {
            dnc.postNotificationName(showNote, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        dnc.postNotificationName(handoffNote, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.2) }
        if others.contains(where: { !$0.isTerminated }) { others.forEach { $0.terminate() }; Thread.sleep(forTimeInterval: 2) }
        tookOver = true
    }

    /// The running copy listens for those two messages.
    static func listenForOtherCopies() {
        guard !isTest else { return }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: handoffNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !isSupervised else { return }
                allowQuit = true
                NSApp.terminate(nil)
            }
        }
        dnc.addObserver(forName: showNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.windows.showMain() }
        }
    }

    // MARK: Keep Cadence alive (launchd)

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var keepAlive: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Turning it on registers a launch agent and hands this copy over to it (Cadence restarts once, window and all).
    /// Turning it off removes the agent; this copy keeps running until you quit it.
    static func setKeepAlive(_ on: Bool) throws {
        let domain = "gui/\(getuid())"
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe] + testArguments + ["-background"],
                "RunAtLoad": true,
                // Restart after a crash or force quit; a clean "Quit completely" (exit 0) stays quit until next login.
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            launchctl(["enable", "\(domain)/\(label)"])
            launchctl(["bootstrap", domain, plistURL.path])
            // Already loaded from earlier (bootstrap refuses): start it, unless this copy is the one launchd runs.
            if !isSupervised { launchctl(["kickstart", "\(domain)/\(label)"]) }
        } else {
            // Not "bootout": that would stop the copy you're using right now.
            launchctl(["disable", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    /// A test copy's agent keeps the test copy's data folder (never the real one).
    private static var testArguments: [String] {
        guard LaunchOptions.has("-stayRunningTest"), let dir = LaunchOptions.value("-dataDir") else { return [] }
        return ["-dataDir", dir, "-stayRunningTest", "-noNotifyPrompt", "-noCheckIn", "-noNag", "-noActivate"]
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// If Cadence was moved or rebuilt somewhere else, point the agent at the copy that's running now.
    static func refreshAgentPath() {
        guard !isTest, keepAlive, let exe = Bundle.main.executablePath,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], args.first != exe else { return }
        try? setKeepAlive(true)
    }
}
