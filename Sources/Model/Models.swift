import Foundation
import SwiftUI

// MARK: - Alert channels

/// The ways Cadence can get your attention. Each task picks any combination.
enum AlertChannel: String, Codable, CaseIterable, Identifiable {
    case notification, banner, sound, checkIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notification: return "Notification"
        case .banner: return "On-screen banner"
        case .sound: return "Sound"
        case .checkIn: return "Checklist window"
        }
    }

    var detail: String {
        switch self {
        case .notification: return "macOS Notification Center. Banner vs. persistent alert style is chosen in System Settings."
        case .banner: return "A Cadence banner in the top-right corner that stays until you dismiss it."
        case .sound: return "Play a chime."
        case .checkIn: return "Pop open the daily checklist window."
        }
    }

    var symbol: String {
        switch self {
        case .notification: return "bell.badge"
        case .banner: return "rectangle.topthird.inset.filled"
        case .sound: return "speaker.wave.2"
        case .checkIn: return "checklist"
        }
    }
}

// MARK: - Colors

enum TaskColor: String, Codable, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, gray
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

// MARK: - Recurrence

enum Frequency: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, yearly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Does not repeat"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
    var unit: String {
        switch self {
        case .none: return ""
        case .daily: return "day"
        case .weekly: return "week"
        case .monthly: return "month"
        case .yearly: return "year"
        }
    }
}

enum RecurrenceEnd: Codable, Hashable {
    case never
    case onDate(Date)
    case afterCount(Int)
}

struct Recurrence: Codable, Hashable {
    var frequency: Frequency = .none
    var interval: Int = 1
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Only used for weekly rules.
    var weekdays: [Int] = []
    var end: RecurrenceEnd = .never

    var isRepeating: Bool { frequency != .none }

    func effectiveWeekdays(start: Date) -> [Int] {
        weekdays.isEmpty ? [Calendar.current.component(.weekday, from: start)] : weekdays.sorted()
    }

    func summary(start: Date) -> String {
        let n = max(1, interval)
        var s: String
        switch frequency {
        case .none:
            return "Once"
        case .daily:
            s = n == 1 ? "Every day" : "Every \(n) days"
        case .weekly:
            let days = effectiveWeekdays(start: start)
            if n == 1 && days == [2, 3, 4, 5, 6] {
                s = "Every weekday"
            } else if n == 1 && days.count == 7 {
                s = "Every day"
            } else {
                let names = days.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
                s = (n == 1 ? "Weekly" : "Every \(n) weeks") + " on " + names
            }
        case .monthly:
            let day = Calendar.current.component(.day, from: start)
            s = (n == 1 ? "Monthly" : "Every \(n) months") + " on day \(day)"
        case .yearly:
            s = (n == 1 ? "Yearly" : "Every \(n) years") + " on " + start.formatted(.dateTime.month(.abbreviated).day())
        }
        switch end {
        case .never: break
        case .onDate(let d): s += ", until " + d.formatted(date: .abbreviated, time: .omitted)
        case .afterCount(let c): s += ", \(c) times"
        }
        return s
    }

