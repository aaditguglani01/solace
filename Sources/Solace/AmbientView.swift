import SwiftUI

struct AmbientView: View {
    @EnvironmentObject private var ambient: AmbientController
    @ObservedObject private var music = AmbientController.shared.music

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ambient")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Toggle("Ambient Light", isOn: $ambient.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            preview
                .padding(.horizontal, 24)
                .padding(.top, 12)

            Form {
                Section {
                    Picker("Source", selection: $ambient.mode) {
                        ForEach(AmbientMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if ambient.mode == .music { musicSection } else { colorSection }
                }

                Section {
                    Toggle("Follow Pomodoro", isOn: $ambient.followPomodoro)
                } footer: {
                    Text("While a Pomodoro is running, the glow turns warm for focus and green for breaks.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section("Look") {
                    LabeledSlider(title: "Brightness", value: $ambient.intensity, range: 0.2...1)
                    LabeledSlider(title: "Width", value: $ambient.thickness, range: 24...180)
                    LabeledSlider(title: "Motion", value: $ambient.speed, range: 0.25...3)
                }

                Section {
                    Toggle("Pause on battery power", isOn: $ambient.pauseOnBattery)
                } header: {
                    Text("Battery")
                } footer: {
                    Text(batteryFooter)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Preview card (static — costs nothing)

    private var preview: some View {
        let colors = ambient.palette.map { Color(nsColor: $0) }
        let ring = AngularGradient(colors: colors + [colors.first ?? .white], center: .center)
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.black.opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ring, lineWidth: 10)
                    .blur(radius: 10)
                    .opacity(ambient.enabled ? 1 : 0.25)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ring, lineWidth: 1.5)
                    .opacity(ambient.enabled ? 0.9 : 0.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .center) {
                Text(statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(height: 110)
            .animation(.easeInOut(duration: 0.6), value: colors)
    }

    private var statusLine: String {
        if !ambient.enabled { return "Off" }
        if let note = ambient.note { return note }
        if ambient.pomodoroOverride { return "Following Pomodoro" }
        switch ambient.mode {
        case .color: return ambient.lowPower ? "On · Low Power Mode" : "On"
        case .music:
            if !music.isPlaying { return "On · Play something in Apple Music" }
            switch ambient.audioStatus {
            case .listening: return "Moving with the music"
            case .noSignal, .failed: return "Pulsing gently with the album colors"
            case .idle: return ambient.lowPower ? "Album colors · beat sync off in Low Power Mode" : "Album colors"
            }
        }
    }

    // MARK: Music

    @ViewBuilder
    private var musicSection: some View {
        HStack(spacing: 12) {
            Group {
                if let art = music.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.primary.opacity(0.07)
                        Image(systemName: "music.note").foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(music.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(music.artist ?? "Play a song in Apple Music")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                music.syncFromApp()
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh from Apple Music")
        }

        Toggle("React to the beat", isOn: $ambient.reactToAudio)
        Toggle("Hide when music is paused", isOn: $ambient.hideWhenPaused)

        if ambient.reactToAudio && (ambient.audioStatus == .noSignal || ambient.audioStatus == .failed) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Solace can't hear the audio, so it's using a gentle pulse instead. To sync to the beat, allow Solace under Privacy & Security › Screen & System Audio Recording (System Audio Recording Only).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { ambient.openAudioPrivacySettings() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Color

    @ViewBuilder
    private var colorSection: some View {
        HStack(spacing: 10) {
            ForEach(ColorPreset.all) { preset in
                Button {
                    ambient.customHex = preset.hex
                } label: {
                    Circle()
                        .fill(AngularGradient(colors: preset.colors + [preset.colors[0]], center: .center))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(ambient.customHex == preset.hex ? 0.9 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
        .padding(.vertical, 4)

        HStack {
            Text("Custom")
            Spacer()
            ForEach(0..<3, id: \.self) { i in
                ColorPicker("", selection: colorBinding(i), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex = ambient.customHex
                return Color(nsColor: NSColor(hex: hex.indices.contains(i) ? hex[i] : "FFFFFF"))
            },
            set: { newValue in
                var hex = ambient.customHex
                while hex.count < 3 { hex.append(hex.last ?? "FFFFFF") }
                hex[i] = NSColor(newValue).hexString
                ambient.customHex = hex
            }
        )
    }

    private var batteryFooter: String {
        var s = "The glow is drawn by the system compositor at low resolution, listens to audio only while music is playing, and turns itself off when the screen locks."
        if ambient.lowPower { s += " Low Power Mode is on: motion is slowed and beat sync is off." }
        return s
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}
