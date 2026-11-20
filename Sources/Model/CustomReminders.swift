import Foundation

/// A notification you program yourself, for anything (not tied to a task): "Drink water" every hour 9–5,
/// "Stretch" at 11:00 and 15:00 on weekdays, "Call the dentist" once on Friday at 10:00.
/// Syncs as kind "reminder"; same shape as the web's customReminder.
struct CustomReminder: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case times, every, once
        var id: String { rawValue }
        var title: String { self == .times ? "At set times" : self == .every ? "Every so often" : "Once" }
    }
    var id = UUID()
    var title = ""
    var body = ""
    var kind: Kind = .times
    /// Minutes after midnight (times).
    var times: [Int] = [9 * 60]
    /// 1 = Sunday … 7 = Saturday; empty = every day (times, every).
    var weekdays: [Int] = []
    /// Every: how often, and between which times.
    var everyMinutes = 60
    var fromMinutes = 9 * 60
    var toMinutes = 17 * 60
    /// Once: when.
    var at = Date().addingTimeInterval(3600)
    var enabled = true
    var channels: Set<AlertChannel> = [.notification, .banner]
    var createdAt = Date()
    var updatedAt: Date?

    init(title: String = "") { self.title = title }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); title = c.value(.title, ""); body = c.value(.body, "")
        kind = c.value(.kind, Kind.times); times = c.value(.times, [540]); weekdays = c.value(.weekdays, [])
        everyMinutes = max(5, c.value(.everyMinutes, 60)); fromMinutes = c.value(.fromMinutes, 540); toMinutes = c.value(.toMinutes, 1020)
        at = c.value(.at, Date()); enabled = c.value(.enabled, true)
        channels = c.value(.channels, [.notification, .banner]); createdAt = c.value(.createdAt, Date()); updatedAt = c.value(.updatedAt, nil as Date?)
    }

    /// When it goes off on a day. Same as reminderFireTimes() on the web.
    func fireTimes(on day: Date) -> [Date] {
        guard enabled else { return [] }
        let d = day.startOfDay
        let wd = Calendar.current.component(.weekday, from: d)
        switch kind {
        case .once: return at.isSameDay(d) ? [at] : []
        case .times:
            guard weekdays.isEmpty || weekdays.contains(wd) else { return [] }
            return times.sorted().map { dayAt(d, minutes: $0) }
        case .every:
            guard weekdays.isEmpty || weekdays.contains(wd), everyMinutes >= 5 else { return [] }
            return stride(from: fromMinutes, through: toMinutes, by: everyMinutes).map { dayAt(d, minutes: $0) }
        }
    }

    /// "Every day at 9:00, 15:00" / "Weekdays, every 1h from 9:00 to 17:00" / "Once, Fri Nov 21 at 10:00".
    var summary: String {
        let days: String = {
            let w = Set(weekdays)
            if w.isEmpty || w.count == 7 { return "Every day" }
            if w == [2, 3, 4, 5, 6] { return "Weekdays" }
            if w == [1, 7] { return "Weekends" }
            return weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        }()
        switch kind {
        case .once: return "Once, \(at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(timeString(at))"
        case .times: return "\(days) at \(times.sorted().map { timeString(minutes: $0) }.joined(separator: ", "))"
        case .every:
            let e = everyMinutes % 60 == 0 ? "\(everyMinutes / 60)h" : "\(everyMinutes) min"
            return "\(days), every \(e) from \(timeString(minutes: fromMinutes)) to \(timeString(minutes: toMinutes))"
        }
    }
}

extension CustomReminder: SyncedRecord { var stampFallback: Date { createdAt } }
