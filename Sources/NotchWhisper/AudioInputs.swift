import AppKit
import AudioToolbox
import CoreAudio
import IOKit
@preconcurrency import AVFoundation

// MARK: - Device

/// One Core Audio device that can capture sound.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// Core Audio's handle — only valid while the device stays connected.
    let id: AudioDeviceID
    /// Stable across reconnects and restarts; what a saved choice remembers.
    let uid: String
    let name: String
    let kind: Kind
    /// The MacBook's own microphone. Every notebook with a T2 chip or Apple
    /// silicon disconnects it in hardware while the lid is closed, so in
    /// clamshell mode it is still listed but only ever records silence.
    let isInternalMic: Bool

    enum Kind: Sendable {
        case builtIn, usb, bluetooth, iPhone, display, interface, virtual, aggregate, other
    }

    var symbolName: String {
        switch kind {
        case .builtIn:
            return isInternalMic ? "laptopcomputer" : "headphones"
        case .usb:
            return "cable.connector"
        case .bluetooth:
            let lowered = name.lowercased()
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            return "headphones"
        case .iPhone:    return "iphone"
        case .display:   return "display"
        case .interface: return "slider.vertical.3"
        case .virtual:   return "waveform"
        case .aggregate: return "square.stack.3d.up"
        case .other:     return "mic"
        }
    }

    /// Automatic selection never falls back to a virtual device (BlackHole,
    /// Zoom, Teams) — those carry an app's audio, not a voice — or to an
    /// aggregate the user built on purpose. Both can still be picked by hand.
    var isAutomaticCandidate: Bool { kind != .virtual && kind != .aggregate }

    /// Fallback order when the chosen mic can't be used: wired before
    /// wireless (it was plugged in for a reason), the iPhone last because it
    /// has to be nearby and awake.
    var fallbackRank: Int {
        switch kind {
        case .usb, .builtIn: return 0   // .builtIn here can only be the headset jack
        case .interface:     return 1
        case .bluetooth:     return 2
        case .display:       return 3
        case .iPhone:        return 4
        case .other:         return 5
        case .virtual, .aggregate: return 9
        }
    }
}

// MARK: - Choice

/// Which microphone the next capture opens, and why it might not be the one
/// the user picked.
struct AudioInputResolution: Equatable, Sendable {
    /// nil when no microphone can be used at all.
    let device: AudioInputDevice?
    /// Set when `device` is not what the user asked for (or there is none).
    let fallback: Fallback?

    enum Fallback: Equatable, Sendable {
        /// The lid is closed, so the built-in mic is off.
        case lidClosed
        /// The chosen mic isn't connected; carries its saved name.
        case missing(String)
    }

    /// One sentence for the notch, a toast or Settings. nil when the capture
    /// uses exactly what was chosen.
    var message: String? {
        switch (device, fallback) {
        case (let device?, .lidClosed?):
            return "Lid closed — using \(device.name)."
        case (let device?, .missing(let name)?):
            return "\(name) isn't connected — using \(device.name)."
        case (_?, nil):
            return nil
        case (nil, .lidClosed?):
            return "Lid closed, so the built-in mic is off. Connect AirPods, a USB mic or your iPhone."
        case (nil, .missing(let name)?):
            return "\(name) isn't connected, and there's no other microphone."
        case (nil, nil):
            return "No microphone found. Connect one, then try again."
        }
    }
}

// MARK: - Core Audio, IOKit, routing

enum AudioInputs {