    /// RFC 5545 rule, used when exporting a task to Google Calendar.
    func rrule(start: Date) -> String? {
        guard isRepeating else { return nil }
        var parts = ["FREQ=" + frequency.rawValue.uppercased()]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if frequency == .weekly {
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            parts.append("BYDAY=" + effectiveWeekdays(start: start).map { codes[$0 - 1] }.joined(separator: ","))
        }
        switch end {
        case .never: break
        case .onDate(let d):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            parts.append("UNTIL=" + f.string(from: d.startOfDay.adding(days: 1).addingTimeInterval(-1)))
        case .afterCount(let c):
            parts.append("COUNT=\(c)")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }
}

// MARK: - Tasks

struct PlanTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var notes: String = ""
    /// The (first) day the task happens.
    var startDate: Date
    /// Minutes after midnight, or nil for "any time that day".
    var timeMinutes: Int?
    var durationMinutes: Int = 30
    var recurrence = Recurrence()
    /// Minutes before the start to remind. 0 = at the start time; negative = that many minutes into the task.
    var reminderOffsets: Set<Int> = [0]
    var channels: Set<AlertChannel> = [.notification, .banner]
    var color: TaskColor = .blue
    /// Occurrence day key ("yyyy-MM-dd") → completion time.
    var completions: [String: Date] = [:]
    /// Occurrence day key → when you marked it "didn't do it" (the X box, with a reflection on why).
    var missed: [String: Date]?
    /// Occurrence day keys the user chose to skip.
    var skipped: Set<String> = []
    var googleEventID: String?
    var createdAt = Date()
    /// Last local or synced edit; drives last-writer-wins sync. nil for data created before sync existed.
    var updatedAt: Date?
    /// "google" / "calendly" for imported items; nil for tasks made in Cadence.
    var source: String?
    /// Link back to the original event (Google Calendar page, Calendly meeting link).
    var externalURL: String?
    /// Google calendar the event came from, so any device can re-check it by ID.
    var sourceCalendar: String?
    /// Imported items are hidden instead of deleted, so the next import doesn't bring them back.
    var archived: Bool?

    /// "task" or "event"; nil means: event if imported, otherwise task.
    var kind: String?
    /// "longTerm": every day until an end date (each day its own check-off).
    /// "untilDone": shows up every day until it's checked off once, then disappears. nil: a normal task.
    var mode: String?
    /// Optional due date for an until-done task (it keeps going past it, marked "Past due").
    var dueDate: Date?

    /// Closed (true) items block their time; open (false) ones are just for info.
    /// nil means the default: events closed, tasks open.
    var busy: Bool?

    /// No channels = a silent item: it never pings.
    var isSilent: Bool { channels.isEmpty }
    var isImported: Bool { source != nil }
    /// Events live on the calendars only: never on the checklist, no check-off, no reflection.
    var isEvent: Bool { kind == "event" || (kind != "task" && source != nil) }
    var isBusy: Bool { busy ?? isEvent }
    /// Checked off or marked "didn't do" at least once (imports never hide items with history).
    var hasHistory: Bool { !completions.isEmpty || !(missed ?? [:]).isEmpty }
    var isLongTerm: Bool { mode == "longTerm" }
    var isUntilDone: Bool { mode == "untilDone" }
    /// The day an until-done task was finished (its earliest check-off).
    var finishedKey: String? { finish()?.key }
    /// An until-done task past its due date that still isn't finished.
    var isPastDue: Bool {
        guard isUntilDone, !recurrence.isRepeating, let due = dueDate, finish() == nil else { return false }
        return due.startOfDay < Date().startOfDay
    }

    /// How it repeats, in words, including the long-term and until-done types. Same as planSummary() on the web.
    var planSummary: String? {
        let cal = Calendar.current
        let short: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day()) }
        if isUntilDone {
            var base = "Every day until done"
            if recurrence.isRepeating {
                let r = recurrence.summary(start: startDate)
                base = "Until done · a new one " + (r.hasPrefix("Every ") ? "every " + r.dropFirst(6) : r.prefix(1).lowercased() + r.dropFirst())
            }
            if let f = finish() { return "\(base) · \(f.missed ? "not done" : "finished")" }
            guard let due = dueDate, !recurrence.isRepeating else { return base }
            let left = cal.dateComponents([.day], from: Date().startOfDay, to: due.startOfDay).day ?? 0
            let tail = left > 1 ? " (\(left) days left)" : left == 1 ? " (tomorrow)" : left == 0 ? " (today)" : ""
            return "\(base) · due \(short(due))\(tail)"
        }
        if isLongTerm {
            guard case .onDate(let end) = recurrence.end else { return "Long-term · every day" }
            let left = cal.dateComponents([.day], from: Date().startOfDay, to: end.startOfDay).day ?? 0
            let tail = left > 0 ? " (\(left) day\(left == 1 ? "" : "s") left)" : left == 0 ? " (last day)" : ""
            return "Long-term · every day until \(short(end))\(tail)"
        }
        return recurrence.isRepeating ? recurrence.summary(start: startDate) : nil
    }
}

