import Foundation
import AVFoundation
import Speech

/// Apple's on-device speech model (`SpeechTranscriber` / `SpeechAnalyzer`,
/// macOS 26+) as a model the app can select.
///
/// There is one model id for it: the language comes from the app's language
/// setting, not from the model, because Apple ships the recognizer per locale
/// and macOS manages those assets itself. English and whatever else the system
/// already uses for dictation are usually present; other locales download on
/// demand through `AssetInventory`.
enum AppleSpeechModel {
    static let id = "apple:speech"
    static let prefix = "apple:"
    static func isAppleId(_ modelId: String) -> Bool { modelId.hasPrefix(prefix) }
    static let displayName = "Apple Speech"
}

/// What this Mac's copy of macOS supports, cached so synchronous UI code
/// (descriptors, compatibility) can read it.
@MainActor
enum AppleSpeechSupport {
    /// SpeechTranscriber needs macOS 26 and hardware Apple supports it on.
    nonisolated static var isAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Language codes the recognizer supports here. Starts from the list macOS
    /// 27 reports and is replaced by the real one after `refresh()`.
    private(set) static var languages: [String] = [
        "bn", "de", "en", "es", "fr", "gu", "hi", "it", "ja", "kn", "ko", "ks", "mai",
        "ml", "mr", "ne", "or", "pa", "pt", "ta", "te", "ur", "yue", "zh",
    ]
    private(set) static var didRefresh = false

    static func refresh() async {
        guard #available(macOS 26, *), isAvailable else { return }
        let locales = await SpeechTranscriber.supportedLocales
        let codes = Set(locales.compactMap { $0.language.languageCode?.identifier })
            .subtracting(["mul"])
        if !codes.isEmpty { languages = codes.sorted() }
        didRefresh = true
    }
}

/// Apple Speech as a transcription engine — the fourth one.
///
/// Every decode builds a fresh `SpeechAnalyzer` session over the samples it is
/// given; the models behind it stay resident (`processLifetime` retention), so
/// only the first session pays for loading them.
@MainActor
final class AppleSpeechASR {
    private(set) var loadedModelId: String?
    /// The locale the loaded session transcribes, e.g. en_US.
    private(set) var locale: Locale?

