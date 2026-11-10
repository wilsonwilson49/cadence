import SwiftUI

// MARK: - Flashcards

/// Flashcards per course, reviewed with spaced repetition: the ones you get right come back less often.
struct FlashcardsView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("cardsCourse") private var courseKey = ""
    @State private var reviewing = false
    @State private var front = ""
    @State private var back = ""
    @State private var search = ""
    @State private var addTo = ""

    private var course: Course? { UUID(uuidString: courseKey).flatMap(store.course) }

    var body: some View {
        let courses = store.activeCourses
        VStack(spacing: 0) {
            ScreenHeader(title: "Flashcards", subtitle: "Spaced repetition: what you know comes back less often, what you miss comes back soon.") {
                Picker("Course", selection: $courseKey) {
                    Text("All courses").tag("")
                    ForEach(courses) { Text($0.title).tag($0.id.uuidString) }
                }
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if courses.isEmpty {
                        Card { Text("Flashcards belong to a preset (one per subject works well). Make one under Study › Presets first.").foregroundStyle(.secondary) }
                    } else if reviewing {
                        CardReview(courseIDs: course.map { [$0.id] } ?? courses.map(\.id)) { reviewing = false }
                    } else {
                        let due = (course.map { [$0] } ?? courses).reduce(0) { $0 + $1.dueCards().count }
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(due)").font(.system(size: 34, weight: .bold).monospacedDigit())
                                Text(due == 1 ? "card due today" : "cards due today").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { reviewing = true } label: { Label("Review", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(due == 0)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.pink.opacity(0.08)))
                        if let c = course ?? UUID(uuidString: addTo).flatMap(store.course) ?? courses.first {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        SectionTitle(text: "New card", symbol: "plus.rectangle.on.rectangle")
                                        if course == nil {
                                            Picker("for", selection: Binding(get: { c.id.uuidString }, set: { addTo = $0 })) {
                                                ForEach(courses) { Text($0.title).tag($0.id.uuidString) }
                                            }
                                            .fixedSize()
                                        } else {
                                            Text("for \(c.title)").foregroundStyle(.secondary)
                                        }
                                    }
                                    TextField("Front (question)", text: $front, axis: .vertical).textFieldStyle(.roundedBorder)
                                    TextField("Back (answer)", text: $back, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit { add(c) }
                                    HStack { Spacer(); Button("Add card") { add(c) }.disabled(front.trimmingCharacters(in: .whitespaces).isEmpty) }
                                }
                            }
                        }
                        TextField("Search cards", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                        ForEach(course.map { [$0] } ?? courses) { c in
                            let cards = c.cards.filter { search.isEmpty || $0.front.localizedCaseInsensitiveContains(search) || $0.back.localizedCaseInsensitiveContains(search) }
                            if !cards.isEmpty {
                                SectionTitle(text: c.title, symbol: "rectangle.on.rectangle.angled", count: cards.count)
                                Card {
                                    VStack(spacing: 0) {
                                        ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                                            if i > 0 { Divider() }
                                            CardRow(courseID: c.id, card: card)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func add(_ c: Course) {
        let f = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        store.editCourse(c.id) { $0.cards.append(Flashcard(front: f, back: back.trimmingCharacters(in: .whitespacesAndNewlines))) }
        front = ""; back = ""
    }
}

private struct CardRow: View {
    @EnvironmentObject private var store: Store
    let courseID: UUID
    let card: Flashcard

    private func bind(_ k: WritableKeyPath<Flashcard, String>) -> Binding<String> {
        Binding(get: { card[keyPath: k] }, set: { v in
            store.editCourse(courseID) { c in if let i = c.cards.firstIndex(where: { $0.id == card.id }) { c.cards[i][keyPath: k] = v } }
        })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("Front", text: bind(\.front), axis: .vertical).textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            TextField("Back", text: bind(\.back), axis: .vertical).textFieldStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(card.isDue() ? "due" : "in \(Calendar.current.dateComponents([.day], from: Date().startOfDay, to: DateKey.date(card.due) ?? Date()).day ?? 0)d")
                .font(.caption.monospacedDigit()).foregroundStyle(card.isDue() ? .pink : .secondary).frame(width: 44, alignment: .trailing)
            Button { store.editCourse(courseID) { $0.cards.removeAll { $0.id == card.id } } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// One card at a time: think, reveal, say how it went. "Again" puts it back in today's pile.
struct CardReview: View {
    @EnvironmentObject private var store: Store
    let courseIDs: [UUID]
    let done: () -> Void
    @State private var queue: [(UUID, UUID)] = []
    @State private var shown = false
    @State private var reviewed = 0
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(reviewed) reviewed · \(queue.count) left").foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { done() }
            }
            if let (cid, kid) = queue.first, let course = store.course(cid), let card = course.cards.first(where: { $0.id == kid }) {
                VStack(spacing: 16) {
                    Text(course.title).font(.caption.weight(.semibold)).foregroundStyle(course.color.color)
                    Text(card.front).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if shown {
                        Divider()
                        Text(card.back.isEmpty ? "(no answer written)" : card.back).font(.title3).multilineTextAlignment(.center)
                            .foregroundStyle(card.back.isEmpty ? .secondary : .primary)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
                if shown {
                    HStack(spacing: 10) {
                        ForEach(Flashcard.Grade.allCases, id: \.rawValue) { g in
                            Button { grade(g, cid, kid) } label: { Text(g.title).frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                                .tint(g == .again ? .red : g == .hard ? .orange : g == .good ? .green : .blue)
                                .keyboardShortcut(KeyEquivalent(Character("\(g.rawValue + 1)")), modifiers: [])
                        }
                    }
                    .controlSize(.large)
                    Text("Keys 1–4 also work.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { shown = true } label: { Text("Show answer").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.space, modifiers: [])
                }
            } else {
                Card {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                        Text(reviewed == 0 ? "Nothing due." : "All done: \(reviewed) reviewed.").font(.headline)
                        Button("Back to cards") { done() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            queue = courseIDs.compactMap(store.course).flatMap { c in c.dueCards().map { (c.id, $0.id) } }.shuffled()
        }
    }

    private func grade(_ g: Flashcard.Grade, _ cid: UUID, _ kid: UUID) {
        store.editCourse(cid) { c in if let i = c.cards.firstIndex(where: { $0.id == kid }) { c.cards[i].review(g) } }
        reviewed += 1
        queue.removeFirst()
        if g == .again { queue.append((cid, kid)) }
        shown = false
    }
}

// MARK: - Notes

/// Plain notes that sync: class notes, ideas, anything that isn't a task.
struct NotesView: View {
    @EnvironmentObject private var store: Store
    @State private var selected: UUID?
    @State private var search = ""

    var body: some View {
        let notes = store.sortedNotes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 0) {
            ScreenHeader(title: "Notes", subtitle: "Quick notes that sync to your iPhone and the web.") {
                Button { newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(10)
                    List(selection: $selected) {
                        ForEach(notes) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if n.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                                    Text(n.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                                }
                                Text((n.updatedAt ?? n.createdAt).formatted(.dateTime.month(.abbreviated).day()) + "  " + n.body.replacingOccurrences(of: "\n", with: " ").prefix(60))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(n.id)
                            .contextMenu {
                                Button(n.pinned == true ? "Unpin" : "Pin") { var m = n; m.pinned = n.pinned == true ? nil : true; store.upsert(m) }
                                Button("Delete", role: .destructive) { store.deleteNote(n.id); if selected == n.id { selected = nil } }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 260)
                Divider()
                if let id = selected, let n = store.notes.first(where: { $0.id == id }) {
                    NoteEditor(note: n).id(n.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text").font(.largeTitle).foregroundStyle(.secondary)
                        Text(store.notes.isEmpty ? "No notes yet." : "Pick a note.").foregroundStyle(.secondary)
                        Button("New note") { newNote() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selected == nil { selected = notes.first?.id } }
    }

    private func newNote() {
        let n = Note()
        store.upsert(n)
        selected = n.id
        search = ""
    }
}

private struct NoteEditor: View {
    @EnvironmentObject private var store: Store
    let note: Note
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title).textFieldStyle(.plain).font(.title2.bold())
                .onChange(of: title) { _, v in save { $0.title = v } }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .onChange(of: text) { _, v in save { $0.body = v } }
        }
        .padding(18)
        .onAppear { title = note.title; text = note.body }
    }

    private func save(_ change: (inout Note) -> Void) {
        guard var n = store.notes.first(where: { $0.id == note.id }) else { return }
        change(&n)
        store.upsert(n)
    }
}
