import SwiftUI
import AppKit

@main
struct SolaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var countdown = CountdownModel.shared
    @StateObject private var stopwatch = StopwatchModel.shared
    @StateObject private var pomodoro = PomodoroModel.shared
    @StateObject private var todos = TodoStore.shared
    @StateObject private var syllabus = SyllabusStore.shared
    @StateObject private var exams = ExamStore.shared
    @StateObject private var focusLog = FocusLog.shared
    @StateObject private var ambient = AmbientController.shared

    init() {
        // Carry settings over from the earlier "Halo" builds before anything reads them.
        Storage.migrateSettingsFromHalo()
    }

    var body: some Scene {
        Window("Solace", id: "main") {
            ContentView()
                .environmentObject(countdown)
                .environmentObject(stopwatch)
                .environmentObject(pomodoro)
                .environmentObject(todos)
                .environmentObject(syllabus)
                .environmentObject(exams)
                .environmentObject(focusLog)
                .environmentObject(ambient)
                .frame(minWidth: 560, minHeight: 600)
                .background(WindowOpenerInstaller())
        }
        .defaultSize(width: 840, height: 680)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { SolaceCommands() }

        Settings {
            SettingsView()
                .environmentObject(ambient)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(ambient)
                .environmentObject(countdown)
                .environmentObject(pomodoro)
        } label: {
            Image(systemName: "circle.dashed.inset.filled")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AmbientController.shared.start()
            NotchController.shared.start()
            Alerts.shared.prepare()
        }
        // Space = start / pause on the Time tab (ignored while typing in a text field).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { KeyShortcuts.handle(event) }
            return handled ? nil : event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            TodoStore.shared.flush()
            SyllabusStore.shared.flush()
        }
    }

    // Keep running (and glowing) when the window is closed. Quit from the menu bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
enum KeyShortcuts {
    static func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false } // space
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty, let window = event.window, !(window is NSPanel) else { return false }
        if window.firstResponder is NSText { return false } // typing
        let d = UserDefaults.standard
        guard d.string(forKey: "selectedTab") ?? AppTab.time.rawValue == AppTab.time.rawValue else { return false }
        switch TimeMode(rawValue: d.string(forKey: "timeMode") ?? "") ?? .timer {
        case .timer:
            let m = CountdownModel.shared
            if m.isActive || m.duration > 0 { m.toggle() }
        case .stopwatch: StopwatchModel.shared.toggle()
        case .pomodoro: PomodoroModel.shared.toggle()
        default: return false
        }
        return true
    }
}

/// Lets AppKit code (menu commands, the notch pill) bring the main window back.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?

    static func open(tab: AppTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Solace" }), !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        } else {
            if let action { action(id: "main") }
        }
    }
}

private struct WindowOpenerInstaller: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { WindowOpener.action = openWindow }
    }
}

struct SolaceCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Solace") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New To-Do") {
                WindowOpener.open(tab: .todo)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NotificationCenter.default.post(name: .solaceNewTodo, object: nil)
                }
            }
            .keyboardShortcut("n")
            Divider()
            Button("Export Backup…") { Backup.export() }
            Button("Import Backup…") { Backup.importBackup() }
        }
        CommandMenu("Go") {
            Button("Time") { WindowOpener.open(tab: .time) }.keyboardShortcut("1")
            Button("To-Do") { WindowOpener.open(tab: .todo) }.keyboardShortcut("2")
            Button("Syllabus") { WindowOpener.open(tab: .syllabus) }.keyboardShortcut("3")
            Button("Ambient") { WindowOpener.open(tab: .ambient) }.keyboardShortcut("4")
        }
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(
            string: "Designed and developed by Aadit Guglani\nBuilt with Claude (AI)\n\nNo accounts, no ads, no internet. Your data stays on your Mac.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var ambient: AmbientController
    @EnvironmentObject private var countdown: CountdownModel
    @EnvironmentObject private var pomodoro: PomodoroModel

    var body: some View {
        Button("Open Solace") { WindowOpener.open() }
            .keyboardShortcut("o")

        Divider()

        Toggle("Ambient Light", isOn: $ambient.enabled)

        Picker("Light Mode", selection: $ambient.mode) {
            ForEach(AmbientMode.allCases) { Text($0.title).tag($0) }
        }

        if countdown.isActive || pomodoro.isActive {
            Divider()
            if countdown.isActive { Text("Timer running") }
            if pomodoro.isActive { Text("Pomodoro — \(pomodoro.phase.title)") }
        }

        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("About Solace") { AboutPanel.show() }
        Text("Solace by Aadit Guglani")

        Divider()

        Button("Quit Solace") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @EnvironmentObject private var ambient: AmbientController
    @AppStorage("notch.enabled") private var notchEnabled = true
    @AppStorage("flash.enabled") private var flashEnabled = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show the running timer next to the notch", isOn: $notchEnabled)
                Toggle("Flash the screen edges when a timer ends", isOn: $flashEnabled)
                Toggle("Glow follows Pomodoro (warm for focus, green for breaks)", isOn: $ambient.followPomodoro)
            }

            Section {
                HStack {
                    Button("Export Backup…") { Backup.export() }
                    Button("Import Backup…") { Backup.importBackup() }
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything is stored only on this Mac. Export a backup to move your lists, syllabus, exams and study time to another Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Solace \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Designed and developed by Aadit Guglani")
                            .font(.system(size: 12))
                        Text("Built with Claude (AI) · © 2026 Aadit Guglani")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