/// One concrete instance of a (possibly repeating) task on a given day.
struct Occurrence: Identifiable, Hashable {
    let task: PlanTask
    let day: Date

    var key: String { DateKey.string(day) }
    var id: String { "\(task.id.uuidString)|\(key)" }
    var start: Date? { task.timeMinutes.map { dayAt(day, minutes: $0) } }
    var end: Date? { start?.adding(minutes: max(5, task.durationMinutes)) }
    var isEvent: Bool { task.isEvent }
    var isBusy: Bool { task.isBusy }
    var isDone: Bool { !task.isEvent && task.completions[key] != nil }
    /// "Didn't do it / couldn't": settles the item like a check-off, without counting as done.
    var isMissed: Bool { !task.isEvent && !isDone && task.missed?[key] != nil }
    var isResolved: Bool { isDone || isMissed }
    var isOverdue: Bool { !task.isEvent && !isResolved && day < Date().startOfDay }
}

// MARK: - Reflections

struct Reflection: Codable, Identifiable, Hashable {
    var id = UUID()
    var taskID: UUID
    var taskTitle: String
    var occurrenceKey: String
    var text: String
    var createdAt = Date()
    var updatedAt: Date?
    /// nil = written when checking it off; "missed" = why it didn't happen.
    var outcome: String?

    var wordCount: Int { countWords(text) }
    var isMissed: Bool { outcome == "missed" }
}

// MARK: - Task presets

