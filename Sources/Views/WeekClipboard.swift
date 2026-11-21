import AppKit
import SwiftUI

/// Week calendar: ⌘Z / ⌘X / ⌘C / ⌘V. Copy and cut take the picked tasks, or the one under the mouse; paste drops
/// them at the spot under the mouse (keeping their spacing), or on today if the mouse isn't over the calendar.
extension AppModel {
    /// Tasks as they were before each week change, newest last.
    func pushWeekUndo() {
        weekUndo.append(store.tasks)
        if weekUndo.count > 30 { weekUndo.removeFirst() }
    }

    func weekUndoLast() -> Bool {
        guard let last = weekUndo.popLast() else { return false }
        store.tasks = last
        weekSelection = [:]
        return true
    }

    private var weekTargets: [Occurrence] {
        if !weekSelection.isEmpty { return Array(weekSelection.values) }
        return weekHoverOcc.map { [$0] } ?? []
    }

    /// Copies as one-off tasks on the day (and time) they were picked.
    func weekCopy() -> Bool {
        let occs = weekTargets.filter { !$0.task.isEvent || $0.task.source == nil }
        guard !occs.isEmpty else { return false }
        weekClipboard = occs.map { o in
            var t = o.task
            t.startDate = o.day.startOfDay
            t.recurrence = Recurrence()
            if t.isUntilDone, let due = t.dueDate { t.dueDate = due }
            return t
        }
        return true
    }

    func weekCut() -> Bool {
        let occs = weekTargets
        guard weekCopy() else { return false }
        pushWeekUndo()
        for o in occs { store.delete(o, scope: .one) }
        weekSelection = [:]
        return true
    }

    func weekPaste() -> Bool {
        guard !weekClipboard.isEmpty else { return false }
        let target = weekHoverPoint ?? (Date().startOfDay, nil)
        func when(_ t: PlanTask) -> Date { dayAt(t.startDate, minutes: t.timeMinutes ?? 0) }
        let first = weekClipboard.map(when).min()!
        let anchor = dayAt(target.day, minutes: target.minutes ?? weekClipboard.compactMap(\.timeMinutes).min() ?? 0)
        let shift = anchor.timeIntervalSince(first)
        pushWeekUndo()
        weekSelection = [:]
        for src in weekClipboard {
            var t = PlanTask(title: src.title, startDate: src.startDate)
            let copyID = t.id
            t = src
            t.id = copyID; t.createdAt = Date(); t.updatedAt = nil
            t.completions = [:]; t.missed = nil; t.skipped = []; t.stepsDone = nil
            t.googleEventID = nil; t.googleTaskID = nil; t.source = nil; t.externalURL = nil; t.sourceCalendar = nil; t.archived = nil
            let moved = when(src).addingTimeInterval(shift)
            t.startDate = moved.startOfDay
            if src.timeMinutes != nil { t.timeMinutes = Calendar.current.component(.hour, from: moved) * 60 + Calendar.current.component(.minute, from: moved) }
            if let due = src.dueDate { t.dueDate = due.addingTimeInterval(shift).startOfDay }
            store.upsert(t)
            if let o = store.occurrences(on: t.startDate).first(where: { $0.task.id == t.id }) { weekSelection[o.id] = o }
        }
        return true
    }

    /// Handles a key press on the Week screen. Returns true if it was used.
    func weekKey(_ e: NSEvent) -> Bool {
        guard screen == .week, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        switch e.charactersIgnoringModifiers {
        case "z": return weekUndoLast()
        case "x": return weekCut()
        case "c": return weekCopy()
        case "v": return weekPaste()
        default: return false
        }
    }
}