    enum InputError: LocalizedError {
        /// Nothing usable to record from; carries the resolution's message.
        case unavailable(String)
        /// Core Audio refused to open the device.
        case openFailed(name: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message):
                return message
            case .openFailed(let name, let status):
                return "\(name) couldn't be opened (Core Audio error \(status)). Pick another microphone in Settings."
            }
        }
    }

    // MARK: Devices

    /// Every connected device with at least one input channel, in Core Audio's
    /// order. Hidden and dying devices are left out.
    static func devices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> AudioInputDevice? in
            guard inputChannelCount(id) > 0,
                  uint32(id, kAudioDevicePropertyIsHidden) != 1,
                  uint32(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Microphone"
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                kind: kind(forTransport: transport),
                isInternalMic: isInternalMic(id, transport: transport, name: name, uid: uid)
            )
        }
    }

    /// The input chosen in System Settings → Sound.
    static func defaultInputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The output the user is listening on — its mic, when it has one, is
    /// the headset already in their ears.
    static func defaultOutputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: Lid

    /// Dev hook: `--simulate-lid-closed` makes the app behave as though the
    /// MacBook were in clamshell mode, so the fallback can be exercised with
    /// the lid open. `--mic-selftest` flips it mid-capture.
    nonisolated(unsafe) static var simulateLidClosed = CommandLine.arguments.contains("--simulate-lid-closed")

    /// Whether a MacBook's lid is closed right now (clamshell mode with an
    /// external display). Always false on desktops, which have no lid.
    static func isLidClosed() -> Bool {
        if simulateLidClosed { return true }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: Choosing

    /// The microphone a capture should open right now, read live from Core
    /// Audio and the lid sensor.
    static func resolve(preferredUID: String?, preferredName: String?) -> AudioInputResolution {
        resolve(preferredUID: preferredUID, preferredName: preferredName,
                devices: devices(), defaultInput: defaultInputID(),
                defaultOutput: defaultOutputID(), lidClosed: isLidClosed())
    }

    /// The choice itself, free of any hardware so it can be tested:
    ///
    /// 1. The mic the user picked, when it's connected and can hear.
    /// 2. Otherwise the System Settings input ("Automatic").
    /// 3. Otherwise the best other real microphone — the headset they're
    ///    listening on first, then wired, then wireless, then the iPhone.
    ///
    /// The built-in mic never counts as able to hear while the lid is closed.
    /// Nor, for Automatic, does a virtual or aggregate system input then: with
    /// the built-in mic dark, that is macOS falling back to a loopback like
    /// BlackHole (or a virtual mic wrapping the dead one), which would record
    /// silence. Picked by hand, either is still used.
    static func resolve(preferredUID: String?, preferredName: String?,
                        devices: [AudioInputDevice], defaultInput: AudioDeviceID?,
                        defaultOutput: AudioDeviceID?, lidClosed: Bool) -> AudioInputResolution {
        func usable(_ device: AudioInputDevice) -> Bool { !(lidClosed && device.isInternalMic) }
        func automatic(_ device: AudioInputDevice) -> Bool {
            usable(device) && (!lidClosed || device.isAutomaticCandidate)
        }
        var fallback: AudioInputResolution.Fallback?

        if let preferredUID {
            if let chosen = devices.first(where: { $0.uid == preferredUID }) {
                if usable(chosen) { return AudioInputResolution(device: chosen, fallback: nil) }
                fallback = .lidClosed
            } else {
                fallback = .missing(preferredName ?? "The selected microphone")
            }
        }

        if let system = devices.first(where: { $0.id == defaultInput }) {
            if automatic(system) { return AudioInputResolution(device: system, fallback: fallback) }
            if fallback == nil { fallback = .lidClosed }
        }

        let best = devices.enumerated()
            .filter { automatic($0.element) && $0.element.isAutomaticCandidate }
            .min { a, b in
                let rankA = a.element.id == defaultOutput ? -1 : a.element.fallbackRank
                let rankB = b.element.id == defaultOutput ? -1 : b.element.fallbackRank
                return rankA != rankB ? rankA < rankB : a.offset < b.offset
            }?.element
        if let best { return AudioInputResolution(device: best, fallback: fallback) }

        return AudioInputResolution(device: nil, fallback: lidClosed ? .lidClosed : fallback)
    }

    /// Whether a capture already running on `device` can keep going.
    static func canKeepUsing(_ device: AudioInputDevice) -> Bool {
        let present = devices().contains { $0.uid == device.uid }
        return present && !(device.isInternalMic && isLidClosed())
    }

    // MARK: Routing

    /// A fresh engine whose input node listens to `device`. Only this app's
    /// capture moves — System Settings and every other app keep their input.
    ///
    /// The system input needs no routing, and is left alone: pointing the
    /// input unit at a device makes AVAudioEngine re-read that device's format
    /// a moment after `start()`, and it stops itself when the channel count or
    /// rate differ — even for the device it was already on. Captures recover
    /// with `resume(_:on:)`.
    ///
    /// Install taps with `format: nil`: once routed, the node's hardware
    /// format is the device's (two channels for many interfaces) while its
    /// output bus stays the client format, and a tap that names the wrong one
    /// raises an Objective-C exception Swift cannot catch.
    static func makeEngine(for device: AudioInputDevice) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        if device.id != defaultInputID() {
            guard let unit = engine.inputNode.audioUnit else {
                throw InputError.openFailed(name: device.name, status: kAudioUnitErr_Uninitialized)
            }
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw InputError.openFailed(name: device.name, status: status) }
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw InputError.openFailed(name: device.name, status: kAudioUnitErr_FormatNotSupported)
        }
        return engine
    }

    /// After a configuration change: whether `engine` still captures from
    /// `device`, restarting it in place when it stopped itself but nothing
    /// else changed — the tap survives, so a few dozen milliseconds are lost
    /// rather than the recording. False means the caller has to reopen: the
    /// device went away, the lid closed on it, or an unrouted engine followed
    /// the system input somewhere else.
    static func resume(_ engine: AVAudioEngine, on device: AudioInputDevice) -> Bool {
        // A routed engine's unit names the device; an unrouted one names a
        // private aggregate AVAudioEngine builds over the system input, so it
        // hears `device` exactly while that is still the system input.
        let listening = currentDevice(of: engine) == device.id || defaultInputID() == device.id
        guard listening, canKeepUsing(device) else { return false }
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// The device an engine's input unit is set to — for an engine that was
    /// never routed, AVAudioEngine's private aggregate, not the mic itself.
    static func currentDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &id, &size) == noErr else { return nil }
        return id
    }

    // MARK: Property plumbing

    private static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), selector),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = propertyAddress(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func kind(forTransport transport: UInt32) -> AudioInputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless,
             fourCharCode("ccap"):
            return .iPhone
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeAVB:
            return .interface
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return .aggregate
        default:
            return .other
        }
    }

    /// The built-in device is the internal mic unless its data source says
    /// otherwise — a headset in the jack reports 'emic' and keeps working
    /// with the lid closed.
    private static func isInternalMic(_ id: AudioDeviceID, transport: UInt32, name: String, uid: String) -> Bool {
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        if let source = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeInput) {
            return source == fourCharCode("imic")
        }
        let label = (name + " " + uid).lowercased()
        return !(label.contains("external") || label.contains("headset") || label.contains("line in"))
    }

    private static func fourCharCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