/// A saved combination of conditions to start new tasks from. Dates are relative to the start day
/// (spanDays: repeat end / long-term end, dueDays: due date). Same JSON as the web app's taskPresets.
struct TaskPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: String? = "task"
    var title = ""
    var notes = ""
    var timeMinutes: Int?
    var durationMinutes = 30
    var recurrence = Recurrence()
    var reminderOffsets: [Int] = [0]
    var channels: [AlertChannel] = [.notification, .banner]
    var color: TaskColor = .blue
    var busy: Bool?
    var mode: String?
    var spanDays: Int?
    var dueDays: Int?

    init(id: UUID = UUID(), name: String, kind: String? = "task", timeMinutes: Int? = nil, durationMinutes: Int = 30,
         recurrence: Recurrence = Recurrence(), reminderOffsets: [Int] = [0], color: TaskColor = .blue,
         busy: Bool? = nil, mode: String? = nil, dueDays: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.timeMinutes = timeMinutes; self.durationMinutes = durationMinutes
        self.recurrence = recurrence; self.reminderOffsets = reminderOffsets; self.color = color
        self.busy = busy; self.mode = mode; self.dueDays = dueDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); name = c.value(.name, "Preset"); kind = c.value(.kind, "task")
        title = c.value(.title, ""); notes = c.value(.notes, "")
        timeMinutes = c.value(.timeMinutes, nil); durationMinutes = c.value(.durationMinutes, 30)
        recurrence = c.value(.recurrence, Recurrence()); reminderOffsets = c.value(.reminderOffsets, [0])
        channels = c.value(.channels, [.notification, .banner]); color = c.value(.color, .blue)
        busy = c.value(.busy, nil); mode = c.value(.mode, nil); spanDays = c.value(.spanDays, nil); dueDays = c.value(.dueDays, nil)
    }

    private static func fixed(_ n: Int) -> UUID { UUID(uuidString: String(format: "B0B0B0B0-0000-4000-8000-%012d", n))! }
    static let defaults: [TaskPreset] = [
        TaskPreset(id: fixed(1), name: "Homework", durationMinutes: 60, color: .orange, busy: false, mode: "untilDone", dueDays: 2),
        TaskPreset(id: fixed(2), name: "Daily habit", recurrence: Recurrence(frequency: .daily), color: .green, busy: false),
        TaskPreset(id: fixed(3), name: "Weekly chore (until done)", recurrence: Recurrence(frequency: .weekly), color: .teal, busy: false, mode: "untilDone"),
        TaskPreset(id: fixed(4), name: "Meeting", kind: "event", timeMinutes: 600, reminderOffsets: [10], color: .purple, busy: true),
    ]

    /// Short description for Settings (same wording as the web).
    var summary: String {
        var parts = [kind == "event" ? "Event" : "Task"]
        if mode == "longTerm" { parts.append("every day for \((spanDays ?? 29) + 1) days") }
        else if !recurrence.isRepeating { parts.append("once") }
        else if recurrence.frequency == .weekly && recurrence.weekdays.isEmpty { parts.append(recurrence.interval > 1 ? "every \(recurrence.interval) weeks" : "weekly") }
        else { var r = recurrence; r.end = .never; let t = r.summary(start: Date()); parts.append(t.prefix(1).lowercased() + t.dropFirst()) }
        if mode == "untilDone" { parts.append("kept on the list until done") }
        if let d = dueDays { parts.append("due in \(d) day\(d == 1 ? "" : "s")") }
        if let m = timeMinutes { parts.append("at \(timeString(minutes: m))") }
        if channels.isEmpty { parts.append("no notifications") }
        if kind == "event" || busy == true { parts.append(busy == true ? "closed" : "open") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Calendar toggles

/// Each item belongs to one calendar: "tasks" / "events" (your own Cadence items), "calendly", or
/// "google:<id>" ("google:primary" for your main Google calendar). Same keys as the web app (model.js).
func googleCalendarKey(_ id: String?, primary: String?) -> String {
    guard let id, id != "primary", id != primary else { return "google:primary" }
    return "google:\(id)"
}

func calendarKey(of task: PlanTask, primary: String?) -> String {
    if task.source == "google" { return googleCalendarKey(task.sourceCalendar, primary: primary) }
    if task.source == "calendly" { return "calendly" }
    return task.isEvent ? "events" : "tasks"
}

// MARK: - Open hours (Booking)

struct Availability: Codable, Hashable {
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    var startMinutes = 9 * 60
    var endMinutes = 17 * 60
    /// Breathing room kept free around closed items.
    var bufferMinutes = 10

    init() {}

    // Tolerant, like the settings: missing keys keep their defaults, unknown ones are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Availability()
        weekdays = c.value(.weekdays, d.weekdays)
        startMinutes = c.value(.startMinutes, d.startMinutes)
        endMinutes = c.value(.endMinutes, d.endMinutes)
        bufferMinutes = c.value(.bufferMinutes, d.bufferMinutes)
    }
}

// MARK: - Settings

struct AppSettings: Codable {
    // Every-30-minutes nudge while the Mac is in use
    var nudgeEnabled = true
    var nudgeIntervalMinutes = 30
    var nudgeChannels: Set<AlertChannel> = [.notification, .banner]
    var nudgeOnlyWhenIncomplete = true

    // Check-in when the computer is opened
    var checkInOnLaunch = true
    var checkInOnWake = true
    var checkInOnUnlock = true
    var checkInOnlyWhenIncomplete = false
    var checkInChannels: Set<AlertChannel> = [.checkIn, .sound]

    // Task reminders
    var defaultChannels: Set<AlertChannel> = [.notification, .banner]
    var untimedReminderMinutes = 9 * 60
    var bannerAutoDismissSeconds = 0

    // Reflections
    var minReflectionWords = 20

    // Google Calendar
    var googleClientID = ""
    var googleClientSecret = ""
    var googleCalendarIDs: [String] = []
    var showGoogleEvents = true
    var googleEventReminderMinutes = 0   // imported/calendar events don't ping by default

    // Calendar imports (Google Calendar events + Calendly meetings become silent checklist items)
    var autoImportCalendars = true
    var importDaysAhead = 14

    // Booking (open hours)
    var availability = Availability()

    /// Calendars switched off with the Calendars toggles (keys from calendarKey(of:primary:)).
    var hiddenCalendars: [String] = []

    var taskPresets: [TaskPreset] = TaskPreset.defaults

    init() {}

    // Tolerant decoding so adding a setting never wipes an existing data file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        nudgeEnabled = c.value(.nudgeEnabled, d.nudgeEnabled)
        nudgeIntervalMinutes = c.value(.nudgeIntervalMinutes, d.nudgeIntervalMinutes)
        nudgeChannels = c.value(.nudgeChannels, d.nudgeChannels)
        nudgeOnlyWhenIncomplete = c.value(.nudgeOnlyWhenIncomplete, d.nudgeOnlyWhenIncomplete)
        checkInOnLaunch = c.value(.checkInOnLaunch, d.checkInOnLaunch)
        checkInOnWake = c.value(.checkInOnWake, d.checkInOnWake)
        checkInOnUnlock = c.value(.checkInOnUnlock, d.checkInOnUnlock)
        checkInOnlyWhenIncomplete = c.value(.checkInOnlyWhenIncomplete, d.checkInOnlyWhenIncomplete)
        checkInChannels = c.value(.checkInChannels, d.checkInChannels)
        defaultChannels = c.value(.defaultChannels, d.defaultChannels)
        untimedReminderMinutes = c.value(.untimedReminderMinutes, d.untimedReminderMinutes)
        bannerAutoDismissSeconds = c.value(.bannerAutoDismissSeconds, d.bannerAutoDismissSeconds)
        minReflectionWords = max(20, c.value(.minReflectionWords, d.minReflectionWords))
        googleClientID = c.value(.googleClientID, d.googleClientID)
        googleClientSecret = c.value(.googleClientSecret, d.googleClientSecret)
        googleCalendarIDs = c.value(.googleCalendarIDs, d.googleCalendarIDs)
        showGoogleEvents = c.value(.showGoogleEvents, d.showGoogleEvents)
        googleEventReminderMinutes = c.value(.googleEventReminderMinutes, d.googleEventReminderMinutes)
        availability = c.value(.availability, d.availability)
        autoImportCalendars = c.value(.autoImportCalendars, d.autoImportCalendars)
        importDaysAhead = c.value(.importDaysAhead, d.importDaysAhead)
        hiddenCalendars = c.value(.hiddenCalendars, d.hiddenCalendars)
        taskPresets = c.value(.taskPresets, d.taskPresets)
    }
}

