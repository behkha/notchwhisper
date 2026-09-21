import AppKit
@preconcurrency import AVFoundation

/// `NotchWhisper --mic-selftest` exercises the input switcher and the
/// lid-closed fallback without anyone at the Mac:
///
/// 1. The choice rules over made-up device lists — no hardware involved.
/// 2. The live device list and what it resolves to, lid open and closed.
/// 3. When BlackHole is installed, real captures routed to it while `say -a`
///    speaks into it: dictation's recorder (transcribed by the active model),
///    a capture moved off the built-in mic when the simulated lid closes, the
///    Settings meter, and the meeting recorder.
///
/// Changes the microphone choice while it runs and puts it back afterwards.
@MainActor
enum MicrophoneSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func run() async -> Int32 {
        choiceRules()
        symbols()
        liveDevices()
        await routedCaptures()
        print(failures == 0 ? "mic-selftest: all checks passed" : "mic-selftest: \(failures) check(s) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: 1. Choice rules

    private static func choiceRules() {
        let mac = AudioInputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                   kind: .builtIn, isInternalMic: true)
        let usb = AudioInputDevice(id: 2, uid: "usb", name: "Blue Yeti", kind: .usb, isInternalMic: false)
        let pods = AudioInputDevice(id: 3, uid: "pods", name: "AirPods Pro", kind: .bluetooth, isInternalMic: false)
        let phone = AudioInputDevice(id: 4, uid: "phone", name: "iPhone Microphone", kind: .iPhone, isInternalMic: false)
        let hole = AudioInputDevice(id: 5, uid: "hole", name: "BlackHole 2ch", kind: .virtual, isInternalMic: false)
        let jack = AudioInputDevice(id: 6, uid: "jack", name: "External Microphone", kind: .builtIn, isInternalMic: false)
        let webcam = AudioInputDevice(id: 7, uid: "cam", name: "Webcam", kind: .usb, isInternalMic: false)

        func pick(_ uid: String?, name: String? = nil, _ devices: [AudioInputDevice],
                  input: AudioDeviceID?, output: AudioDeviceID? = nil, lid: Bool) -> AudioInputResolution {
            AudioInputs.resolve(preferredUID: uid, preferredName: name, devices: devices,
                                defaultInput: input, defaultOutput: output, lidClosed: lid)
        }

        var r = pick(nil, [mac, hole], input: 1, lid: false)
        check("lid open: Automatic uses the system input", r.device == mac && r.fallback == nil)

        r = pick(nil, [mac, hole], input: 1, lid: true)
        check("lid closed, only the built-in mic and a virtual device: no microphone",
              r.device == nil && r.fallback == .lidClosed, r.message ?? "")
        check("…and the message says why", r.message?.hasPrefix("Lid closed") == true)

        r = pick(nil, [mac, hole, phone, pods], input: 1, lid: true)
        check("lid closed: Bluetooth before iPhone, never the virtual device",
              r.device == pods && r.fallback == .lidClosed, r.message ?? "")

        r = pick(nil, [mac, pods, usb], input: 1, lid: true)
        check("lid closed: wired before wireless", r.device == usb)

        r = pick(nil, [mac, usb, pods], input: 1, output: 3, lid: true)
        check("lid closed: the headset being listened on comes first", r.device == pods)

        r = pick("BuiltInMicrophoneDevice", [mac, usb], input: 1, lid: true)
        check("lid closed with the built-in mic picked: falls back",
              r.device == usb && r.fallback == .lidClosed)

        r = pick("usb", name: "Blue Yeti", [mac], input: 1, lid: false)
        check("picked mic unplugged: falls back to Automatic and names it",
              r.device == mac && r.fallback == .missing("Blue Yeti"), r.message ?? "")

        r = pick("usb", name: "Blue Yeti", [mac], input: 1, lid: true)
        check("picked mic unplugged and lid closed: no microphone, the lid explains it",
              r.device == nil && r.fallback == .lidClosed)

        r = pick("hole", [mac, hole], input: 1, lid: true)
        check("a virtual device picked by hand is used", r.device == hole && r.fallback == nil)

        r = pick(nil, [mac, pods], input: 3, lid: true)
        check("lid closed, system input already external: no fallback", r.device == pods && r.fallback == nil)

        r = pick(nil, [mac, jack], input: 1, lid: true)
        check("lid closed: a headset in the jack still works", r.device == jack)

        r = pick(nil, [], input: nil, lid: false)
        check("no devices: no microphone", r.device == nil && r.message?.hasPrefix("No microphone") == true)

        r = pick(nil, [hole, usb], input: nil, lid: false)
        check("no system input: the best real mic", r.device == usb && r.fallback == nil)

        r = pick(nil, [mac, usb, webcam], input: 1, lid: true)
        check("equal rank keeps Core Audio's order", r.device == usb)

        r = pick(nil, [hole], input: 5, lid: true)
        check("lid closed, built-in mic gone and macOS fell back to a loopback: no microphone",
              r.device == nil && r.fallback == .lidClosed)

        r = pick(nil, [hole, pods], input: 5, lid: true)
        check("lid closed with a loopback as system input: the real mic wins",
              r.device == pods && r.fallback == .lidClosed)

        r = pick(nil, [mac, hole], input: 5, lid: false)
        check("lid open: a virtual system input is respected", r.device == hole && r.fallback == nil)
    }

