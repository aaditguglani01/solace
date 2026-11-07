import SwiftUI

struct Chapter: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var done = false
    /// One tick per revision column of the subject (may be shorter than the column count).
    var revisions: [Bool] = []

    func revised(_ i: Int) -> Bool { revisions.indices.contains(i) && revisions[i] }
}

struct Subject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var revisionNames: [String] = []
    var chapters: [Chapter] = []
    var collapsed = false

    var doneCount: Int { chapters.filter(\.done).count }
    /// Percentage = chapters completed (revisions are tracked separately).
    var progress: Double { chapters.isEmpty ? 0 : Double(doneCount) / Double(chapters.count) }

    func revisionProgress(_ i: Int) -> Double {
        chapters.isEmpty ? 0 : Double(chapters.filter { $0.revised(i) }.count) / Double(chapters.count)
    }
}

@MainActor
final class SyllabusStore: ObservableObject {
    static let shared = SyllabusStore()
    static let maxRevisions = 6

    @Published var subjects: [Subject] {
        didSet { saver.schedule(subjects) }
    }
    private let saver = DebouncedSaver<[Subject]>("syllabus.json")
    func flush() { saver.flush() }

    init() {
        subjects = Storage.load([Subject].self, "syllabus.json") ?? []
    }

    var totalChapters: Int { subjects.reduce(0) { $0 + $1.chapters.count } }
    var totalDone: Int { subjects.reduce(0) { $0 + $1.doneCount } }
    /// Weighted by chapters, so a 30-chapter subject counts more than a 5-chapter one.
    var overall: Double { totalChapters == 0 ? 0 : Double(totalDone) / Double(totalChapters) }

    private func si(_ id: UUID) -> Int? { subjects.firstIndex { $0.id == id } }
    private func ci(_ s: Int, _ id: UUID) -> Int? { subjects[s].chapters.firstIndex { $0.id == id } }

    // Subjects
    func addSubject(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        subjects.append(Subject(name: t))
    }

    func deleteSubject(_ id: UUID) {
        subjects.removeAll { $0.id == id }
        if FocusLog.shared.currentSubjectID == id { FocusLog.shared.currentSubjectID = nil }
    }

    func toggleCollapsed(_ id: UUID) {
        guard let s = si(id) else { return }
        subjects[s].collapsed.toggle()
    }

    func moveSubjects(from source: IndexSet, to destination: Int) {
        subjects.move(fromOffsets: source, toOffset: destination)
    }

    // Chapters
    func addChapter(_ subjectID: UUID, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let s = si(subjectID) else { return }
        subjects[s].chapters.append(Chapter(name: t))
    }

    /// One chapter per non-empty line.
    func addChapters(_ subjectID: UUID, lines: String) {
        guard let s = si(subjectID) else { return }
        let names = lines.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        subjects[s].chapters += names.map { Chapter(name: $0) }
    }

    func deleteChapter(_ subjectID: UUID, _ chapterID: UUID) {
        guard let s = si(subjectID) else { return }
        subjects[s].chapters.removeAll { $0.id == chapterID }
    }

    func toggleDone(_ subjectID: UUID, _ chapterID: UUID) {
        guard let s = si(subjectID), let c = ci(s, chapterID) else { return }
        subjects[s].chapters[c].done.toggle()
    }

    func toggleRevision(_ subjectID: UUID, _ chapterID: UUID, _ i: Int) {
        guard let s = si(subjectID), let c = ci(s, chapterID) else { return }
        var revs = subjects[s].chapters[c].revisions
        while revs.count <= i { revs.append(false) }
        revs[i].toggle()
        subjects[s].chapters[c].revisions = revs
    }

    // Revision columns
    func addRevision(_ subjectID: UUID) {
        guard let s = si(subjectID), subjects[s].revisionNames.count < Self.maxRevisions else { return }
        subjects[s].revisionNames.append("Revision \(subjects[s].revisionNames.count + 1)")
    }

    func renameRevision(_ subjectID: UUID, _ i: Int, _ name: String) {
        guard let s = si(subjectID), subjects[s].revisionNames.indices.contains(i) else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        subjects[s].revisionNames[i] = t.isEmpty ? "Revision \(i + 1)" : t
    }

