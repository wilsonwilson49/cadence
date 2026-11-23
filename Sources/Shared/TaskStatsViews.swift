import SwiftUI

// Priority, hardness and time-taken pieces shared by the Mac and iPhone apps (rules in Model/TaskStats.swift).

extension Priority {
    var color: Color { switch self { case .high: .red; case .medium: .orange; case .low: .blue } }
}

extension Hardness {
    static func color(_ n: Int) -> Color { n <= 2 ? .green : n == 3 ? .yellow : n == 4 ? .orange : .red }
}

/// Five bars, rising like a signal meter, filled up to the task's hardness.
struct HardnessMeter: View {
    let level: Int
    var height: CGFloat = 10
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Hardness.range, id: \.self) { n in
                RoundedRectangle(cornerRadius: 1)
                    .fill(n <= level ? Hardness.color(level) : Color.primary.opacity(0.15))
                    .frame(width: max(2.5, height * 0.3), height: height * (0.4 + 0.15 * CGFloat(n - 1)))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Hardness \(level) of 5, \(Hardness.title(level))")
    }
}

/// Pick a hardness by clicking a bar (click it again to clear).
struct HardnessPicker: View {
    @Binding var value: Int?
    var barHeight: CGFloat = 22
    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Hardness.range, id: \.self) { n in
                    Button { value = value == n ? nil : n } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(n <= (value ?? 0) ? Hardness.color(value ?? n) : Color.primary.opacity(0.13))
                            .frame(width: barHeight * 0.75, height: barHeight * (0.4 + 0.15 * CGFloat(n - 1)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(n): \(Hardness.title(n))")
                    .accessibilityLabel("\(n), \(Hardness.title(n))")
                }
            }
            Text(value.map { "\($0) · \(Hardness.title($0))" } ?? "Not rated").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

enum TaskStatsText {
    /// "Usually about 40 min: 60% of the 7 times you timed took that long or less." / "It took 40 min the one time you timed it."
    static func typical(_ task: PlanTask) -> String? {
        let times = task.takenTimes
        guard let p = task.typicalMinutes else { return nil }
        if times.count == 1 { return "It took \(TaskStats.format(p)) the one time you timed it." }
        return "Usually about \(TaskStats.format(p)): 60% of the \(times.count) times you timed took that long or less."
    }
}

/// Every recorded time as a tick on a line from 0 to the longest, with the part up to the 60% mark filled in,
/// so you can see how long it usually takes and how much it varies.
struct TimeSpread: View {
    let times: [Int]
    var body: some View {
        if let typical = TaskStats.percentile(times, 0.6), let longest = times.last {
            let top = Double(max(longest, 1))
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6)
                        Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(6, w * Double(typical) / top), height: 6)
                        ForEach(Array(times.enumerated()), id: \.offset) { _, t in
                            Rectangle().fill(t <= typical ? Color.accentColor : Color.secondary)
                                .frame(width: 2, height: 14)
                                .offset(x: min(w - 2, max(0, w * Double(t) / top - 1)))
                        }
                        Rectangle().fill(Color.primary).frame(width: 2, height: 20)
                            .offset(x: min(w - 2, max(0, w * Double(typical) / top - 1)))
                    }
                    .frame(height: 20)
                }
                .frame(height: 20)
                HStack {
                    Text("0")
                    Spacer()
                    Text("60% ≤ \(TaskStats.format(typical))").fontWeight(.semibold)
                    Spacer()
                    Text("longest \(TaskStats.format(longest))")
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement()
            .accessibilityLabel("60% of \(times.count) times took \(TaskStats.format(typical)) or less; the longest took \(TaskStats.format(longest))")
        }
    }
}

/// "How long did it take?" when checking something off: type it (45, 1:30, 1h 30m) or pick a length.
struct TimeTakenField: View {
    let task: PlanTask
    @Binding var text: String

    static func isValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || TaskStats.parseMinutes(text) != nil
    }

    private var parsed: Int? { TaskStats.parseMinutes(text) }

    private var choices: [Int] {
        var c = [15, 30, 45, 60, 90]
        if task.timeMinutes != nil { c.append(task.durationMinutes) }
        if let t = task.typicalMinutes { c.append(t) }
        return Array(Set(c)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(iOS)
            Label("How long did it take?", systemImage: "stopwatch").fontWeight(.medium)
            HStack(spacing: 8) {
                field.keyboardType(.numbersAndPunctuation)
                note
            }
            ScrollView(.horizontal, showsIndicators: false) { chips }
            #else
            HStack(spacing: 8) {
                Label("How long did it take?", systemImage: "stopwatch").fontWeight(.medium)
                field.frame(width: 120)
                note
            }
            chips
            #endif
            if let line = TaskStatsText.typical(task) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var field: some View {
        TextField("Time taken", text: $text, prompt: Text("e.g. 45 or 1:30"))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Time taken")
    }

    @ViewBuilder private var note: some View {
        if let parsed {
            Text(TaskStats.format(parsed)).foregroundStyle(.secondary)
        } else if !Self.isValid(text) {
            Text("Try 45, 1:30 or 1h 30m").foregroundStyle(.orange)
        } else {
            Text("optional").foregroundStyle(.tertiary)
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(choices, id: \.self) { m in
                Button(TaskStats.format(m)) { text = "\(m)" }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(m == parsed ? .accentColor : nil)
            }
        }
    }
}

extension FocusBlock.Kind {
    var color: Color { switch self { case .work: .accentColor; case .focus: .purple; case .study: .green } }
}