    // MARK: 2. Symbols and live devices

    private static func symbols() {
        let names = ["laptopcomputer", "headphones", "cable.connector", "airpodsmax", "airpodspro", "airpods",
                     "iphone", "display", "slider.vertical.3", "waveform", "square.stack.3d.up", "mic",
                     "mic.slash", "mic.fill", "mic.slash.fill", "exclamationmark.triangle.fill"]
        let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("every SF Symbol the switcher draws exists", missing.isEmpty, missing.joined(separator: ", "))
    }

    private static func liveDevices() {
        let devices = AudioInputs.devices()
        let input = AudioInputs.defaultInputID()
        let output = AudioInputs.defaultOutputID()
        print("live: lid \(AudioInputs.isLidClosed() ? "closed" : "open"), system input id \(input.map(String.init) ?? "none")")
        for device in devices {
            print("  • \(device.name)  [\(device.kind)\(device.isInternalMic ? ", internal" : "")]  id=\(device.id) uid=\(device.uid)")
        }
        check("at least one input device is listed", !devices.isEmpty)
        for lid in [false, true] {
            let r = AudioInputs.resolve(preferredUID: nil, preferredName: nil, devices: devices,
                                        defaultInput: input, defaultOutput: output, lidClosed: lid)
            print("live: lid \(lid ? "closed" : "open") → \(r.device?.name ?? "no microphone")\(r.message.map { " — \($0)" } ?? "")")
        }
    }

    // MARK: 3. Real captures through BlackHole

