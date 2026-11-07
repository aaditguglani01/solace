import SwiftUI

enum TimeMode: String, CaseIterable, Identifiable {
    case timer = "Timer", stopwatch = "Stopwatch", pomodoro = "Pomodoro", exams = "Exams", stats = "Stats", clock = "Clock"
    var id: Self { self }
}

struct TimeView: View {
    @AppStorage("timeMode") private var mode: TimeMode = .timer

    var body: some View {
        VStack(spacing: 0) {
            TextSwitcher(items: TimeMode.allCases, selection: $mode) { $0.rawValue }
                .padding(.top, 8)

            Group {
                switch mode {
                case .timer: CountdownView()
                case .stopwatch: StopwatchView()
                case .pomodoro: PomodoroView()
                case .exams: ExamsView()
                case .stats: StatsView()
                case .clock: ClockView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Shared

struct ProgressRing: View {
    var progress: Double
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private let bigDigits = Font.system(size: 64, weight: .thin).monospacedDigit()

// MARK: - Timer

enum TimeUnit: Hashable { case hours, minutes, seconds }

struct CountdownView: View {
    @EnvironmentObject private var model: CountdownModel
    @FocusState private var focus: TimeUnit?

    private let presets: [(String, Int)] = [("15", 15 * 60), ("25", 25 * 60), ("45", 45 * 60), ("60", 3600), ("90", 5400)]

    var body: some View {
        GeometryReader { geo in
            Group {
                if model.isActive { running(width: geo.size.width) } else { setter(width: geo.size.width) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Set duration

    private func setter(width: CGFloat) -> some View {
        let size = min(150, max(54, width / 6.2))
        return VStack(spacing: 0) {
            Spacer(minLength: 8)
            StudyingPicker()
                .frame(height: 22)

            HStack(alignment: .lastTextBaseline, spacing: size * 0.18) {
                DurationField(value: binding(.hours), unit: .hours, max: 99, suffix: "h", size: size, focus: $focus, onSubmit: startIfReady)
                DurationField(value: binding(.minutes), unit: .minutes, max: 59, suffix: "m", size: size, focus: $focus, onSubmit: startIfReady)
                DurationField(value: binding(.seconds), unit: .seconds, max: 59, suffix: "s", size: size, focus: $focus, onSubmit: startIfReady)
            }
            .padding(.top, size * 0.2)

            Text("Click a number to type · ↑ ↓ to adjust · Return to start")
                .font(.system(size: 11))
                .foregroundStyle(Ink.dim)
                .padding(.top, 10)

            HStack(spacing: 0) {
                ForEach(Array(presets.enumerated()), id: \.offset) { i, p in
                    if i > 0 {
                        Text("·").foregroundStyle(Ink.dim).padding(.horizontal, 10)
                    }
                    let selected = Int(model.duration) == p.1
                    Button(p.0) {
                        focus = nil
                        model.duration = TimeInterval(p.1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.white : Ink.label)
                }
                Text("min").foregroundStyle(Ink.dim).padding(.leading, 8)
            }
            .font(.system(size: 14).monospacedDigit())
            .padding(.top, 30)

            CircleButton(icon: "play.fill", primary: true, diameter: 64, help: "Start") { startIfReady() }
                .opacity(model.duration > 0 ? 1 : 0.35)
                .disabled(model.duration <= 0)
                .padding(.top, 34)
            Spacer(minLength: 8)
        }
    }

    private func startIfReady() {
        guard model.duration > 0 else { return }
        focus = nil
        model.start()
    }

    private func binding(_ unit: TimeUnit) -> Binding<Int> {
        Binding(
            get: {
                let t = Int(model.duration)
                switch unit {
                case .hours: return t / 3600
                case .minutes: return (t % 3600) / 60
                case .seconds: return t % 60
                }
            },
            set: { v in
                let t = Int(model.duration)
                var h = t / 3600, m = (t % 3600) / 60, s = t % 60
                switch unit {
                case .hours: h = v
                case .minutes: m = v
                case .seconds: s = v
                }
                model.duration = TimeInterval(h * 3600 + m * 60 + s)
            }
        )
    }

    // MARK: Running

    private func running(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !model.isRunning)) { ctx in
            let rem = model.remaining(at: ctx.date)
            let parts = TimeFormat.parts(rem, forceHours: model.total >= 3600)
            let size = min(190, max(60, width / (parts.count == 3 ? 4.7 : 3.5)))
            let progress = model.total > 0 ? rem / model.total : 0
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                StudyingPicker()
                    .frame(height: 22)
                    .padding(.bottom, 8)
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                        if i > 0 { ColonDots(size: size) }
                        Text(p)
                            .font(.system(size: size, weight: .regular).monospacedDigit())
                            .foregroundStyle(model.isRunning ? Color.white : Color(white: 0.55))
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
                .lineLimit(1)
                .animation(.snappy(duration: 0.25), value: parts)

                // Slim line that drains as time runs out.
                ProgressLine(progress: progress, height: 2)
                    .frame(width: min(width * 0.62, 560))
                    .padding(.top, 18)

                Text(model.endDate.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.label)
                    .padding(.top, 14)

                HStack(spacing: 22) {
                    CircleButton(icon: "arrow.counterclockwise", help: "Reset") { model.reset() }
                    CircleButton(icon: model.isRunning ? "pause.fill" : "play.fill", primary: true, diameter: 64,
                                 help: model.isRunning ? "Pause" : "Resume") { model.toggle() }
                    CircleButton(text: "+5", help: "Add 5 minutes") { model.add(300) }
                }
                .padding(.top, 34)
                Spacer(minLength: 8)
            }
        }
    }
}

/// One big editable number with a small unit after it (click and type, or use ↑ ↓). Tab moves to the next.
struct DurationField: View {
    @Binding var value: Int
    let unit: TimeUnit
    let max: Int
    let suffix: String
    let size: CGFloat
    var focus: FocusState<TimeUnit?>.Binding
    var onSubmit: () -> Void

    private let text = State(initialValue: "")

    private var isFocused: Bool { focus.wrappedValue == unit }
    private var lit: Bool { isFocused || value > 0 }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.04) {
            TextField("\(value)", text: text.projectedValue)
                .textFieldStyle(.plain)
                .font(.system(size: size, weight: .regular).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .foregroundStyle(lit ? Color.white : Ink.dim)
                .focused(focus, equals: unit)
                .frame(width: size * 1.25)
                .onAppear { text.wrappedValue = "\(value)" }
                .onChange(of: value) { _, v in
                    if Int(text.wrappedValue) != v { text.wrappedValue = "\(v)" }
                }
                .onChange(of: text.wrappedValue) { _, new in
                    let digits = String(new.filter(\.isNumber).suffix(2))
                    if digits != new { text.wrappedValue = digits; return }
                    guard !digits.isEmpty else { return }   // empty while typing: keep the old value
                    let v = Swift.min(Int(digits) ?? 0, max)
                    if v != value { value = v }
                }
                .onChange(of: isFocused) { _, f in
                    text.wrappedValue = f ? "" : "\(value)"
                }
                .onKeyPress(.upArrow) { step(1); return .handled }
                .onKeyPress(.downArrow) { step(-1); return .handled }
                .onSubmit(onSubmit)

            Text(suffix)
                .font(.system(size: size * 0.3, weight: .regular))
                .foregroundStyle(isFocused ? Color.white : Ink.label)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = unit }
    }

    private func step(_ d: Int) {
        var v = value + d
        if v > max { v = 0 }
        if v < 0 { v = max }
        value = v
        text.wrappedValue = "\(v)"
    }
}

// MARK: - Stopwatch

struct StopwatchView: View {
    @EnvironmentObject private var model: StopwatchModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isRunning)) { ctx in
                Text(TimeFormat.precise(model.elapsed(at: ctx.date)))
                    .font(.system(size: 84, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
            }
            .frame(height: 110)

            StudyingPicker().frame(height: 22)

            HStack(spacing: 22) {
                if model.isRunning {
                    CircleButton(icon: "flag", help: "Lap") { model.lap() }
                } else {
                    CircleButton(icon: "arrow.counterclockwise", help: "Reset") { model.reset() }
                        .opacity(model.hasTime ? 1 : 0.35)
                        .disabled(!model.hasTime)
                }
                CircleButton(icon: model.isRunning ? "pause.fill" : "play.fill", primary: true, diameter: 64,
                             help: model.isRunning ? "Stop" : "Start") { model.toggle() }
            }

            lapList
                .frame(maxWidth: 460, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var lapList: some View {
        let completed = model.laps
        let best = completed.count > 1 ? completed.min() : nil
        let worst = completed.count > 1 ? completed.max() : nil
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.hasTime && !completed.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isRunning)) { ctx in
                        lapRow(n: completed.count + 1,
                               time: model.elapsed(at: ctx.date) - completed.reduce(0, +),
                               color: .white)
                    }
                }
                ForEach(Array(completed.enumerated()), id: \.offset) { i, lap in
                    lapRow(n: completed.count - i, time: lap,
                           color: lap == best ? .green : (lap == worst ? .red : .white))
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func lapRow(n: Int, time: TimeInterval, color: Color) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.12)).frame(height: 1)
            HStack {
                Text("Lap \(n)")
                Spacer()
                Text(TimeFormat.precise(time)).monospacedDigit()
            }
            .font(.system(size: 14))
            .foregroundStyle(color)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Pomodoro

struct PomodoroView: View {
    @EnvironmentObject private var model: PomodoroModel
    private let showSettings = State(initialValue: false)

    private var tint: Color { model.phase == .focus ? Color(red: 1, green: 0.42, blue: 0.3) : Color(red: 0.2, green: 0.83, blue: 0.6) }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            StudyingPicker().frame(height: 22)
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !model.isRunning)) { ctx in
                let rem = model.remaining(at: ctx.date)
                ZStack {
                    ProgressRing(progress: rem / max(1, model.phaseLength), tint: tint)
                    VStack(spacing: 8) {
                        Text(model.phase.title.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .kerning(2)
                            .foregroundStyle(tint)
                        Text(TimeFormat.clock(rem))
                            .font(.system(size: 64, weight: .regular).monospacedDigit())
                            .foregroundStyle(.white)
                        HStack(spacing: 7) {
                            ForEach(0..<max(1, model.rounds), id: \.self) { i in
                                Circle()
                                    .fill(i < model.roundProgress ? tint : Color.white.opacity(0.15))
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                }
                .frame(width: 270, height: 270)
                .animation(.easeInOut(duration: 0.4), value: model.phase)
            }
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                CircleButton(icon: "arrow.counterclockwise", help: "Reset") { model.reset() }
                CircleButton(icon: model.isRunning ? "pause.fill" : "play.fill", primary: true, diameter: 64,
                             help: model.isRunning ? "Pause" : "Start") { model.toggle() }
                CircleButton(icon: "forward.end.fill", help: "Skip to next phase") { model.skip() }
                CircleButton(icon: "slider.horizontal.3", help: "Pomodoro settings") { showSettings.wrappedValue.toggle() }
                    .popover(isPresented: showSettings.projectedValue, arrowEdge: .bottom) {
                        PomodoroSettings().environmentObject(model)
                    }
            }
        }
    }
}

struct PomodoroSettings: View {
    @EnvironmentObject private var model: PomodoroModel

    var body: some View {
        Form {
            Stepper("Focus  \(model.focusMinutes) min", value: $model.focusMinutes, in: 1...120)
            Stepper("Short break  \(model.shortMinutes) min", value: $model.shortMinutes, in: 1...60)
            Stepper("Long break  \(model.longMinutes) min", value: $model.longMinutes, in: 1...90)
            Stepper("Long break every  \(model.rounds)", value: $model.rounds, in: 2...8)
            Toggle("Start next phase automatically", isOn: $model.autoStart)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Clock

struct ClockView: View {
    @AppStorage("clock.seconds") private var showSeconds = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 10) {
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ctx.date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 110, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    if showSeconds {
                        Text(ctx.date.formatted(.dateTime.second(.twoDigits)))
                            .font(.system(size: 32, weight: .light).monospacedDigit())
                            .foregroundStyle(Ink.label)
                    }
                }
                Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 17))
                    .foregroundStyle(Ink.label)
                Spacer()
                Toggle("Show seconds", isOn: $showSeconds)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .foregroundStyle(Ink.label)
                    .font(.system(size: 12))
            }
        }
    }
}
