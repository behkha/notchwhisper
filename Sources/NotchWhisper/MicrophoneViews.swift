import SwiftUI

/// The input picker, shared by Settings and the menu bar: Automatic, every
/// connected microphone, and the picked one even while it is unplugged.
struct MicrophoneMenu: View {
    /// What the collapsed menu reads: the choice ("Automatic"), or the mic the
    /// next dictation will actually open ("AirPods Pro").
    enum Caption { case choice, device }
    var caption: Caption = .choice

    @EnvironmentObject private var settings: Settings
    @ObservedObject private var inputs = AudioInputManager.shared

    var body: some View {
        Menu {
            Toggle(isOn: choose(nil)) {
                Text("Automatic (\(inputs.automaticResolution.device?.name ?? "no microphone"))")
            }
            if !inputs.devices.isEmpty {
                Section("Microphones") {
                    ForEach(inputs.devices) { device in
                        Toggle(isOn: choose(device)) {
                            Label(title(for: device), systemImage: device.symbolName)
                        }
                        .disabled(inputs.lidClosed && device.isInternalMic)
                    }
                }
            }
            if let missing = missingChoiceName {
                Toggle(isOn: .constant(true)) { Text("\(missing) — not connected") }
                    .disabled(true)
            }
            Divider()
            Button("Sound Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Text(label).lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .help("The microphone NotchWhisper records from")
    }

    private var label: String {
        switch caption {
        case .choice:
            guard settings.inputDeviceUID != nil else { return "Automatic" }
            return settings.inputDeviceName ?? "Microphone"
        case .device:
            return inputs.resolution(for: settings).device?.name ?? "No microphone"
        }
    }

    private func title(for device: AudioInputDevice) -> String {
        inputs.lidClosed && device.isInternalMic ? "\(device.name) — off while the lid is closed" : device.name
    }

    /// The saved choice's name while it is unplugged.
    private var missingChoiceName: String? {
        guard let uid = settings.inputDeviceUID,
              !inputs.devices.contains(where: { $0.uid == uid }) else { return nil }
        return settings.inputDeviceName ?? "Selected microphone"
    }

    /// Checked when it is the current choice; picking it (again) selects it.
    private func choose(_ device: AudioInputDevice?) -> Binding<Bool> {
        Binding(get: { settings.inputDeviceUID == device?.uid },
                set: { _ in settings.selectInput(device) })
    }
}

/// The menu bar's input switcher: names the mic the next dictation opens, and
/// says so when a closed lid or an unplugged mic moved it somewhere else.
struct MicrophoneMenuBarRow: View {
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var inputs = AudioInputManager.shared

    var body: some View {
        let resolution = inputs.resolution(for: settings)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: resolution.device?.symbolName ?? "mic.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(resolution.device == nil ? Tokens.Color.warn : Tokens.Color.accent)
                    .frame(width: 18)
                Text("Microphone").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textSec)
                    .fixedSize()
                MicrophoneMenu(caption: .device)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let message = resolution.message {
                Text(message)
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(resolution.device == nil ? Tokens.Color.warn : Tokens.Color.textTert)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18 + Tokens.Space.x2)
            }
        }
        .padding(.horizontal, Tokens.Space.x3).padding(.vertical, 6)
    }
}

/// Settings → Microphone: which input dictation listens to, what a closed lid
/// is doing to it, and a meter that proves it hears you.
struct MicrophoneSettingsGroup: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var inputs = AudioInputManager.shared
    @StateObject private var tester = MicrophoneTester()

    var body: some View {
        let resolution = inputs.resolution(for: settings)
        SettingsGroup(title: "Microphone",
                      footnote: "Dictation, meetings and the Models lab all record from this microphone. Only NotchWhisper's input changes — System Settings and your other apps keep theirs.") {
            SettingRow(icon: "mic", title: "Input", subtitle: inputSubtitle) {
                MicrophoneMenu()
                    .frame(maxWidth: 200)
            }
            statusRow(resolution)
            SettingRow(icon: "waveform", title: "Test the microphone",
                       subtitle: testSubtitle) {
                HStack(spacing: Tokens.Space.x3) {
                    MicLevelBar(level: tester.level, active: tester.isRunning)
                        .frame(width: 90, height: 6)
                    Button(tester.isRunning ? "Stop" : "Test") {
                        if tester.isRunning { tester.stop() } else { tester.start(settings: settings) }
                    }
                    .secondaryAction()
                    .disabled(!tester.isRunning && !canTest(resolution))
                }
            }
        }
        .onDisappear { tester.stop() }
        // The meter is its own capture; it gives way to any real one.
        .onChange(of: state.mode) { _, mode in if mode != .idle { tester.stop() } }
        .onChange(of: state.meetingRecording) { _, recording in if recording { tester.stop() } }
        .onChange(of: settings.inputDeviceUID) { _, _ in
            if tester.isRunning { tester.start(settings: settings) }
        }
    }

    private var inputSubtitle: String {
        settings.inputDeviceUID == nil
            ? "Automatic follows System Settings → Sound. With the lid closed it moves to another microphone by itself, because the built-in one is switched off."
            : "Used whenever it's connected. When it isn't — or it's the built-in mic and the lid is closed — Automatic takes over."
    }

    private var testSubtitle: String {
        if let error = tester.error { return error }
        if tester.isRunning { return "Listening on \(tester.deviceName) — say something and watch the bar." }
        if inputs.resolution(for: settings).device == nil { return "Connect a microphone to test it." }
        return "Check it hears you before you dictate."
    }

    private func canTest(_ resolution: AudioInputResolution) -> Bool {
        resolution.device != nil && state.mode == .idle
            && !state.meetingRecording && !state.micReservedByModelLab
    }

    /// Only when something is off: the lid, a missing mic, or no mic at all.
    @ViewBuilder
    private func statusRow(_ resolution: AudioInputResolution) -> some View {
        if resolution.device == nil {
            SettingRow(icon: "mic.slash", tint: Tokens.Color.danger,
                       title: inputs.lidClosed ? "Lid closed — no microphone" : "No microphone",
                       subtitle: inputs.lidClosed
                        ? "A MacBook switches its built-in mic off in hardware while the lid is shut — no app can use it then. To dictate, connect AirPods or another headset, a USB mic or webcam, or use your iPhone as a microphone (keep it nearby and signed in to the same Apple Account). Or open the lid."
                        : "Connect a microphone, then pick it above.") {
                EmptyView()
            }
        } else if let device = resolution.device, let fallback = resolution.fallback {
            switch fallback {
            case .lidClosed:
                SettingRow(icon: "laptopcomputer", tint: Tokens.Color.warn, title: "Lid closed",
                           subtitle: "The built-in mic is off while the lid is shut, so NotchWhisper records from \(device.name).") {
                    EmptyView()
                }
            case .missing(let name):
                SettingRow(icon: "exclamationmark.triangle.fill", tint: Tokens.Color.warn,
                           title: "\(name) isn't connected",
                           subtitle: "NotchWhisper records from \(device.name) until it's back.") {
                    EmptyView()
                }
            }
        }
    }
}

/// A thin horizontal level bar for the microphone test.
struct MicLevelBar: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Color.fillQuiet)
                Capsule()
                    .fill(Tokens.Color.accentGradient)
                    .frame(width: max(active ? 4 : 0, geo.size.width * CGFloat(level)))
                    .animation(Tokens.Motion.meter, value: level)
            }
        }
        .opacity(active ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(active ? "\(Int(level * 100)) percent" : "Off")
    }
}
