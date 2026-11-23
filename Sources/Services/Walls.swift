import AppKit
import SwiftUI

// Full-screen walls: they cover every screen, above full-screen apps and the menu bar, until you deal with them.
// - Reflections: when a focus session ends, write the reflection for each thing you finished (Focus).
// - Decision: the minutes you gave yourself after opening your Mac are up; pick what's next (Screen time walls).
// - Away: you were away a while during the day; write what happened before carrying on (Screen time walls).
// ⌥⌘Q (Quit Cadence completely) always works as a way out.

extension Reflection {
    /// Reflections that aren't about a task: "Away from the computer" and "Kept going" decisions.
    static let awayTaskID = UUID(uuidString: "5A7E0000-0000-4000-8000-00000000A0A7")!
    static let decisionTaskID = UUID(uuidString: "5A7E0000-0000-4000-8000-00000000DEC1")!
    var isAway: Bool { outcome == "away" }
    var isDecision: Bool { outcome == "decision" }
}

@MainActor
final class Walls: ObservableObject {
    enum Kind: Equatable {
        case reflections([Occurrence], minutes: Int?)
        case decision
        case away(from: Date, to: Date)
    }

    private unowned let model: AppModel
    private var windows: [NSWindow] = []
    @Published private(set) var showing: Kind?
    /// From Settings' preview buttons: answers aren't kept, and there's a way out.
    @Published private(set) var previewing = false

    init(model: AppModel) { self.model = model }

    var isShowing: Bool { showing != nil }

    func show(_ kind: Kind, preview: Bool = false) {
        hide()
        showing = kind
        previewing = preview
        let main = NSScreen.main ?? NSScreen.screens.first
        let content = WallView(kind: kind, walls: self)
            .environmentObject(model).environmentObject(model.store).environmentObject(model.focus)
            .tint(Theme.accent).modifier(AppFontScope())
        // -wallPreview: an ordinary window, so a test never covers the screen.
        if LaunchOptions.has("-wallPreview") {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: content.frame(width: 1100, height: 760).background(Color(nsColor: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1))).preferredColorScheme(.dark))
            w.isReleasedWhenClosed = false
            w.title = "Wall preview"
            w.center(); w.orderFrontRegardless()
            windows = [w]
            return
        }
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.98)
            w.isOpaque = false
            if screen == main {
                w.contentViewController = NSHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark))
            } else {
                w.contentViewController = NSHostingController(rootView: Text("Cadence: \(Self.otherScreenText(kind))")
                    .font(Theme.heading(26)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark))
            }
            w.setFrame(screen.frame, display: true)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        windows.first { $0.screen == main }?.makeKey()
        NSSound(named: "Glass")?.play()
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        showing = nil
        previewing = false
    }

    private static func otherScreenText(_ k: Kind) -> String {
        switch k {
        case .reflections: return "reflect on what you just did"
        case .decision: return "time to decide what's next"
        case .away: return "what happened while you were away?"
        }
    }

    // MARK: Reflections after a focus session

    /// Opens right away and stays until each one has a reflection (or you say you didn't finish it).
    func reflect(on occs: [Occurrence], minutes: Int? = nil) {
        let open = occs.filter { !$0.isResolved }
        guard !open.isEmpty else { return }
        show(.reflections(open, minutes: minutes))
    }

    /// One reflection written (or one dropped): on to the next, or done.
    func finishedReflection(_ occ: Occurrence) {
        guard case .reflections(let list, let minutes) = showing else { return }
        let rest = list.filter { $0.id != occ.id }
        if rest.isEmpty { hide(); model.guardian.restartAllowance() } else { show(.reflections(rest, minutes: minutes)) }
    }
}

/// What's on the wall.
struct WallView: View {
    let kind: Walls.Kind
    let walls: Walls
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if walls.previewing {
                    HStack {
                        Text("Preview: what you write here isn't kept").foregroundStyle(.secondary)
                        Button("Close preview") { walls.hide() }.keyboardShortcut(.cancelAction)
                    }
                    .font(.app(.callout)).padding(.bottom, 20)
                }
                switch kind {
                case .reflections(let list, let minutes):
                    if let occ = list.first {
                        VStack(spacing: 14) {
                            Text(list.count > 1 ? "REFLECT BEFORE YOU MOVE ON · \(list.count) LEFT" : "REFLECT BEFORE YOU MOVE ON")
                                .font(.app(.caption).weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                            ReflectionForm(occurrence: occ, minWords: store.settings.minReflectionWords, initialMinutes: minutes,
                                           cancelTitle: "I didn't finish it") { text, taken in
                                store.complete(occ, reflection: text, minutes: taken)
                                walls.finishedReflection(occ)
                            } onCancel: {
                                walls.finishedReflection(occ)
                            }
                            .id(occ.id)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(nsColor: .windowBackgroundColor)))
                        }
                    }
                case .decision:
                    DecisionWall(walls: walls)
                case .away(let from, let to):
                    AwayWall(from: from, to: to, walls: walls)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
    }
}