/// The settings that sync between devices (Google client credentials, calendar picks and
/// the like stay on each device). Same JSON keys as AppSettings, so the web app shares them.
struct SyncedSettings: Codable, Equatable {
    var nudgeEnabled: Bool
    var nudgeIntervalMinutes: Int
    var nudgeChannels: Set<AlertChannel>
    var nudgeOnlyWhenIncomplete: Bool
    var checkInOnLaunch: Bool
    var checkInOnWake: Bool
    var checkInOnUnlock: Bool
    var checkInOnlyWhenIncomplete: Bool
    var checkInChannels: Set<AlertChannel>
    var defaultChannels: Set<AlertChannel>
    var untimedReminderMinutes: Int
    var bannerAutoDismissSeconds: Int
    var minReflectionWords: Int
    var showGoogleEvents: Bool
    var googleEventReminderMinutes: Int
    var availability: Availability
    var autoImportCalendars: Bool
    var importDaysAhead: Int
    var hiddenCalendars: [String]
    var taskPresets: [TaskPreset]

    init(_ s: AppSettings) {
        nudgeEnabled = s.nudgeEnabled; nudgeIntervalMinutes = s.nudgeIntervalMinutes
        nudgeChannels = s.nudgeChannels; nudgeOnlyWhenIncomplete = s.nudgeOnlyWhenIncomplete
        checkInOnLaunch = s.checkInOnLaunch; checkInOnWake = s.checkInOnWake; checkInOnUnlock = s.checkInOnUnlock
        checkInOnlyWhenIncomplete = s.checkInOnlyWhenIncomplete; checkInChannels = s.checkInChannels
        defaultChannels = s.defaultChannels; untimedReminderMinutes = s.untimedReminderMinutes
        bannerAutoDismissSeconds = s.bannerAutoDismissSeconds; minReflectionWords = s.minReflectionWords
        showGoogleEvents = s.showGoogleEvents; googleEventReminderMinutes = s.googleEventReminderMinutes
        availability = s.availability
        autoImportCalendars = s.autoImportCalendars; importDaysAhead = s.importDaysAhead
        hiddenCalendars = s.hiddenCalendars
        taskPresets = s.taskPresets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(AppSettings())
        nudgeEnabled = c.value(.nudgeEnabled, nudgeEnabled)
        nudgeIntervalMinutes = c.value(.nudgeIntervalMinutes, nudgeIntervalMinutes)
        nudgeChannels = c.value(.nudgeChannels, nudgeChannels)
        nudgeOnlyWhenIncomplete = c.value(.nudgeOnlyWhenIncomplete, nudgeOnlyWhenIncomplete)
        checkInOnLaunch = c.value(.checkInOnLaunch, checkInOnLaunch)
        checkInOnWake = c.value(.checkInOnWake, checkInOnWake)
        checkInOnUnlock = c.value(.checkInOnUnlock, checkInOnUnlock)
        checkInOnlyWhenIncomplete = c.value(.checkInOnlyWhenIncomplete, checkInOnlyWhenIncomplete)
        checkInChannels = c.value(.checkInChannels, checkInChannels)
        defaultChannels = c.value(.defaultChannels, defaultChannels)
        untimedReminderMinutes = c.value(.untimedReminderMinutes, untimedReminderMinutes)
        bannerAutoDismissSeconds = c.value(.bannerAutoDismissSeconds, bannerAutoDismissSeconds)
        minReflectionWords = max(20, c.value(.minReflectionWords, minReflectionWords))
        showGoogleEvents = c.value(.showGoogleEvents, showGoogleEvents)
        googleEventReminderMinutes = c.value(.googleEventReminderMinutes, googleEventReminderMinutes)
        availability = c.value(.availability, availability)
        autoImportCalendars = c.value(.autoImportCalendars, autoImportCalendars)
        importDaysAhead = c.value(.importDaysAhead, importDaysAhead)
        hiddenCalendars = c.value(.hiddenCalendars, hiddenCalendars)
        taskPresets = c.value(.taskPresets, taskPresets)
    }

    func apply(to s: inout AppSettings) {
        s.nudgeEnabled = nudgeEnabled; s.nudgeIntervalMinutes = nudgeIntervalMinutes
        s.nudgeChannels = nudgeChannels; s.nudgeOnlyWhenIncomplete = nudgeOnlyWhenIncomplete
        s.checkInOnLaunch = checkInOnLaunch; s.checkInOnWake = checkInOnWake; s.checkInOnUnlock = checkInOnUnlock
        s.checkInOnlyWhenIncomplete = checkInOnlyWhenIncomplete; s.checkInChannels = checkInChannels
        s.defaultChannels = defaultChannels; s.untimedReminderMinutes = untimedReminderMinutes
        s.bannerAutoDismissSeconds = bannerAutoDismissSeconds; s.minReflectionWords = minReflectionWords
        s.showGoogleEvents = showGoogleEvents; s.googleEventReminderMinutes = googleEventReminderMinutes
        s.availability = availability
        s.autoImportCalendars = autoImportCalendars; s.importDaysAhead = importDaysAhead
        s.hiddenCalendars = hiddenCalendars
        s.taskPresets = taskPresets
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
