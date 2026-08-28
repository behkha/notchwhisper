import SwiftUI
import Carbon

/// Settings window content. Holds the hotkey capture and the model picker /
/// download — exactly the two things the user asked to live here. A small
/// behavior section (auto-type, language, translate) is included because it is
/// cheap and useful, but hotkey + model are the primary controls.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings

    @State private var capturing = false
    @State private var captureLabel = "Press a key…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                generalSection
                Divider().foregroundStyle(Tokens.Color.separator)
                appearanceSection
                Divider().foregroundStyle(Tokens.Color.separator)
                hotkeySection
                Divider().foregroundStyle(Tokens.Color.separator)
                modelSection
            }
            .padding(Tokens.Space.x6)
            .frame(width: 520)
        }
        .background(Tokens.Color.bg)
    }

    // MARK: General
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("General")
            Toggle(isOn: $settings.launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("Start NotchWhisper automatically when you log in. It lives quietly in the menu bar until you hold the hotkey.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: settings.launchAtLogin) { _, _ in
                settings.applyLaunchAtLogin()
            }
        }
    }

    // MARK: Appearance
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Appearance")
            Toggle(isOn: $settings.reactiveGlow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice-reactive notch glow")
                        .font(Tokens.TypeScale.body)
                        .foregroundStyle(Tokens.Color.text)
                    Text("While recording, the notch's ambient glow breathes and heats up with your voice. Turn off for a calm, static glow.")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.textTert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            visualizerPicker
        }
    }

    // MARK: Visualizer style (LiveKit Agents-UI family)
    private var visualizerPicker: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Text("Notch visualizer")
                .font(Tokens.TypeScale.body)
                .foregroundStyle(Tokens.Color.text)

            Picker("Notch visualizer", selection: $settings.visualizerStyle) {
                ForEach(VisualizerStyle.allCases) { style in
                    Text(style.display).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.visualizerStyle.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            // Live preview on a black island strip, driven by a simulated voice.
            VisualizerPreview(style: settings.visualizerStyle)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(.black)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Border.hair)
                )
        }
    }

    // MARK: Hotkey
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Hold-to-talk Hotkey")
            Text("Press and hold this key anywhere to record; release to transcribe and type.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Tokens.Space.x3) {
                Button {
                    armCapture()
                } label: {
                    Text(capturing ? captureLabel : settings.hotkeyDisplay)
                        .font(Tokens.TypeScale.title2)
                        .frame(minWidth: 120, minHeight: 44)
                        .foregroundStyle(capturing ? Tokens.Color.record : Tokens.Color.text)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .fill(capturing ? Tokens.Color.record.opacity(0.12) : Tokens.Color.fillQuiet)
                        )
                }
                .buttonStyle(.plain)

                Button("Reset to Right ⌥") {
                    settings.hotkeyCode = 61
                    settings.hotkeyModifiers = 0
                    NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.Color.textSec)
                .font(Tokens.TypeScale.callout)

                Spacer()
            }
        }
        .onDisappear { cancelCapture() }
    }

    // MARK: Model
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            sectionTitle("Model")
            Text("Local Whisper models are downloaded from Hugging Face and run on-device. Larger models are more accurate but slower.")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Active model", selection: $settings.modelId) {
                ForEach(WhisperModelOption.all) { m in
                    Text("\(m.display)  ·  \(m.size)  ·  \(m.quality)")
                        .tag(m.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: settings.modelId) { _, _ in
                NotificationCenter.default.post(name: .modelChanged, object: nil)
            }

            // Downloaded models + download action.
            HStack(spacing: Tokens.Space.x2) {
                Text(downloadedSummary)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer()
                if state.isDownloading {
                    ProgressView(value: state.downloadProgress) {
                        Text(state.downloadLabel)
                            .font(Tokens.TypeScale.caption)
                    }
                    .frame(width: 160)
                } else {
                    Button {
                        AppDelegate.shared?.requestDownload(modelId: settings.modelId)
                    } label: {
                        Text(WhisperModelOption.find(id: settings.modelId).folderName == currentFolder
                             ? "Reload" : "Download")
                        .font(Tokens.TypeScale.captionSB)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Color.accent)
                }
            }
        }
    }

    @State private var currentFolder: String = ""

    private var downloadedSummary: String {
        let local = AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []
        if local.isEmpty { return "No models downloaded yet." }
        return "On disk: " + local.map { WhisperModelOption.find(id: $0).display }.joined(separator: ", ")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(Tokens.TypeScale.title2)
            .foregroundStyle(Tokens.Color.text)
    }

    // MARK: Hotkey capture (local monitor while armed)
    private func armCapture() {
        capturing = true
        captureLabel = "Press a key…"
        var monitor: Any?
        // Keycodes for the dedicated modifier keys. When the user presses one of
        // these alone we register it as a standalone hotkey (mods 0) — e.g. the
        // right-Option key (61) fires on its own press, and must NOT also carry
        // the `optionKey` mask (which would require "option + right-option").
        let modifierKeyCodes: Set<Int> = [58, 61, 55, 54, 56, 60, 59, 57]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let code = Int(event.keyCode)
            if modifierKeyCodes.contains(code) {
                settings.hotkeyCode = UInt32(code)
                settings.hotkeyModifiers = 0
            } else {
                let mods = UInt32(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
                settings.hotkeyCode = UInt32(code)
                settings.hotkeyModifiers = mods
            }
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
            if let m = monitor { NSEvent.removeMonitor(m) }
            capturing = false
            return nil // swallow the key
        }
    }

    private func cancelCapture() {
        capturing = false
    }
}
