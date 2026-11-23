import Foundation

/// Follow-up (trigger) tasks: "after X, do Y". Y waits off every list until X is checked off, then comes up as a
/// one-off with a reminder, right away or a set time later. Chains work (Y can have its own follow-ups).
/// Same rules on the web (model.js armFollowUp / store.complete).
extension PlanTask {
    var isFollowUp: Bool { after != nil }
    var isWaiting: Bool { after != nil && armedAt == nil }
    static let afterChoices = [0, 5, 10, 15, 30, 60, 120, 240]
    static func afterLabel(_ m: Int) -> String { m == 0 ? "Right away" : "\(TaskStats.format(m)) later" }
}

extension Store {
    func followUps(of id: UUID) -> [PlanTask] { tasks.filter { $0.after == id && $0.archived != true } }

    /// Tasks `id` could follow without making a loop (not itself, not anything that already follows it).
    func possibleTriggers(for id: UUID) -> [PlanTask] {
        var below: Set<UUID> = [id], frontier = [id]
        while let x = frontier.popLast() {
            for f in tasks where f.after == x && !below.contains(f.id) { below.insert(f.id); frontier.append(f.id) }
        }
        return tasks.filter { !below.contains($0.id) && !$0.isEvent && $0.archived != true }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// X was checked off: its follow-ups come up, each `afterMinutes` from now (on the next whole minute).
    func armFollowUps(of id: UUID, key: String, at now: Date = Date()) {
        for i in tasks.indices where tasks[i].after == id && tasks[i].archived != true {
            var f = tasks[i]
            let raw = now.addingTimeInterval(Double(max(0, f.afterMinutes ?? 0) * 60))
            let when = Date(timeIntervalSinceReferenceDate: (raw.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
            let day = when.startOfDay, dayKey = DateKey.string(day)
            f.startDate = day
            f.timeMinutes = when.minutesSinceMidnight
            f.recurrence = Recurrence()
            if f.mode == "longTerm" { f.mode = nil }
            f.cycleGapDays = nil; f.cycleTimes = nil; f.dueDate = nil
            f.completions[dayKey] = nil
            f.missed?[dayKey] = nil
            f.skipped.remove(dayKey)
            f.armedAt = now
            f.armedBy = "\(id.uuidString)|\(key)"
            tasks[i] = f
        }
    }

    /// X was unchecked: follow-ups it set off go back to waiting, unless they're already done.
    func disarmFollowUps(of id: UUID, key: String) {
        let tag = "\(id.uuidString)|\(key)"
        for i in tasks.indices where tasks[i].after == id && tasks[i].armedBy == tag {
            let f = tasks[i]
            if f.completions[DateKey.string(f.startDate)] == nil { tasks[i].armedAt = nil; tasks[i].armedBy = nil }
        }
    }
}