    func removeRevision(_ subjectID: UUID, _ i: Int) {
        guard let s = si(subjectID), subjects[s].revisionNames.indices.contains(i) else { return }
        subjects[s].revisionNames.remove(at: i)
        for c in subjects[s].chapters.indices where subjects[s].chapters[c].revisions.indices.contains(i) {
            subjects[s].chapters[c].revisions.remove(at: i)
        }
    }

    // Bindings for inline editing
    func subjectName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.subjects.first { $0.id == id }?.name ?? "" },
            set: { [weak self] v in
                guard let self, let s = self.si(id) else { return }
                self.subjects[s].name = v
            }
        )
    }

    func chapterName(_ subjectID: UUID, _ chapterID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.subjects.first { $0.id == subjectID }?.chapters.first { $0.id == chapterID }?.name ?? ""
            },
            set: { [weak self] v in
                guard let self, let s = self.si(subjectID), let c = self.ci(s, chapterID) else { return }
                self.subjects[s].chapters[c].name = v
            }
        )
    }
}

// MARK: - Views

struct ProgressLine: View {
    var progress: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.13))
                Capsule().fill(Color.white)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(.snappy(duration: 0.35), value: progress)
    }
}

struct CheckCircle: View {
    let on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(on ? Color.white : Color(white: 0.3))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

struct SyllabusView: View {
    @EnvironmentObject private var store: SyllabusStore
    private let newSubject = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Syllabus").font(.system(size: 28, weight: .bold))
                    Text(store.totalChapters == 0 ? "Add your subjects and chapters"
                         : "\(store.totalDone) of \(store.totalChapters) chapters done")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.label)
                }
                Spacer()
                Text(percent(store.overall))
                    .font(.system(size: 48, weight: .regular).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: store.overall)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            ProgressLine(progress: store.overall)
                .padding(.horizontal, 28)
                .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(store.subjects) { subject in
                        SubjectCard(subject: subject)
                    }
                    addSubjectRow
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.never)
        }
    }

    private var addSubjectRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Ink.label)
            TextField(store.subjects.isEmpty ? "Add your first subject, e.g. Physics" : "Add subject",
                      text: newSubject.projectedValue)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit {
                    withAnimation(.snappy) { store.addSubject(newSubject.wrappedValue) }
                    newSubject.wrappedValue = ""
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct SubjectCard: View {
    let subject: Subject
    @EnvironmentObject private var store: SyllabusStore

    private let newChapter = State(initialValue: "")
    private let showPaste = State(initialValue: false)
    private let pasteText = State(initialValue: "")
    private let renamingRevision = State<Int?>(initialValue: nil)
    private let revisionName = State(initialValue: "")
    private let confirmDelete = State(initialValue: false)

    private let col: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ProgressLine(progress: subject.progress, height: 2)
            if !subject.collapsed {
                table
                if !subject.revisionNames.isEmpty && !subject.chapters.isEmpty {
                    Text(subject.revisionNames.indices.map { "\(subject.revisionNames[$0]) \(percent(subject.revisionProgress($0)))" }
                        .joined(separator: "   ·   "))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.label)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.stroke, lineWidth: 1))
        .sheet(isPresented: showPaste.projectedValue) { pasteSheet }
        .alert("Rename column", isPresented: Binding(get: { renamingRevision.wrappedValue != nil },
                                                     set: { if !$0 { renamingRevision.wrappedValue = nil } })) {
            TextField("Name", text: revisionName.projectedValue)
            Button("Save") {
                if let i = renamingRevision.wrappedValue { store.renameRevision(subject.id, i, revisionName.wrappedValue) }
                renamingRevision.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { renamingRevision.wrappedValue = nil }
        }
        .confirmationDialog("Delete \(subject.name.isEmpty ? "this subject" : subject.name)?",
                            isPresented: confirmDelete.projectedValue, titleVisibility: .visible) {
            Button("Delete Subject", role: .destructive) { withAnimation(.snappy) { store.deleteSubject(subject.id) } }
        } message: {
            Text("Its chapters and ticks will be removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.snappy) { store.toggleCollapsed(subject.id) } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.label)
                    .rotationEffect(.degrees(subject.collapsed ? 0 : 90))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField("Subject", text: store.subjectName(subject.id))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))

            Text(percent(subject.progress))
                .font(.system(size: 17, weight: .regular).monospacedDigit())
                .foregroundStyle(subject.progress >= 1 ? Color.white : Color(white: 0.7))
                .contentTransition(.numericText())

            Menu {
                Button("Add Revision Column") { withAnimation(.snappy) { store.addRevision(subject.id) } }
                    .disabled(subject.revisionNames.count >= SyllabusStore.maxRevisions)
                Button("Paste Chapters…") { pasteText.wrappedValue = ""; showPaste.wrappedValue = true }
                Divider()
                Button("Delete Subject…", role: .destructive) { confirmDelete.wrappedValue = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.label)
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("CHAPTER").frame(maxWidth: .infinity, alignment: .leading)
                Text("DONE").frame(width: col)
                ForEach(subject.revisionNames.indices, id: \.self) { i in
                    Menu {
                        Button("Rename…") {
                            revisionName.wrappedValue = subject.revisionNames[i]
                            renamingRevision.wrappedValue = i
                        }
                        Button("Remove Column", role: .destructive) { withAnimation(.snappy) { store.removeRevision(subject.id, i) } }
                    } label: {
                        Text(shortName(subject.revisionNames[i], i))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: col)
                    .help(subject.revisionNames[i])
                }
                Button { withAnimation(.snappy) { store.addRevision(subject.id) } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Add a revision column")
                .disabled(subject.revisionNames.count >= SyllabusStore.maxRevisions)
                .frame(width: 34)
            }
            .font(.system(size: 10, weight: .semibold))
            .kerning(1.2)
            .foregroundStyle(Ink.label)
            .padding(.bottom, 6)

            ForEach(subject.chapters) { chapter in
                ChapterRow(subject: subject, chapter: chapter, col: col)
            }

            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.label)
                TextField("Add chapter", text: newChapter.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        withAnimation(.snappy) { store.addChapter(subject.id, newChapter.wrappedValue) }
                        newChapter.wrappedValue = ""
                    }
                Button("Paste list") { pasteText.wrappedValue = ""; showPaste.wrappedValue = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.label)
            }
            .padding(.top, 10)
        }
    }

    /// "Revision 1" → "REV 1" so columns stay narrow; custom names are shown as typed.
    private func shortName(_ name: String, _ i: Int) -> String {
        name.lowercased().hasPrefix("revision ") ? "REV \(name.dropFirst(9))" : name.uppercased()
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste chapters").font(.system(size: 17, weight: .semibold))
            Text("One chapter per line. They'll be added to \(subject.name.isEmpty ? "this subject" : subject.name).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextEditor(text: pasteText.projectedValue)
                .font(.system(size: 13))
                .frame(width: 380, height: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            HStack {
                Spacer()
                Button("Cancel") { showPaste.wrappedValue = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add Chapters") {
                    store.addChapters(subject.id, lines: pasteText.wrappedValue)
                    showPaste.wrappedValue = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .preferredColorScheme(.dark)
    }
}

struct ChapterRow: View {
    let subject: Subject
    let chapter: Chapter
    let col: CGFloat
    @EnvironmentObject private var store: SyllabusStore
    private let hovering = State(initialValue: false)

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.11)).frame(height: 1)
            HStack(spacing: 0) {
                TextField("Chapter", text: store.chapterName(subject.id, chapter.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(chapter.done ? Color(white: 0.6) : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CheckCircle(on: chapter.done) { withAnimation(.snappy) { store.toggleDone(subject.id, chapter.id) } }
                    .frame(width: col)
                ForEach(subject.revisionNames.indices, id: \.self) { i in
                    CheckCircle(on: chapter.revised(i)) { withAnimation(.snappy) { store.toggleRevision(subject.id, chapter.id, i) } }
                        .frame(width: col)
                }
                Button { withAnimation(.snappy) { store.deleteChapter(subject.id, chapter.id) } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.label)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .opacity(hovering.wrappedValue ? 1 : 0)
                .frame(width: 34)
                .help("Delete chapter")
            }
            .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering.wrappedValue = $0 }
        .contextMenu {
            Button("Delete Chapter", role: .destructive) { store.deleteChapter(subject.id, chapter.id) }
        }
    }
}
