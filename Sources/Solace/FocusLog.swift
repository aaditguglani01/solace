import Foundation

/// One block of focused time from the Timer, Stopwatch or a Pomodoro focus phase.
struct FocusSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Date
    var seconds: Double
    var subjectID: UUID?
    var kind: String
}

@MainActor
final class FocusLog: ObservableObject {
    static let shared = FocusLog()

    /// Sessions shorter than this are ignored (accidental starts).
    static let minimumSeconds: Double = 30

    @Published private(set) var sessions: [FocusSession]

    /// Optional: what the user is studying right now (a Syllabus subject). nil = general.
    @Published var currentSubjectID: UUID? {
        didSet { UserDefaults.standard.set(currentSubjectID?.uuidString, forKey: "focus.subject") }
    }

    init() {
        sessions = Storage.load([FocusSession].self, "focus.json") ?? []
        currentSubjectID = UserDefaults.standard.string(forKey: "focus.subject").flatMap { UUID(uuidString: $0) }
    }

    func log(seconds: Double, kind: String, endingAt end: Date = Date()) {
        guard seconds >= Self.minimumSeconds else { return }
        let subject = currentSubjectID.flatMap { id in SyllabusStore.shared.subjects.contains { $0.id == id } ? id : nil }
        sessions.append(FocusSession(start: end.addingTimeInterval(-seconds), seconds: seconds, subjectID: subject, kind: kind))
        Storage.save(sessions, "focus.json")
    }

    func replaceAll(_ new: [FocusSession]) {
        sessions = new
        Storage.save(sessions, "focus.json")
    }

    // MARK: Stats

    func total(in interval: DateInterval?) -> Double {
        guard let interval else { return sessions.reduce(0) { $0 + $1.seconds } }
        return sessions.filter { interval.contains($0.start) }.reduce(0) { $0 + $1.seconds }
    }

    func today(_ now: Date = Date()) -> Double {
        total(in: Calendar.current.dateInterval(of: .day, for: now))
    }

    func thisWeek(_ now: Date = Date()) -> Double {
        total(in: Calendar.current.dateInterval(of: .weekOfYear, for: now))
    }

    var allTime: Double { total(in: nil) }

    /// Seconds per day for the last `days` days, oldest first.
    func perDay(last days: Int, now: Date = Date()) -> [(day: Date, seconds: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> (day: Date, seconds: Double)? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let interval = cal.dateInterval(of: .day, for: day) else { return nil }
            return (day, total(in: interval))
        }
    }

    /// Consecutive days (ending today, or yesterday if nothing yet today) with at least 1 minute of focus.
    func streak(now: Date = Date()) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: now)
        if today(now) < 60, let y = cal.date(byAdding: .day, value: -1, to: day) { day = y }
        var count = 0
        while let interval = cal.dateInterval(of: .day, for: day), total(in: interval) >= 60 {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// This week's time per subject (only sessions tagged with a subject).
    func weekBySubject(now: Date = Date()) -> [(name: String, seconds: Double)] {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else { return [] }
        var totals: [UUID: Double] = [:]
        for s in sessions where week.contains(s.start) {
            if let id = s.subjectID { totals[id, default: 0] += s.seconds }
        }
        let subjects = SyllabusStore.shared.subjects
        var rows: [(name: String, seconds: Double)] = []
        for (id, secs) in totals {
            if let subject = subjects.first(where: { $0.id == id }) {
                rows.append((name: subject.name.isEmpty ? "Untitled" : subject.name, seconds: secs))
            }
        }
        return rows.sorted { $0.seconds > $1.seconds }
    }

    static func hm(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        let h = m / 60, mm = m % 60
        if h > 0 { return mm > 0 ? "\(h)h \(mm)m" : "\(h)h" }
        return "\(mm)m"
    }
}
