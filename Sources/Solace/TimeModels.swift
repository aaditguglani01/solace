import Foundation
import AppKit
import UserNotifications

// All timing is based on wall-clock end dates, not on counting ticks:
// accurate, and nothing runs in the background except one scheduled wake-up.

@MainActor
final class Alerts {
    static let shared = Alerts()

    func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func ring(title: String, body: String) {
        NSSound(named: "Glass")?.play()
        AmbientController.shared.flash()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // the app already plays a sound
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

/// Fires a closure once at a given date with minimal wake-ups.
@MainActor
final class OneShot {
    private var timer: Timer?

    func schedule(at date: Date, _ action: @escaping @MainActor () -> Void) {
        cancel()
        let t = Timer(fire: date, interval: 0, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Countdown timer

@MainActor
final class CountdownModel: ObservableObject {
    static let shared = CountdownModel()

    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    @Published var duration: TimeInterval {
        didSet { UserDefaults.standard.set(duration, forKey: "timer.duration") }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var total: TimeInterval = 0

    private let wake = OneShot()
    private var segmentStart: Date?

    init() {
        let saved = UserDefaults.standard.double(forKey: "timer.duration")
        duration = saved > 0 ? saved : 25 * 60
    }

    var isRunning: Bool { if case .running = state { return true }; return false }
    var isActive: Bool { state != .idle }

    var endDate: Date? { if case .running(let end) = state { return end }; return nil }

    func remaining(at date: Date) -> TimeInterval {
        switch state {
        case .idle: return duration
        case .running(let end): return max(0, end.timeIntervalSince(date))
        case .paused(let r): return r
        }
    }

    func start() {
        let rem: TimeInterval
        if case .paused(let r) = state { rem = r } else { rem = duration; total = duration }
        guard rem > 0 else { return }
        let end = Date().addingTimeInterval(rem)
        state = .running(end: end)
        segmentStart = Date()
        wake.schedule(at: end) { [weak self] in self?.finish() }
    }

    func pause() {
        guard case .running(let end) = state else { return }
        state = .paused(remaining: max(0, end.timeIntervalSinceNow))
        wake.cancel()
        closeSegment()
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    func reset() {
        closeSegment()
        state = .idle
        wake.cancel()
    }

    /// Adds time to a running or paused timer.
    func add(_ seconds: TimeInterval) {
        switch state {
        case .idle:
            duration += seconds
        case .running(let end):
            let newEnd = end.addingTimeInterval(seconds)
            state = .running(end: newEnd)
            total += seconds
            wake.schedule(at: newEnd) { [weak self] in self?.finish() }
        case .paused(let r):
            state = .paused(remaining: r + seconds)
            total += seconds
        }
    }

    private func closeSegment() {
        if let s = segmentStart { FocusLog.shared.log(seconds: Date().timeIntervalSince(s), kind: "timer") }
        segmentStart = nil
    }

    private func finish() {
        closeSegment()
        state = .idle
        Alerts.shared.ring(title: "Time's up", body: "Your \(TimeFormat.clock(total)) timer has finished.")
    }
}

// MARK: - Stopwatch

@MainActor
final class StopwatchModel: ObservableObject {
    static let shared = StopwatchModel()

    @Published private(set) var startDate: Date?
    @Published private(set) var accumulated: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = [] // newest first, each is a lap duration

    var isRunning: Bool { startDate != nil }
    var hasTime: Bool { accumulated > 0 || startDate != nil }

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (startDate.map { date.timeIntervalSince($0) } ?? 0)
    }

    func start() { if startDate == nil { startDate = Date() } }

    func stop() {
        guard let s = startDate else { return }
        let segment = Date().timeIntervalSince(s)
        accumulated += segment
        startDate = nil
        FocusLog.shared.log(seconds: segment, kind: "stopwatch")
    }

    func toggle() { if isRunning { stop() } else { start() } }

    func lap() {
        let now = elapsed(at: Date())
        laps.insert(now - laps.reduce(0, +), at: 0)
    }

    func reset() {
        if isRunning { stop() }
        accumulated = 0
        laps = []
    }
}

// MARK: - Pomodoro

@MainActor
final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()

    enum Phase: String {
        case focus, shortBreak, longBreak
        var title: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Short Break"
            case .longBreak: return "Long Break"
            }
        }
    }

    private let d = UserDefaults.standard

    @Published var focusMinutes: Int { didSet { d.set(focusMinutes, forKey: "pomo.focus") } }
    @Published var shortMinutes: Int { didSet { d.set(shortMinutes, forKey: "pomo.short") } }
    @Published var longMinutes: Int { didSet { d.set(longMinutes, forKey: "pomo.long") } }
    @Published var rounds: Int { didSet { d.set(rounds, forKey: "pomo.rounds") } }
    @Published var autoStart: Bool { didSet { d.set(autoStart, forKey: "pomo.auto") } }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var completedFocus = 0
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?

    private let wake = OneShot()
    private var segmentStart: Date?

    init() {
        func int(_ k: String, _ def: Int) -> Int { let v = UserDefaults.standard.integer(forKey: k); return v > 0 ? v : def }
        focusMinutes = int("pomo.focus", 25)
        shortMinutes = int("pomo.short", 5)
        longMinutes = int("pomo.long", 15)
        rounds = int("pomo.rounds", 4)
        autoStart = UserDefaults.standard.object(forKey: "pomo.auto") as? Bool ?? true
    }

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || pausedRemaining != nil }

    var phaseLength: TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortMinutes * 60)
        case .longBreak: return TimeInterval(longMinutes * 60)
        }
    }

    /// Focus sessions finished in the current set (0..<rounds).
    var roundProgress: Int { completedFocus % max(1, rounds) }

    func remaining(at date: Date) -> TimeInterval {
        if let end = endDate { return max(0, end.timeIntervalSince(date)) }
        return pausedRemaining ?? phaseLength
    }

    func start() {
        let rem = pausedRemaining ?? phaseLength
        let end = Date().addingTimeInterval(rem)
        endDate = end
        pausedRemaining = nil
        if phase == .focus { segmentStart = Date() }
        wake.schedule(at: end) { [weak self] in self?.phaseFinished() }
    }

    func pause() {
        guard let end = endDate else { return }
        pausedRemaining = max(0, end.timeIntervalSinceNow)
        endDate = nil
        wake.cancel()
        closeSegment()
    }

    func toggle() { if isRunning { pause() } else { start() } }

    func reset() {
        closeSegment()
        wake.cancel()
        endDate = nil
        pausedRemaining = nil
        phase = .focus
        completedFocus = 0
    }

    func skip() { advance(notify: false) }

    private func phaseFinished() { advance(notify: true) }

    private func closeSegment() {
        if let s = segmentStart { FocusLog.shared.log(seconds: Date().timeIntervalSince(s), kind: "pomodoro") }
        segmentStart = nil
    }

    private func advance(notify: Bool) {
        let wasRunning = isRunning || notify
        closeSegment()
        wake.cancel()
        endDate = nil
        pausedRemaining = nil

        let finished = phase
        if phase == .focus {
            completedFocus += 1
            phase = completedFocus % max(1, rounds) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }

        if notify {
            let body = finished == .focus ? "Nice work. Time for a \(phase.title.lowercased())." : "Break's over. Back to focus."
            Alerts.shared.ring(title: "\(finished.title) complete", body: body)
        }
        if autoStart && wasRunning { start() }
    }
}
