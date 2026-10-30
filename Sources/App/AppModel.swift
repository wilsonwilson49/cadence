import AppKit
import ServiceManagement
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case home, today, week, month, todo, habits, reflections, focus, screentime, booking, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .todo: return "To-Do List"
        case .reflections: return "Reflections"
        case .habits: return "Habits"
        case .focus: return "Focus"
        case .screentime: return "Screen Time"
        case .booking: return "Booking"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .today: return "sun.max"
        case .week: return "calendar.day.timeline.left"
        case .month: return "calendar"
        case .todo: return "checklist"
        case .reflections: return "text.quote"
        case .habits: return "arrow.triangle.2.circlepath.circle"
        case .focus: return "scope"
        case .screentime: return "desktopcomputer"
        case .booking: return "person.crop.circle.badge.clock"
        case .settings: return "gearshape"
        }
    }
}

/// Owns the app's long-lived objects and the navigation state shared by all windows.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: Store
    let google: GoogleCalendar
    let sync: SyncService
    let calendly = CalendlyService()
    private(set) lazy var importer = CalendarImporter(model: self)
    let notifier = Notifier.shared
    let windows = WindowManager()
    private(set) lazy var engine = ReminderEngine(model: self)
    private(set) lazy var screenTime = ScreenTimeTracker(model: self)
    private(set) lazy var focus = FocusEngine(model: self)

    @Published var screen: Screen = .home
    @Published var reflectionTarget: Occurrence?
    /// True when the open reflection is for "didn't do it" rather than a check-off.
    @Published var reflectionMissed = false
    @Published var editingTask: PlanTask?

    private init() {
        store = Store(directory: LaunchOptions.dataDirectory)
        google = GoogleCalendar(store: store)
        sync = SyncService(store: store)
        // Google through the website: the Mac reuses the account's Google connection.
        google.serverCall = { [unowned sync] method, path, query, body in
            try await sync.apiCall(method, path, query: query, body: body)
        }
        sync.onSignedIn = { [unowned google] in Task { await google.checkServer() } }
        sync.onSignedOut = { [unowned google] in google.resetServerMode() }
        // Checking off (or unchecking) a Google Tasks item updates it in Google.
        store.onGoogleTaskChange = { [unowned google] t, status in
            Task { try? await google.updateGoogleTask(listID: t.sourceCalendar ?? "@default", taskID: t.googleTaskID ?? "", fields: ["status": status]) }
        }
    }

    func start() {
        windows.model = self
        notifier.setup(model: self)
        google.restore()
        engine.start()
        screenTime.start()
        LoginItem.applyDefault()
        sync.start()
        calendly.restore()
        importer.start()
        #if DEBUG
        DebugDriver.prepare(self)
        #endif
        // Opened at login with background mode on: stay in the menu bar (the check-in below still appears).
        if !LaunchOptions.has("-background") && !(WindowManager.runsInBackground && AppDelegate.launchedAtLogin) { windows.showMain() }
        else { windows.updateDockIcon() }
        if store.settings.checkInOnLaunch && !LaunchOptions.has("-noCheckIn") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.engine.triggerCheckIn(reason: .launch) }
        }
        #if DEBUG
        DebugDriver.run(self)
        #endif
    }

    // MARK: Actions used across views

    func newTask(on day: Date = Date(), minutes: Int? = nil) {
        editingTask = PlanTask(title: "", startDate: day.startOfDay, timeMinutes: minutes,
                               channels: store.settings.defaultChannels)
        windows.showMain()
    }

    /// Start a new task at a moment inside an existing task or event, so its
    /// reminders fire while the other one is still going.
    func newTask(at moment: Date) {
        let m = moment.minutesSinceMidnight / 5 * 5
        newTask(on: moment, minutes: min(m, 23 * 60 + 55))
    }

    /// A new event: next whole hour (or 9 AM on other days), one hour, 10-minute heads-up.
    func newEvent(on day: Date = Date(), minutes: Int? = nil) {
        let now = Date()
        let m = minutes ?? (day.isSameDay(now) ? min(23 * 60, (Calendar.current.component(.hour, from: now) + 1) * 60) : 9 * 60)
        var t = PlanTask(title: "", startDate: day.startOfDay, timeMinutes: m, durationMinutes: 60,
                         reminderOffsets: [10], channels: store.settings.defaultChannels, color: .teal)
        t.kind = "event"
        t.busy = true   // events you make here start closed
        editingTask = t
        windows.showMain()
    }

    /// A new habit: daily, building something new (or replacing a bad habit from the scorecard).
    func newHabit(style: String = "build", replaces: String? = nil) {
        var t = PlanTask(title: "", startDate: Date().startOfDay, recurrence: Recurrence(frequency: .daily),
                         channels: store.settings.defaultChannels, color: .green)
        t.kind = "habit"; t.busy = false
        var h = HabitInfo(); h.style = style; h.replaces = replaces
        t.habit = h
        editingTask = t
        windows.showMain()
    }

    func edit(_ task: PlanTask) {
        editingTask = store.task(task.id) ?? task
        windows.showMain()
    }

    /// Completing requires a reflection, so "checking" an item opens the reflection form.
    func toggle(_ occ: Occurrence) {
        if occ.isDone { store.uncomplete(occ) } else { beginReflection(occ) }
    }

    func beginReflection(_ occ: Occurrence, missed: Bool = false) {
        windows.showMain()
        reflectionMissed = missed
        // Re-read the task so the sheet sees the latest state.
        if let t = store.task(occ.task.id) { reflectionTarget = Occurrence(task: t, day: occ.day) }
    }

    /// The X box: "didn't do it / couldn't" asks why; clicking it again undoes it.
    func toggleMissed(_ occ: Occurrence) {
        if occ.isMissed { store.unmiss(occ) } else { beginReflection(occ, missed: true) }
    }

    func openChecklist() {
        screen = .today
        windows.showMain()
    }
}

