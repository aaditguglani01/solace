import AppKit
import SwiftUI
import IOKit.ps
import Combine

enum AmbientMode: String, CaseIterable, Identifiable {
    case music, color
    var id: Self { self }
    var title: String { self == .music ? "Music" : "Color" }
}

enum AudioStatus: Equatable {
    case idle, listening, noSignal, failed
}

struct ColorPreset: Identifiable {
    let name: String
    let hex: [String]
    var id: String { name }
    var colors: [Color] { hex.map { Color(nsColor: NSColor(hex: $0)) } }

    static let all: [ColorPreset] = [
        ColorPreset(name: "Aurora", hex: ["2DD4BF", "3B82F6", "A855F7"]),
        ColorPreset(name: "Sunset", hex: ["FF6B6B", "FFA94D", "F06595"]),
        ColorPreset(name: "Ocean", hex: ["00C2FF", "0066FF", "00E5A0"]),
        ColorPreset(name: "Neon", hex: ["FF2BD6", "7C3AED", "22D3EE"]),
        ColorPreset(name: "Ember", hex: ["FF3B30", "FF9500", "FFCC00"]),
        ColorPreset(name: "Soft White", hex: ["FFF4E0", "FFE2B8", "FFFFFF"]),
    ]
}

/// Owns the glow windows and decides, as cheaply as possible, what they should be doing.
@MainActor
final class AmbientController: NSObject, ObservableObject {
    static let shared = AmbientController()
    private let d = UserDefaults.standard

