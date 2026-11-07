import AppKit
import SwiftUI
import Combine

/// A small black pill beside the MacBook notch showing the running timer.
/// Hovering widens it into a mini control panel. Hidden when nothing is running.
@MainActor
final class NotchController {
    static let shared = NotchController()

    private var panel: NotchPanel?
    private let state = NotchState()
    private var cancellables: Set<AnyCancellable> = []
    private var hoverTimer: Timer?
    private var geometry = NotchGeometry.current()

    var enabled: Bool { UserDefaults.standard.object(forKey: "notch.enabled") as? Bool ?? true }

    private var anyActive: Bool {
        CountdownModel.shared.isActive || PomodoroModel.shared.isActive || StopwatchModel.shared.isRunning
    }

    func start() {
        Publishers.MergeMany(
            CountdownModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            PomodoroModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            StopwatchModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    func refresh() {
        if enabled && anyActive { show() } else { hide() }
    }

    private func show() {
        if panel == nil {
            let p = NotchPanel()
            let host = FirstMouseHostingView(rootView: NotchView(state: state))
            p.contentView = host
            panel = p
            relayout()
        }
        guard let panel else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startHoverTracking()
    }

    private func hide() {
        panel?.orderOut(nil)
        stopHoverTracking()
        state.expanded = false
    }

    private func relayout() {
        geometry = NotchGeometry.current()
        state.geometry = geometry
        panel?.setFrame(geometry.panelFrame, display: true)
    }

    // Polling the pointer 5×/s only while the pill is visible: simpler and more reliable than
    // event monitors over the menu bar, and negligible on battery.
    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in NotchController.shared.checkHover() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func checkHover() {
        let p = NSEvent.mouseLocation
        if !state.expanded, geometry.compactFrame.insetBy(dx: -6, dy: -6).contains(p) {
            setExpanded(true)
        } else if state.expanded, !geometry.expandedFrame.insetBy(dx: -14, dy: -14).contains(p) {
            setExpanded(false)
        }
    }

    private func setExpanded(_ on: Bool) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { state.expanded = on }
        panel?.ignoresMouseEvents = !on
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var geometry = NotchGeometry.current()
}

struct NotchGeometry {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var barHeight: CGFloat
    var centerX: CGFloat
    var topY: CGFloat

    static let side: CGFloat = 74          // width of each wing next to the notch
    static let expandedWidth: CGFloat = 360
    static let expandedHeight: CGFloat = 132

    var compactWidth: CGFloat { hasNotch ? notchWidth + 2 * Self.side : 150 }
    var compactHeight: CGFloat { hasNotch ? barHeight : 28 }
    var expandedWidth: CGFloat { max(Self.expandedWidth, compactWidth + 40) }

    var panelFrame: CGRect {
        CGRect(x: centerX - expandedWidth / 2, y: topY - Self.expandedHeight,
               width: expandedWidth, height: Self.expandedHeight)
    }
    var compactFrame: CGRect {
        CGRect(x: centerX - compactWidth / 2, y: topY - compactHeight, width: compactWidth, height: compactHeight)
    }
    var expandedFrame: CGRect { panelFrame }

    @MainActor
    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            let notchW = s.frame.width - left.width - right.width
            return NotchGeometry(hasNotch: true, notchWidth: max(0, notchW), barHeight: s.safeAreaInsets.top,
                                 centerX: s.frame.minX + left.width + notchW / 2, topY: s.frame.maxY)
        }
        let s = NSScreen.main ?? screens.first
        let frame = s?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let visibleTop = s?.visibleFrame.maxY ?? frame.maxY - 24
        return NotchGeometry(hasNotch: false, notchWidth: 0, barHeight: 0, centerX: frame.midX, topY: visibleTop - 6)
    }
}

final class NotchPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons respond to the first click even though the app isn't active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - View

