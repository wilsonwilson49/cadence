import Foundation

/// How hard a task keeps after you until it's checked off. Stored on the task as `nag` (same values on the web).
enum NagLevel: String, CaseIterable, Identifiable {
    case normal, persistent, pushy, strict
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .persistent: return "Persistent"
        case .pushy: return "Pushy"
        case .strict: return "Strict"
        }
    }
    var detail: String {
        switch self {
        case .normal: return "One reminder at the times you choose."
        case .persistent: return "The reminder comes back every few minutes until it's checked off."
        case .pushy: return "A window opens in the middle of the screen, again and again."
        case .strict: return "Covers the screen, putting it off asks why, and the Mac blocks your distracting apps and sites until it's done."
        }
    }
    var symbol: String {
        switch self {
        case .normal: return "bell"
        case .persistent: return "bell.badge"
        case .pushy: return "macwindow.badge.plus"
        case .strict: return "lock"
        }
    }
    static let everyChoices = [3, 5, 10, 15, 20, 30, 60]
}

extension PlanTask {
    var nagLevel: NagLevel { NagLevel(rawValue: nag ?? "") ?? .normal }
    var nagMinutes: Int { max(1, nagEvery ?? 10) }
}

extension Store {
    /// When a task starts keeping after you on its day: its time, or the untimed reminder time.
    /// Overdue items started long ago.
    func nagStart(_ occ: Occurrence, now: Date = Date()) -> Date {
        if occ.day < now.startOfDay && !occ.task.isUntilDone { return occ.day }
        let day = occ.task.isUntilDone ? now.startOfDay : occ.day
        return occ.task.timeMinutes.map { dayAt(day, minutes: $0) } ?? dayAt(day, minutes: settings.untimedReminderMinutes)
    }

    /// Open items that are past their start and set to keep after you.
    func nagging(now: Date = Date()) -> [Occurrence] {
        todayChecklist().filter { $0.task.nagLevel != .normal && !$0.isResolved && nagStart($0, now: now) <= now }
    }
}