/// The main window and check-in window are managed with AppKit so they can be
/// reopened from anywhere (menu bar, notifications, wake events).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    weak var model: AppModel?
    private(set) var mainWindow: NSWindow?
    private(set) var checkInWindow: NSWindow?
    private var checkInReason = ""

    private func inject<V: View>(_ view: V) -> some View {
        let m = model ?? AppModel.shared
        return view.environmentObject(m).environmentObject(m.store).environmentObject(m.google)
            .environmentObject(m.engine).environmentObject(m.sync)
            .environmentObject(m.calendly).environmentObject(m.importer)
            .environmentObject(m.focus).environmentObject(m.screenTime)
    }

    // MARK: Running in the background

    /// On (the default): with no Cadence window open, the Dock icon goes away and Cadence keeps running in
    /// the menu bar, so reminders and check-ins keep working. Starting at login opens quietly (no window).
    static var runsInBackground: Bool {
        get { UserDefaults.standard.object(forKey: "runInBackground") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "runInBackground"); AppModel.shared.windows.updateDockIcon() }
    }

    /// Dock icon only while a window is on screen (or always, with background mode off).
    func updateDockIcon() {
        let visible = [mainWindow, checkInWindow].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = !Self.runsInBackground || visible ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func windowWillClose(_ notification: Notification) {
        // Let the window finish closing, then drop the Dock icon if nothing else is open.
        DispatchQueue.main.async { [weak self] in self?.updateDockIcon() }
    }

    func showMain() {
        if !LaunchOptions.has("-noActivate") && Self.runsInBackground { NSApp.setActivationPolicy(.regular) }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Cadence"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 600)
            w.contentViewController = NSHostingController(rootView: inject(RootView()))
            w.setContentSize(NSSize(width: 1180, height: 760))
            w.center()
            w.setFrameAutosaveName("CadenceMain")
            w.delegate = self
            mainWindow = w
        }
        if !LaunchOptions.has("-noActivate") { NSApp.activate(ignoringOtherApps: true) }
        if LaunchOptions.has("-noActivate") { mainWindow?.orderFront(nil) } else { mainWindow?.makeKeyAndOrderFront(nil) }
    }

    func showCheckIn(reason: String) {
        checkInReason = reason
        let root = inject(CheckInView(reason: reason, onClose: { [weak self] in self?.closeCheckIn() }))
        if let w = checkInWindow {
            (w.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.delegate = self
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentViewController = NSHostingController(rootView: AnyView(root))
            w.setContentSize(NSSize(width: 560, height: 620))
            checkInWindow = w
        }
        checkInWindow?.center()
        if !LaunchOptions.has("-noActivate") { NSApp.activate(ignoringOtherApps: true) }
        checkInWindow?.makeKeyAndOrderFront(nil)
    }

    func closeCheckIn() {
        checkInWindow?.orderOut(nil)
        model?.engine.resetNudgeTimer()
        updateDockIcon()
    }
}

/// Opening at login is on by default. Once you change it in Settings, Cadence leaves your choice alone.
enum LoginItem {
    private static let choiceKey = "loginItemUserChoice"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// First launches (and copies that were never registered) turn it on, unless you've turned it off.
    /// Test runs (-dataDir) never touch your login items.
    static func applyDefault() {
        guard !LaunchOptions.has("-dataDir"), !UserDefaults.standard.bool(forKey: choiceKey) else { return }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return
        default: try? SMAppService.mainApp.register()
        }
    }

    /// From the Settings switch: remembered, so the default never overrides it.
    static func set(_ on: Bool) throws {
        UserDefaults.standard.set(true, forKey: choiceKey)
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