extension Notification.Name {
    /// A microphone was connected or removed, the system default input moved,
    /// or the lid opened or closed. Posted on the main queue.
    static let audioInputsChanged = Notification.Name("NotchWhisper.audioInputsChanged")
}

// MARK: - Live device list

/// The connected microphones, the system default and the lid, kept current
/// for the pickers and for captures that need to move when a mic goes away.
@MainActor
final class AudioInputManager: ObservableObject {
    static let shared = AudioInputManager()

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultInputID: AudioDeviceID?
    @Published private(set) var defaultOutputID: AudioDeviceID?
    @Published private(set) var lidClosed = false

    private init() {
        refresh()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultInputDevice)
        listen(kAudioHardwarePropertyDefaultOutputDevice)
        // Closing the lid in clamshell mode takes the built-in display away,
        // so a display change is when the lid state is worth reading again.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterDisplayChange() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterDisplayChange() }
        }
    }

    /// What the next capture will open for these settings.
    func resolution(for settings: Settings) -> AudioInputResolution {
        resolution(preferredUID: settings.inputDeviceUID, preferredName: settings.inputDeviceName)
    }

    /// What "Automatic" means right now, whatever is selected.
    var automaticResolution: AudioInputResolution {
        resolution(preferredUID: nil, preferredName: nil)
    }

    func refresh() {
        let devices = AudioInputs.devices()
        let input = AudioInputs.defaultInputID()
        let output = AudioInputs.defaultOutputID()
        let lid = AudioInputs.isLidClosed()
        guard devices != self.devices || input != defaultInputID
                || output != defaultOutputID || lid != lidClosed else { return }
        self.devices = devices
        defaultInputID = input
        defaultOutputID = output
        lidClosed = lid
        NotificationCenter.default.post(name: .audioInputsChanged, object: nil)
    }

    private func resolution(preferredUID: String?, preferredName: String?) -> AudioInputResolution {
        AudioInputs.resolve(preferredUID: preferredUID, preferredName: preferredName,
                            devices: devices, defaultInput: defaultInputID,
                            defaultOutput: defaultOutputID, lidClosed: lidClosed)
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The lid state can land a moment after the displays reconfigure, so
    /// read it again once things settle.
    private func refreshAfterDisplayChange() {
        refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refresh()
        }
    }
}

// MARK: - Microphone test

/// Settings' level meter: opens the microphone dictation would use, on its
/// own engine, so the user can see it hears them before relying on it. Stops
/// itself after 20 seconds.
@MainActor
final class MicrophoneTester: ObservableObject {
    @Published private(set) var isRunning = false
    /// 0…1, the same scale as the notch meter.
    @Published private(set) var level: Float = 0
    @Published private(set) var deviceName = ""
    @Published private(set) var error: String?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var timeout: Task<Void, Never>?

    func start(settings: Settings) {
        stop()
        let resolution = AudioInputs.resolve(preferredUID: settings.inputDeviceUID,
                                             preferredName: settings.inputDeviceName)
        guard let device = resolution.device else {
            error = resolution.message
            return
        }
        do {
            let engine = try AudioInputs.makeEngine(for: device)
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil,
                                        block: Self.meterTap { [weak self] value in
                Task { @MainActor in self?.show(value) }
            })
            engine.prepare()
            try engine.start()
            self.engine = engine
            deviceName = device.name
            error = nil
            isRunning = true
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let engine = self.engine, !AudioInputs.resume(engine, on: device) else { return }
                    self.stop()
                    self.error = "\(device.name) stopped responding."
                }
            }
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    /// Peak-hold with a quick release, so speech reads as a steady bar.
    private func show(_ value: Float) {
        guard isRunning else { return }
        level = max(value, level * 0.82)
    }

    /// Built outside the main actor: the tap runs on Core Audio's thread.
    nonisolated private static func meterTap(_ report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += channel[0][i] * channel[0][i] }
            report(min(1, (sum / Float(count)).squareRoot() * 7))
        }
    }
}

// MARK: - Conversion

/// Any input format → mono float at `sampleRate`. The converter is rebuilt
/// when the format changes (a routed device, a Bluetooth mic renegotiating).
/// Used only from one tap thread at a time.
final class MonoResampler: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(sampleRate: Double) {
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let input = buffer.format
        if converter == nil || converter?.inputFormat != input {
            converter = AVAudioConverter(from: input, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = target.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        // Hand the buffer over exactly once. Answering every request with the
        // same buffer makes the converter read part of it twice.
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