struct NotchView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var countdown = CountdownModel.shared
    @ObservedObject private var pomodoro = PomodoroModel.shared
    @ObservedObject private var stopwatch = StopwatchModel.shared

    private enum Source { case pomodoro, countdown, stopwatch }

    private var source: Source? {
        if pomodoro.isActive { return .pomodoro }
        if countdown.isActive { return .countdown }
        if stopwatch.isRunning { return .stopwatch }
        return nil
    }

    private var isRunning: Bool {
        switch source {
        case .pomodoro: return pomodoro.isRunning
        case .countdown: return countdown.isRunning
        case .stopwatch: return stopwatch.isRunning
        case nil: return false
        }
    }

    private var tint: Color {
        switch source {
        case .pomodoro: return pomodoro.phase == .focus ? Color(red: 1, green: 0.42, blue: 0.3) : Color(red: 0.2, green: 0.83, blue: 0.6)
        default: return .white
        }
    }

    private var title: String {
        switch source {
        case .pomodoro: return pomodoro.phase.title
        case .countdown: return "Timer"
        case .stopwatch: return "Stopwatch"
        case nil: return ""
        }
    }

    private func timeText(_ date: Date) -> String {
        switch source {
        case .pomodoro: return TimeFormat.clock(pomodoro.remaining(at: date))
        case .countdown: return TimeFormat.clock(countdown.remaining(at: date))
        case .stopwatch: return TimeFormat.clock(stopwatch.elapsed(at: date).rounded(.down))
        case nil: return ""
        }
    }

    private func progress(_ date: Date) -> Double {
        switch source {
        case .pomodoro: return pomodoro.remaining(at: date) / max(1, pomodoro.phaseLength)
        case .countdown: return countdown.total > 0 ? countdown.remaining(at: date) / countdown.total : 0
        default: return 1
        }
    }

    var body: some View {
        let g = state.geometry
        let expanded = state.expanded
        let width = expanded ? g.expandedWidth : g.compactWidth
        let height = expanded ? NotchGeometry.expandedHeight : g.compactHeight
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: g.hasNotch ? 0 : (expanded ? 22 : 14),
            bottomLeadingRadius: expanded ? 22 : (g.hasNotch ? 10 : 14),
            bottomTrailingRadius: expanded ? 22 : (g.hasNotch ? 10 : 14),
            topTrailingRadius: g.hasNotch ? 0 : (expanded ? 22 : 14),
            style: .continuous)

        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                    .overlay(shape.strokeBorder(Color.white.opacity(g.hasNotch ? 0 : 0.12), lineWidth: 1))
                    .frame(width: width, height: height)

                VStack(spacing: 0) {
                    compactRow(ctx.date, g)
                        .frame(width: g.compactWidth, height: g.compactHeight)
                    if expanded {
                        expandedContent(ctx.date)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .frame(width: width, height: height, alignment: .top)
                .clipShape(shape)
            }
            .frame(width: g.expandedWidth, height: NotchGeometry.expandedHeight, alignment: .top)
        }
        .preferredColorScheme(.dark)
    }

    private func compactRow(_ date: Date, _ g: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.001, progress(date)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            .frame(width: g.hasNotch ? NotchGeometry.side : 40)

            if g.hasNotch { Spacer(minLength: g.notchWidth) } else { Spacer(minLength: 0) }

            Text(timeText(date))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isRunning ? Color.white : Color(white: 0.55))
                .lineLimit(1)
                .frame(width: g.hasNotch ? NotchGeometry.side : 100, alignment: g.hasNotch ? .center : .leading)
        }
    }

    private func expandedContent(_ date: Date) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(tint == .white ? Color(white: 0.55) : tint)
                Spacer()
                Text(timeText(date))
                    .font(.system(size: 30, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white)
            }
            HStack(spacing: 10) {
                mini(isRunning ? "pause.fill" : "play.fill", "Pause / Resume") { toggle() }
                switch source {
                case .countdown:
                    mini(nil, "Add 5 minutes", text: "+5") { countdown.add(300) }
                    mini("arrow.counterclockwise", "Reset") { countdown.reset() }
                case .pomodoro:
                    mini("forward.end.fill", "Skip") { pomodoro.skip() }
                    mini("arrow.counterclockwise", "Reset") { pomodoro.reset() }
                case .stopwatch:
                    mini("flag", "Lap") { stopwatch.lap() }
                case nil:
                    EmptyView()
                }
                Spacer()
                mini("arrow.up.forward.app", "Open Solace") { WindowOpener.open(tab: .time) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func mini(_ icon: String?, _ help: String, text: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                else { Text(text ?? "").font(.system(size: 11, weight: .semibold).monospacedDigit()) }
            }
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.white.opacity(0.1)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle() {
        switch source {
        case .pomodoro: pomodoro.toggle()
        case .countdown: countdown.toggle()
        case .stopwatch: stopwatch.toggle()
        case nil: break
        }
    }
}