    // MARK: Settings (persisted)

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "amb.enabled"); update() } }
    @Published var mode: AmbientMode { didSet { d.set(mode.rawValue, forKey: "amb.mode"); update() } }
    @Published var customHex: [String] { didSet { d.set(customHex, forKey: "amb.colors"); update() } }
    @Published var intensity: Double { didSet { d.set(intensity, forKey: "amb.intensity"); update() } }
    @Published var thickness: Double { didSet { d.set(thickness, forKey: "amb.thickness"); update() } }
    @Published var speed: Double { didSet { d.set(speed, forKey: "amb.speed"); update() } }
    @Published var reactToAudio: Bool { didSet { d.set(reactToAudio, forKey: "amb.react"); noSignalForTrack = false; update() } }
    @Published var hideWhenPaused: Bool { didSet { d.set(hideWhenPaused, forKey: "amb.hidePaused"); update() } }
    /// While a Pomodoro is running, glow warm for focus and green for breaks.
    @Published var followPomodoro: Bool { didSet { d.set(followPomodoro, forKey: "amb.followPomodoro"); appliedColors = []; update() } }
    @Published var pauseOnBattery: Bool { didSet { d.set(pauseOnBattery, forKey: "amb.pauseBattery"); update() } }

    // MARK: State (for the UI)

    @Published private(set) var audioStatus: AudioStatus = .idle
    @Published private(set) var isShowing = false
    @Published private(set) var note: String?
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var onBattery = false

    let music = MusicMonitor()

    private var windows: [GlowWindow] = []
    private let tap = AudioLevelTap()
    private var link: CADisplayLink?
    private var screensAsleep = false
    private var started = false
    private var noSignalForTrack = false
    private var appliedColors: [NSColor] = []
    private var tokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var flashing = false

    // Audio envelope
    private var env: Float = 0
    private var peak: Float = 0.05
    private var floorLevel: Float = 0
    private var silentFrames = 0

    override init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "amb.enabled") as? Bool ?? false
        mode = AmbientMode(rawValue: d.string(forKey: "amb.mode") ?? "") ?? .music
        customHex = d.stringArray(forKey: "amb.colors") ?? ColorPreset.all[0].hex
        intensity = d.object(forKey: "amb.intensity") as? Double ?? 0.8
        thickness = d.object(forKey: "amb.thickness") as? Double ?? 70
        speed = d.object(forKey: "amb.speed") as? Double ?? 1
        reactToAudio = d.object(forKey: "amb.react") as? Bool ?? true
        hideWhenPaused = d.object(forKey: "amb.hidePaused") as? Bool ?? false
        followPomodoro = d.object(forKey: "amb.followPomodoro") as? Bool ?? true
        pauseOnBattery = d.object(forKey: "amb.pauseBattery") as? Bool ?? false
        super.init()
    }

    static let focusColors = ["FF6A3D", "FF9248", "FF4F5E"].map { NSColor(hex: $0) }
    static let breakColors = ["34D399", "2DD4BF", "7DDB7A"].map { NSColor(hex: $0) }

    /// True while the glow is showing Pomodoro colours instead of music/colour mode.
    var pomodoroOverride: Bool { followPomodoro && PomodoroModel.shared.isActive }

    var palette: [NSColor] {
        if pomodoroOverride {
            return PomodoroModel.shared.phase == .focus ? Self.focusColors : Self.breakColors
        }
        return basePalette
    }

    private var basePalette: [NSColor] {
        switch mode {
        case .music: return music.palette ?? ColorPreset.all[0].hex.map { NSColor(hex: $0) }
        case .color: return customHex.map { NSColor(hex: $0) }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        music.onChange = { [weak self] trackChanged in
            guard let self else { return }
            if trackChanged { self.noSignalForTrack = false }
            self.update()
            self.objectWillChange.send()
        }

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AmbientController) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }

        observe(nc, NSApplication.didChangeScreenParametersNotification) { $0.rebuildWindows(); $0.update() }
        observe(nc, .NSProcessInfoPowerStateDidChange) {
            $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.update()
        }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.update() }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.update() }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.screensAsleep = true; $0.update() }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.screensAsleep = false; $0.update() }
        observe(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.screensAsleep = true; $0.update() }
        observe(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.screensAsleep = false; $0.update() }

        // Power source changes (plugged in / on battery) — event driven, no polling.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in AmbientController.shared.powerSourceChanged() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        onBattery = Self.readOnBattery()

        PomodoroModel.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        update()
    }

    /// Briefly lights up the screen edges (used when a timer ends), even if the glow is off.
    func flash() {
        guard started, !screensAsleep, d.object(forKey: "flash.enabled") as? Bool ?? true else { return }
        flashing = true
        stopAudio()
        ensureWindows()
        for w in windows {
            w.glow.configure(thickness: CGFloat(thickness), speed: speed, intensity: Float(max(intensity, 0.8)))
            w.glow.flash(colors: [.white, NSColor(white: 0.92, alpha: 1)])
            w.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashing = false
                self.appliedColors = []
                self.windows.forEach { $0.glow.resetLevel() }
                self.update()
            }
        }
    }

    private func powerSourceChanged() {
        let now = Self.readOnBattery()
        if now != onBattery { onBattery = now; update() }
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    // MARK: The one place that decides what happens

    func update() {
        guard started, !flashing else { return }
        let pomo = pomodoroOverride

        var reason: String?
        if screensAsleep { reason = "Paused while the screen is locked." }
        else if pauseOnBattery && onBattery { reason = "Paused on battery power." }
        else if !pomo && mode == .music && hideWhenPaused && !music.isPlaying { reason = "Waiting for music to play." }

        let show = enabled && reason == nil
        note = enabled ? reason : nil

        guard show else {
            stopAudio()
            windows.forEach { $0.orderOut(nil) }
            isShowing = false
            return
        }

        ensureWindows()
        let motion = lowPower ? speed * 0.5 : speed
        for w in windows {
            w.glow.configure(thickness: CGFloat(thickness), speed: motion, intensity: Float(intensity))
            w.orderFrontRegardless()
        }
        isShowing = true

        let colors = palette
        if colors != appliedColors {
            appliedColors = colors
            windows.forEach { $0.glow.apply(colors: colors, animated: true) }
        }

        let wantAudio = !pomo && mode == .music && reactToAudio && music.isPlaying && !lowPower && !noSignalForTrack
        if wantAudio { startAudio() } else { stopAudio() }

        let reacting = audioStatus == .listening
        let period: Double = pomo ? 5 : (mode == .music ? (music.isPlaying ? 2.4 : 5) : 6 / max(0.25, motion))
        windows.forEach { $0.glow.setBreathing(!reacting, period: period) }
    }

    // MARK: Windows

    private func ensureWindows() {
        let screens = NSScreen.screens
        let same = windows.count == screens.count && zip(windows, screens).allSatisfy { $0.frame == $1.frame }
        if !same { rebuildWindows() }
    }

    private func rebuildWindows() {
        let wasLinked = link != nil
        stopLink()
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = NSScreen.screens.map { GlowWindow(screen: $0) }
        let colors = palette
        appliedColors = colors
        windows.forEach { $0.glow.apply(colors: colors, animated: false) }
        if wasLinked { startLink() }
    }

    // MARK: Audio reaction

    private func startAudio() {
        guard !tap.isRunning else { return }
        do {
            try tap.start()
            audioStatus = .listening
            silentFrames = 0
            env = 0
            peak = 0.05
            floorLevel = 0
            startLink()
        } catch {
            audioStatus = .failed
        }
    }

    private func stopAudio() {
        guard tap.isRunning || link != nil else { return }
        tap.stop()
        stopLink()
        if audioStatus == .listening { audioStatus = .idle }
        windows.forEach { $0.glow.resetLevel() }
    }

    private func startLink() {
        guard link == nil, let view = windows.first?.glow else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let raw = tap.level()

        // No sound reaching us while Music says it's playing → permission denied or protected
        // audio. Stop listening (saves battery) and fall back to a gentle pulse for this track.
        if raw < 0.00002 { silentFrames += 1 } else { silentFrames = 0 }
        if silentFrames > 30 * 4 && music.isPlaying {
            noSignalForTrack = true
            stopAudio()
            audioStatus = .noSignal
            update()
            return
        }

        // Auto-gain: follow the song's own loud/quiet range so every track pulses nicely.
        peak = max(max(raw, peak * 0.996), 0.01)
        floorLevel += (raw - floorLevel) * (raw < floorLevel ? 0.3 : 0.004)
        let norm = max(0, min(1, (raw - floorLevel) / max(0.005, peak - floorLevel)))
        let shaped = powf(norm, 1.4)
        env += (shaped - env) * (shaped > env ? 0.55 : 0.10) // fast attack, slow release

        for w in windows { w.glow.setLevel(env) }
    }

    func openAudioPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
