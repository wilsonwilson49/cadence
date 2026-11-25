import Foundation

/// Time spent focusing (sprints), working (Focus › Work) and studying, for the calendars: where each block
/// sat in the day, and the totals, so you can see how much of it you've been doing.
struct FocusBlock: Identifiable, Hashable {
    enum Kind: String { case focus, work, study
        var title: String { switch self { case .focus: "Focus sprint"; case .work: "Work"; case .study: "Study" } }
    }
    let id: String
    let start: Date
    let end: Date
    let kind: Kind
    let title: String
    var minutes: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }
}

extension Store {
    /// Every focus, work and study session that overlaps the day, clipped to it.
    func focusBlocks(on day: Date) -> [FocusBlock] {
        let s = day.startOfDay, e = s.adding(days: 1)
        func clip(_ a: Date, _ b: Date) -> (Date, Date)? {
            let x = max(a, s), y = min(b, e)
            return y.timeIntervalSince(x) >= 60 ? (x, y) : nil
        }
        var out: [FocusBlock] = []
        // A finished study session is also saved as a focus session (same id, for points): count it once, as study.
        let studyIDs = Set(studyLogs.map(\.id))
        for f in focusSessions where !studyIDs.contains(f.id) && f.finishedTitles.first?.hasPrefix("Study: ") != true {
            let title = f.isWork ? (f.title ?? "Work") : f.finished > 0 ? "\(f.finished) of \(f.picked) done" : "Focus sprint"
            // Pauses are gaps: one block per stretch of actual focus.
            for (i, seg) in f.segments.enumerated() {
                guard let (a, b) = clip(seg.start, seg.end) else { continue }
                out.append(FocusBlock(id: i == 0 ? "f-\(f.id)" : "f-\(f.id)-\(i)", start: a, end: b, kind: f.isWork ? .work : .focus, title: title))
            }
        }
        for l in studyLogs {
            guard let (a, b) = clip(l.startedAt, l.endedAt) else { continue }
            out.append(FocusBlock(id: "s-\(l.id)", start: a, end: b, kind: .study, title: l.title))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Minutes of focus (sprints and work) and of study on a day.
    func focusMinutes(on day: Date) -> (focus: Int, study: Int) {
        focusBlocks(on: day).reduce(into: (0, 0)) { t, b in
            if b.kind == .study { t.1 += b.minutes } else { t.0 += b.minutes }
        }
    }
}