/// A text box that needs enough words, and (if it's on) Gemini's OK, before `onSubmit` runs.
struct WallWriting: View {
    let prompt: String
    let about: String
    let minWords: Int
    let buttonTitle: String
    let onSubmit: (String) -> Void
    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(.app(.body)).scrollContentBackground(.hidden).padding(8).focused($focused)
                if text.isEmpty { Text(prompt).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false) }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.app(.callout)) }
            HStack {
                let n = countWords(text)
                Text("\(n) / \(minWords) words").monospacedDigit().foregroundStyle(n >= minWords ? .green : .secondary)
                if checking { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                Spacer()
                Button(buttonTitle) { submit() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(n < minWords || checking)
            }
            .font(.app(.callout))
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard countWords(t) >= minWords else { return }
        guard AICheck.enabled else { onSubmit(t); return }
        checking = true; problem = nil
        Task {
            let v = await AICheck.check(t, about: about)
            checking = false
            if v.genuine { onSubmit(t) } else { problem = v.reason }
        }
    }
}

/// The minutes you gave yourself are up: work on something, keep going (with a reason), or stop.
struct DecisionWall: View {
    let walls: Walls
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @State private var more = 15
    @State private var keepGoing = false

    var body: some View {
        let open = store.todayChecklist().filter { !$0.isResolved && !$0.isEvent }.enumerated()
            .sorted { ($0.element.task.priorityLevel?.rank ?? 3, $0.offset) < ($1.element.task.priorityLevel?.rank ?? 3, $1.offset) }
            .map(\.element).prefix(5)
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "hourglass.bottomhalf.filled").font(.system(size: 38)).foregroundStyle(.orange)
            Text("TIME TO DECIDE").font(.app(.caption).weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
            Text("Your \(Focus.label(model.guardian.allowanceMinutes)) are up").font(Theme.heading(36, .bold))
            Text("You gave yourself \(Focus.label(model.guardian.allowanceMinutes)) when you sat down. What now?")
                .font(.app(.title3)).foregroundStyle(.secondary)

            if !open.isEmpty {
                Text("Work on one of these").font(.app(.headline)).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(open)) { o in
                        WorkPickRow(occ: o) { let p = walls.previewing; walls.hide(); if !p { model.workOn(o) } }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(nsColor: .controlBackgroundColor)))
            }

            HStack(spacing: 10) {
                Button { keepGoing.toggle() } label: { Label("Keep going…", systemImage: "arrow.clockwise") }.controlSize(.large)
                Button { let p = walls.previewing; walls.hide(); if !p { model.guardian.stopForNow() } } label: { Label("I'm done: lock the screen", systemImage: "lock") }.controlSize(.large)
            }
            if keepGoing {
                HStack {
                    Text("For")
                    Picker("", selection: $more) { ForEach([10, 15, 30, 60], id: \.self) { Text(Focus.label($0)).tag($0) } }
                        .labelsHidden().fixedSize()
                    Text("more. Why? Say what you'll do with it.")
                }
                .font(.app(.callout))
                WallWriting(prompt: "e.g. finishing the reading for tomorrow's class, then I'm off", about: "Asking for \(more) more minutes on the computer",
                            minWords: 6, buttonTitle: "Keep going") { text in
                    if walls.previewing { walls.hide(); return }
                    store.reflections.insert(Reflection(taskID: Reflection.decisionTaskID, taskTitle: "Kept going for \(Focus.label(more))",
                                                        occurrenceKey: "decision|\(ISO8601DateFormatter().string(from: Date()))", text: text, outcome: "decision"), at: 0)
                    walls.hide()
                    model.guardian.extend(minutes: more)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(32)
    }
}

/// You were away during the day: write what happened before carrying on.
struct AwayWall: View {
    let from: Date
    let to: Date
    let walls: Walls
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        let mins = max(1, Int(to.timeIntervalSince(from) / 60))
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 38)).foregroundStyle(Theme.accent)
            Text("WHILE YOU WERE AWAY").font(.app(.caption).weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
            Text("You were away for \(Focus.label(mins))").font(Theme.heading(36, .bold))
            Text("\(timeString(from)) – \(timeString(to)). Before you carry on: what happened, and was it what you meant to do?")
                .font(.app(.title3)).foregroundStyle(.secondary)
            let missed = store.todayChecklist().filter { !$0.isResolved && ($0.start.map { $0 >= from && $0 <= to } ?? false) }
            if !missed.isEmpty {
                Label("Due while you were away: \(missed.map(\.task.title).joined(separator: ", "))", systemImage: "clock.badge.exclamationmark")
                    .font(.app(.callout)).foregroundStyle(.orange)
            }
            WallWriting(prompt: "What were you doing, and why? Honest is fine: a nap, your phone, a friend dropped by…",
                        about: "Away from the computer for \(mins) minutes during the day (\(timeString(from))–\(timeString(to)))",
                        minWords: max(8, store.settings.minReflectionWords / 2), buttonTitle: "Carry on") { text in
                if walls.previewing { walls.hide(); return }
                store.reflections.insert(Reflection(taskID: Reflection.awayTaskID, taskTitle: "Away \(timeString(from))–\(timeString(to)) (\(Focus.label(mins)))",
                                                    occurrenceKey: "away|\(DateKey.string(from))|\(from.minutesSinceMidnight)", text: text, outcome: "away"), at: 0)
                walls.hide()
                model.guardian.restartAllowance()
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(32)
    }
}
