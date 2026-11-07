import SwiftUI

// MARK: - Exams

struct Exam: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
}

@MainActor
final class ExamStore: ObservableObject {
    static let shared = ExamStore()

    @Published var exams: [Exam] {
        didSet { Storage.save(exams, "exams.json") }
    }

    init() {
        exams = Storage.load([Exam].self, "exams.json") ?? []
    }

    func add(name: String, date: Date) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        exams.append(Exam(name: t, date: Calendar.current.startOfDay(for: date)))
    }

    func delete(_ id: UUID) { exams.removeAll { $0.id == id } }

    /// Today and later, soonest first.
    func upcoming(_ now: Date) -> [Exam] {
        let today = Calendar.current.startOfDay(for: now)
        return exams.filter { $0.date >= today }.sorted { $0.date < $1.date }
    }

    static func daysUntil(_ date: Date, from now: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
    }
}

struct ExamsView: View {
    @EnvironmentObject private var store: ExamStore
    private let name = State(initialValue: "")
    private let date = State(initialValue: Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date())

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let upcoming = store.upcoming(ctx.date)
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                if let next = upcoming.first {
                    let days = ExamStore.daysUntil(next.date, from: ctx.date)
                    Text(days == 0 ? "Today" : "\(days)")
                        .font(.system(size: 140, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .contentTransition(.numericText(countsDown: true))
                    Text(days == 0 ? next.name : "\(days == 1 ? "day" : "days") until \(next.name)")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(white: 0.75))
                    Text(next.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.label)
                        .padding(.top, 6)
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Ink.label)
                    Text("No exams yet")
                        .font(.system(size: 20, weight: .medium))
                        .padding(.top, 10)
                    Text("Add one below to start a countdown.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.label)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)

                if upcoming.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(upcoming.dropFirst()) { exam in
                            examRow(exam, now: ctx.date)
                        }
                    }
                    .frame(maxWidth: 460)
                    .padding(.bottom, 14)
                }
                if let next = upcoming.first, upcoming.count == 1 {
                    Button("Remove \(next.name)") { withAnimation(.snappy) { store.delete(next.id) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.label)
                        .padding(.bottom, 12)
                }
                addRow
            }
        }
    }

    private func examRow(_ exam: Exam, now: Date) -> some View {
        let days = ExamStore.daysUntil(exam.date, from: now)
        return VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.11)).frame(height: 1)
            HStack {
                Text(exam.name).font(.system(size: 14))
                Spacer()
                Text(exam.date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.label)
                Text("\(days)d")
                    .font(.system(size: 14).monospacedDigit())
                    .frame(width: 54, alignment: .trailing)
                Button { withAnimation(.snappy) { store.delete(exam.id) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.label)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .help("Remove")
            }
            .padding(.vertical, 9)
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("Exam name, e.g. Boards", text: name.projectedValue)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(add)
            DatePicker("", selection: date.projectedValue, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .opacity(name.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .help("Add exam")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(Capsule().fill(Ink.surface))
        .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
    }

    private func add() {
        withAnimation(.snappy) { store.add(name: name.wrappedValue, date: date.wrappedValue) }
        name.wrappedValue = ""
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject private var log: FocusLog

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let now = ctx.date
            let days = log.perDay(last: 7, now: now)
            let peak = max(days.map(\.seconds).max() ?? 0, 1)
            let bySubject = log.weekBySubject(now: now)
            let streak = log.streak(now: now)

            ScrollView {
                VStack(spacing: 28) {
                    HStack(spacing: 0) {
                        statBlock("Today", log.today(now))
                        statBlock("This week", log.thisWeek(now))
                        statBlock("All time", log.allTime)
                    }
                    .padding(.top, 18)

                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(days, id: \.day) { d in
                            let isToday = Calendar.current.isDate(d.day, inSameDayAs: now)
                            VStack(spacing: 6) {
                                Text(d.seconds >= 60 ? FocusLog.hm(d.seconds) : "")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Ink.label)
                                    .lineLimit(1)
                                    .fixedSize()
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isToday ? Color.white : Color(white: 0.28))
                                    .frame(width: 26, height: max(3, 120 * d.seconds / peak))
                                Text(d.day.formatted(.dateTime.weekday(.narrow)))
                                    .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                                    .foregroundStyle(isToday ? Color.white : Ink.label)
                            }
                        }
                    }
                    .frame(height: 170, alignment: .bottom)
                    .animation(.snappy, value: days.map(\.seconds))

                    HStack(spacing: 8) {
                        Image(systemName: "flame")
                        Text(streak == 1 ? "1-day streak" : "\(streak)-day streak")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(streak > 0 ? Color.white : Ink.label)

                    if !bySubject.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("THIS WEEK BY SUBJECT")
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(1.2)
                                .foregroundStyle(Ink.label)
                            let top = bySubject.first?.seconds ?? 1
                            ForEach(bySubject, id: \.name) { row in
                                HStack(spacing: 12) {
                                    Text(row.name).font(.system(size: 13)).frame(width: 120, alignment: .leading).lineLimit(1)
                                    ProgressLine(progress: row.seconds / max(top, 1), height: 4)
                                    Text(FocusLog.hm(row.seconds))
                                        .font(.system(size: 13).monospacedDigit())
                                        .frame(width: 64, alignment: .trailing)
                                }
                            }
                        }
                        .frame(maxWidth: 460)
                    }

                    Text("Counts time from the Timer, Stopwatch and Pomodoro focus sessions (30 seconds or longer).")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
    }

    private func statBlock(_ title: String, _ seconds: Double) -> some View {
        VStack(spacing: 6) {
            Text(FocusLog.hm(seconds))
                .font(.system(size: 40, weight: .regular).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .kerning(2)
                .foregroundStyle(Ink.label)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small menu to tag focus time with a Syllabus subject. Hidden if there are no subjects.
struct StudyingPicker: View {
    @EnvironmentObject private var log: FocusLog
    @EnvironmentObject private var syllabus: SyllabusStore

    var body: some View {
        if !syllabus.subjects.isEmpty {
            let current = syllabus.subjects.first { $0.id == log.currentSubjectID }
            Menu {
                Button("General (no subject)") { log.currentSubjectID = nil }
                Divider()
                ForEach(syllabus.subjects) { s in
                    Button(s.name.isEmpty ? "Untitled" : s.name) { log.currentSubjectID = s.id }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Studying")
                        .foregroundStyle(Ink.label)
                    Text(current.map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "General")
                        .foregroundStyle(Color.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.label)
                }
                .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