    private static func routedCaptures() async {
        let devices = AudioInputs.devices()
        guard let hole = devices.first(where: { $0.uid.hasPrefix("BlackHole") }) else {
            print("SKIP  routed captures: BlackHole isn't installed")
            return
        }
        let settings = Settings.shared
        let state = AppState.shared
        let saved = (uid: settings.inputDeviceUID, name: settings.inputDeviceName)
        defer {
            AudioInputs.simulateLidClosed = false
            settings.selectInput(saved.uid.map {
                AudioInputDevice(id: 0, uid: $0, name: saved.name ?? "", kind: .other, isInternalMic: false)
            })
        }
        let recorder = AudioRecorder(state, settings)

        // Dictation's recorder, routed to BlackHole.
        settings.selectInput(hole)
        do {
            try recorder.start()
            check("recorder opens the picked mic", recorder.activeDevice?.uid == hole.uid,
                  recorder.activeDevice?.name ?? "none")
            try? await Task.sleep(nanoseconds: 600_000_000)
            // Routing reconfigures the engine just after start; it must keep
            // (or resume) capturing rather than fall silent.
            check("a routed capture keeps flowing after start", recorder.sampleCount > 16_000 * 3 / 10,
                  "\(recorder.sampleCount) samples in 0.6 s")
            check("…on the engine it started with", recorder.engineOpens == 1, "\(recorder.engineOpens) engines")
            await speak("The quick brown fox is testing the microphone switcher.", into: hole)
            let samples = recorder.stop()
            let speech = rms(samples)
            check("speech played into BlackHole reaches the capture", speech > 0.02,
                  String(format: "rms %.3f over %.1f s", speech, Double(samples.count) / 16_000))
            let transcriber = Transcriber(state, settings)
            if await transcriber.ensureLoaded() {
                let text = (try? await transcriber.transcribe(samples)) ?? ""
                print("transcript: \(text)")
                let lowered = text.lowercased()
                check("the routed capture transcribes", lowered.contains("fox") || lowered.contains("microphone"))
            } else {
                print("SKIP  transcription: no model could be loaded")
            }
        } catch {
            check("recorder opens the picked mic", false, error.localizedDescription)
        }

        // A capture that starts on the built-in mic and moves when the lid closes.
        if let mac = devices.first(where: \.isInternalMic) {
            settings.selectInput(mac)
            do {
                try recorder.start()
                check("capture starts on the built-in mic", recorder.activeDevice?.uid == mac.uid)
                try? await Task.sleep(nanoseconds: 800_000_000)
                let before = recorder.sampleCount
                // A new choice alone must not move a capture whose mic still works.
                settings.selectInput(hole)
                NotificationCenter.default.post(name: .audioInputsChanged, object: nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                check("a working mic is kept when the choice changes mid-capture",
                      recorder.activeDevice?.uid == mac.uid && recorder.engineOpens == 1,
                      "\(recorder.engineOpens) engines")
                AudioInputs.simulateLidClosed = true
                NotificationCenter.default.post(name: .audioInputsChanged, object: nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                check("closing the lid moves the capture off the built-in mic",
                      recorder.activeDevice?.uid == hole.uid && recorder.engineOpens == 2,
                      "\(recorder.activeDevice?.name ?? "none"), \(recorder.engineOpens) engines")
                check("the notch names the mic it moved to", state.inputFallbackName == hole.name,
                      state.inputFallbackName)
                await speak("Recording continues after the lid closed.", into: hole)
                let samples = recorder.stop()
                check("audio from before the move is kept", samples.count > before && before > 8_000,
                      "\(before) samples before, \(samples.count) total")
                check("speech after the move is captured", rms(Array(samples.suffix(from: before))) > 0.02)
                check("stopping clears the notch label", state.inputFallbackName.isEmpty)
            } catch {
                check("capture starts on the built-in mic", false, error.localizedDescription)
            }
            AudioInputs.simulateLidClosed = false
        }

        // Lid closed with only the built-in mic and a virtual device: refuse clearly.
        settings.selectInput(nil)
        AudioInputs.simulateLidClosed = true
        let realMics = AudioInputs.devices().filter { !$0.isInternalMic && $0.isAutomaticCandidate }
        if realMics.isEmpty {
            do {
                try recorder.start()
                _ = recorder.stop()
                check("lid closed without a mic refuses to record", false, "it recorded")
            } catch {
                check("lid closed without a mic refuses to record", error is AudioInputs.InputError,
                      error.localizedDescription)
            }
        } else {
            print("SKIP  lid-closed refusal: a real external mic is connected (\(realMics[0].name))")
        }
        AudioInputs.simulateLidClosed = false

        // The Settings meter.
        settings.selectInput(hole)
        let tester = MicrophoneTester()
        tester.start(settings: settings)
        var peak: Float = 0
        let meterWatch = Task { @MainActor in
            while !Task.isCancelled {
                peak = max(peak, tester.level)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await speak("Testing the level meter.", into: hole)
        meterWatch.cancel()
        tester.stop()
        check("the Settings meter moves with speech", peak > 0.1,
              String(format: "peak %.2f", peak) + (tester.error.map { ", error: \($0)" } ?? ""))

        // The meeting recorder, routed the same way.
        let meeting = MeetingRecorder()
        meeting.preferredInput = (hole.uid, hole.name)
        let notices = NoticeLog()
        meeting.onNotice = { notices.add($0) }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("nw-mic-selftest.wav")
        do {
            try await meeting.start(to: wav, includeSystemAudio: false)
            await speak("Meetings record from the chosen microphone too.", into: hole)
            let seconds = await meeting.stop()
            let back = try await AudioFileImport.loadSamples(from: wav)
            check("the meeting recorder captures the picked mic", rms(back) > 0.01,
                  String(format: "%.1f s, rms %.3f", seconds, rms(back)))
            check("no spurious 'microphone changed' notice", notices.all.isEmpty, notices.all.joined(separator: " | "))
        } catch {
            check("the meeting recorder captures the picked mic", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: wav)
    }

    /// Speaks into `device` (BlackHole loops its output back to its input)
    /// and waits for it to finish, plus a short tail.
    private static func speak(_ text: String, into device: AudioInputDevice) async {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-a", device.name, text]
        do { try say.run() } catch { print("say failed: \(error)"); return }
        while say.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private final class NoticeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var notices: [String] = []
        func add(_ notice: String) { lock.lock(); notices.append(notice); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return notices }
    }
}