    enum EngineError: LocalizedError {
        case unavailable
        case unsupportedLanguage(String)
        case notLoaded
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Speech needs macOS 26 or later on a Mac that supports it."
            case .unsupportedLanguage(let name):
                return "Apple Speech doesn't support \(name). Pick another language, or a Whisper or Parakeet model."
            case .notLoaded:
                return "Apple Speech isn't loaded."
            case .noAudioFormat:
                return "Apple Speech couldn't agree on an audio format for this language."
            }
        }
    }

    // MARK: - Locales and assets

    /// The supported locale for a language code (nil/"auto" = the system's
    /// language). Apple's recognizer can't detect the language by itself.
    static func resolveLocale(_ languageCode: String?) async throws -> Locale {
        guard #available(macOS 26, *), AppleSpeechSupport.isAvailable else { throw EngineError.unavailable }
        let code = languageCode?.trimmingCharacters(in: .whitespaces).lowercased()
        let requested: Locale = (code == nil || code == "" || code == "auto")
            ? Locale.current
            : Locale(identifier: code!)
        if let exact = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return exact
        }
        // A bare language ("de") may not map on its own: prefer the user's
        // region, then any supported region for that language.
        let language = requested.language.languageCode?.identifier ?? code ?? ""
        let candidates = await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode?.identifier == language }
        if let region = Locale.current.region,
           let match = candidates.first(where: { $0.region == region }) {
            return match
        }
        if let first = candidates.sorted(by: { $0.identifier < $1.identifier }).first {
            return first
        }
        throw EngineError.unsupportedLanguage(ModelCapabilities.languageName(language))
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        guard #available(macOS 26, *) else { return false }
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }

    /// Whether the recognizer for `languageCode` is ready without a download.
    static func isReady(languageCode: String?) async -> Bool {
        guard let locale = try? await resolveLocale(languageCode) else { return false }
        return await isInstalled(locale)
    }

    /// Download and install the recognizer assets for a locale, if macOS
    /// doesn't have them yet. The system owns the files; nothing lands in the
    /// app's model folder.
    static func install(_ locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { throw EngineError.unavailable }
        if await isInstalled(locale) { onProgress(1); return }
        await reserve(locale)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            onProgress(1)
            return
        }
        let progress = request.progress
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
        onProgress(1)
    }

    /// An app may hold only a few locale reservations at once. Make room by
    /// releasing the oldest one that isn't the locale being installed.
    @available(macOS 26, *)
    private static func reserve(_ locale: Locale) async {
        let wanted = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales,
           let evict = reserved.first(where: { $0.identifier(.bcp47) != wanted }) {
            await AssetInventory.release(reservedLocale: evict)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Load

    /// "Loading" resolves the locale and makes sure its assets are present,
    /// downloading them through the system when they aren't.
    func load(modelId: String, languageCode: String?,
              onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let resolved = try await Self.resolveLocale(languageCode)
        try await Self.install(resolved, onProgress: onProgress)
        locale = resolved
        loadedModelId = modelId
    }

    func unload() {
        loadedModelId = nil
        locale = nil
    }

    // MARK: - Transcribe

    /// Transcribe 16 kHz mono samples. Segments are sentence-sized groups of
    /// Apple's word timings, relative to the start of `samples`. `contextualStrings` (the
    /// dictionary) biases recognition toward those terms.
    func transcribe(
        _ samples: [Float],
        contextualStrings: [String] = [],
        splitAt: Double? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (text: String, segments: [EngineSegment]) {
        guard #available(macOS 26, *) else { throw EngineError.unavailable }
        guard let locale else { throw EngineError.notLoaded }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let terms = contextualStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(terms.prefix(100))
            // A locale whose model takes no context is still worth running.
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }

        let totalSeconds = Double(samples.count) / 16_000
        // Each result is a phrase whose words are runs carrying their own time
        // range. Words, not phrases, go to the segmenter: a phrase can straddle
        // the live loop's typed boundary, a word almost never does.
        let collector = Task { () -> (texts: [String], tokens: [(text: String, start: Double, end: Double)]) in
            var texts: [String] = []
            var tokens: [(text: String, start: Double, end: Double)] = []
            for try await result in transcriber.results {
                let phrase = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                texts.append(phrase)
                var first = true
                for run in result.text.runs {
                    var word = String(result.text[run.range].characters)
                    // A phrase's first word has no leading space; it is still
                    // the start of a word.
                    if first, !word.hasPrefix(" ") { word = " " + word }
                    first = false
                    if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                        tokens.append((word, range.start.seconds, range.end.seconds))
                    } else if !tokens.isEmpty {
                        tokens[tokens.count - 1].text += word
                    }
                }
                let end = result.range.end.seconds
                if totalSeconds > 0, end.isFinite { onProgress(min(1, end / totalSeconds)) }
            }
            return (texts, tokens)
        }
        // A cancel from the Upload page has to reach a session that may be
        // deep in analysis, so it is polled rather than checked once.
        let canceller = Task {
            while !Task.isCancelled {
                if isCancelled() { await analyzer.cancelAndFinishNow(); return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { canceller.cancel() }

        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: inputs)
            for buffer in try Self.buffers(from: samples, to: format) {
                feed.yield(AnalyzerInput(buffer: buffer))
            }
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            feed.finish()
            collector.cancel()
            if isCancelled() { throw CancellationError() }
            throw error
        }
        let collected = try await collector.value
        if isCancelled() { throw CancellationError() }
        let text = collected.texts.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = EngineSegment.group(collected.tokens, splitAt: splitAt)
        // No word timings (an attribute the recognizer didn't fill): one span.
        if segments.isEmpty, !text.isEmpty {
            segments = [EngineSegment(start: 0, end: totalSeconds, text: text)]
        }
        return (text, segments)
    }

    // MARK: - Audio

    /// 16 kHz mono Float32 samples, converted to the analyzer's format in
    /// one-second buffers. The converter carries state across buffers, so it is
    /// drained at the end rather than reset per buffer.
    private static func buffers(from samples: [Float], to target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else { return [] }
        let chunk = 16_000
        var inputs: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            inputs.append(buffer)
            offset += count
        }
        if target == source { return inputs }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw EngineError.noAudioFormat
        }
        let ratio = target.sampleRate / source.sampleRate
        var outputs: [AVAudioPCMBuffer] = []
        var index = 0
        var finished = false
        while !finished {
            let capacity = AVAudioFrameCount(Double(chunk) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if index < inputs.count {
                    inputStatus.pointee = .haveData
                    defer { index += 1 }
                    return inputs[index]
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if out.frameLength > 0 { outputs.append(out) }
            finished = status == .endOfStream || status == .error
                || (index >= inputs.count && out.frameLength == 0)
        }
        return outputs
    }
}
