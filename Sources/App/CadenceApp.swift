import SwiftUI
import AppKit

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppModel.shared.store

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.store)
                .environmentObject(AppModel.shared.google)
                .environmentObject(AppModel.shared.engine)
                .environmentObject(AppModel.shared.sync)
                .environmentObject(AppModel.shared.calendly)
                .environmentObject(AppModel.shared.importer)
                .environmentObject(AppModel.shared.focus)
                .environmentObject(AppModel.shared.screenTime)
                .environmentObject(AppModel.shared.study)
        } label: {
            MenuBarLabel(store: store, focus: AppModel.shared.focus, study: AppModel.shared.study)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when macOS opened Cadence as a login item (rather than you opening it).
    static var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.start()
        // Reminders run on a timer; keep App Nap from delaying it while Cadence has no window open.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Cadence reminders and check-ins")
    }

    private var activity: NSObjectProtocol?

    /// Clicking the Dock icon brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.windows.showMain()
        return true
    }

    /// Closing the window keeps Cadence running in the menu bar so reminders keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.screenTime.flush()
        AppModel.shared.store.saveNow()
    }
}

/// The number a running study session shows: time left in the round / period / session, or time so far.
@MainActor func studyClock(_ r: StudyRun, now: Date = Date()) -> Int {
    switch r.mode {
    case .timed: return r.timedState(now).secondsLeft
    case .dynamic: return r.taskBased || r.wrapUp ? Int(r.elapsed(now)) : r.periodSecondsLeft(now)
    case .offline: return r.offlineSecondsLeft(now) ?? Int(r.elapsed(now))
    }
}

/// Menu bar: the focus countdown while a session runs, otherwise what's left today.
private struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var focus: FocusEngine
    @ObservedObject var study: StudyEngine
    var body: some View {
        if focus.running {
            Image(systemName: "scope")
            Text(focus.clock).monospacedDigit()
        } else if let r = study.run, !r.paused {
            Image(systemName: r.mode.symbol)
            Text(clockString(studyClock(r))).monospacedDigit()
        } else {
            let remaining = store.remainingToday
            Image(systemName: remaining > 0 ? "checklist.unchecked" : "checklist.checked")
            if remaining > 0 { Text("\(remaining)") }
        }
    }
}
