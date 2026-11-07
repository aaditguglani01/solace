import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case time = "Time"
    case todo = "To-Do"
    case syllabus = "Syllabus"
    case ambient = "Ambient"
    var id: Self { self }

    var icon: String {
        switch self {
        case .time: return "timer"
        case .todo: return "checklist"
        case .syllabus: return "book.closed"
        case .ambient: return "sparkles"
        }
    }
}

/// Shared palette for the pitch-black look.
enum Ink {
    static let background = Color.black
    static let surface = Color(white: 0.06)
    static let stroke = Color(white: 0.17)
    static let dim = Color(white: 0.22)
    static let label = Color(white: 0.48)
}

struct ContentView: View {
    @AppStorage("selectedTab") private var tab: AppTab = .time

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .time: TimeView()
                case .todo: TodoView()
                case .syllabus: SyllabusView()
                case .ambient: AmbientView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 26)      // room for the window buttons
            .padding(.bottom, 64)   // room for the tab bar

            TabPill(selection: $tab)
                .padding(.bottom, 16)
        }
        .overlay(alignment: .topTrailing) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.label)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
        .background(Ink.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

/// Floating pill tab bar at the bottom.
struct TabPill: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 12, weight: .medium))
                        Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selected ? Color.white : Ink.label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(selected ? Color(white: 0.16) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Ink.surface))
        .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
    }
}

/// A quiet, text-only switcher (secondary navigation inside a tab).
struct TextSwitcher<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 22) {
            ForEach(items) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? Color.white : Ink.label)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Round button: icon or short text. `primary` = solid white with a black glyph.
struct CircleButton: View {
    var icon: String? = nil
    var text: String? = nil
    var primary = false
    var diameter: CGFloat = 52
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: diameter * 0.32, weight: .semibold))
                } else {
                    Text(text ?? "").font(.system(size: diameter * 0.3, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(primary ? Color.black : Color.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(primary ? Color.white : Ink.surface))
            .overlay(Circle().strokeBorder(primary ? Color.clear : Ink.stroke, lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Two grey dots used as the ":" between big digits.
struct ColonDots: View {
    var size: CGFloat

    var body: some View {
        VStack(spacing: size * 0.32) {
            Circle().frame(width: size * 0.12, height: size * 0.12)
            Circle().frame(width: size * 0.12, height: size * 0.12)
        }
        .foregroundStyle(Color(white: 0.4))
        .padding(.horizontal, size * 0.08)
    }
}

enum TimeFormat {
    /// 1:05:09, 05:09
    static func clock(_ t: TimeInterval, forceHours: Bool = false) -> String {
        let total = max(0, Int(t.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 || forceHours { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// ["05", "59", "49"] or ["04", "59"]
    static func parts(_ t: TimeInterval, forceHours: Bool) -> [String] {
        let total = max(0, Int(t.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 || forceHours { return [String(format: "%02d", h), String(format: "%02d", m), String(format: "%02d", s)] }
        return [String(format: "%02d", m), String(format: "%02d", s)]
    }

    /// 01:05.42 (stopwatch)
    static func precise(_ t: TimeInterval) -> String {
        let cs = Int((max(0, t) * 100).rounded(.down))
        let h = cs / 360_000, m = (cs % 360_000) / 6000, s = (cs % 6000) / 100, c = cs % 100
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, c) }
        return String(format: "%02d:%02d.%02d", m, s, c)
    }
}
