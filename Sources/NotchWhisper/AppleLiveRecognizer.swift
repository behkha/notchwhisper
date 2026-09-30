import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Apple Speech, streaming — one `SpeechAnalyzer` session for the whole
/// dictation, fed as the microphone captures.
///
/// This is the recognizer Apple built for live captions, and it already works
/// in the two tiers live dictation needs: volatile results, its running guess
/// at the speech in progress, and final results, which it never revises. Its
/// guesses use everything heard so far in the session, so a word misheard
/// mid-sentence is corrected once the rest of the sentence arrives — and the
/// final text is as accurate as transcribing the recording afterwards
/// (measured on the Harvard sentences: identical, word for word).
///
/// `fastResults` makes it publish a guess about once a second instead of
/// about every four; the final text does not change with it.
@available(macOS 26, *)
@MainActor
final class AppleLiveRecognizer: LiveRecognizer {
    private let locale: Locale
    private let contextualStrings: [String]

    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var samplesFed = 0
    /// Set when the results stream has ended — Apple ends it once the session
    /// has published everything.
    private var resultsEnded = false

    private(set) var finalWords: [LiveWord] = []
    private(set) var volatileWords: [LiveWord] = []
    /// Apple's guesses are already steady enough to type as they come.
    var settledWords: [LiveWord] { volatileWords }
    var onUpdate: (() -> Void)?
    var tickSeconds: Double { 0.1 }
    var meanDecodeSeconds: Double? { nil }

    init(locale: Locale, contextualStrings: [String]) {
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
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
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleSpeechASR.EngineError.noAudioFormat
        }
        targetFormat = format
        converter = format == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: format)

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                fputs("NotchWhisper[live]: Apple Speech results ended: \(error)\n", stderr)
            }
            self?.resultsEnded = true
        }
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            // Nothing will end the results stream now: release it here.
            feed.finish()
            self.feed = nil
            resultsTask?.cancel()
            resultsTask = nil
            throw error
        }
        self.analyzer = analyzer
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty, let feed, let targetFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        samplesFed += samples.count
        guard let converter else {
            feed.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64)
        else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            fputs("NotchWhisper[live]: audio conversion failed: \(error)\n", stderr)
            return
        }
        if out.frameLength > 0 { feed.yield(AnalyzerInput(buffer: out)) }
    }

    /// Apple's session does its own scheduling; results arrive on their own.
    func process() async {}

    func finish() async {
        feed?.finish()
        feed = nil
        if let analyzer {
            Task {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    fputs("NotchWhisper[live]: Apple Speech finish failed: \(error)\n", stderr)
                }
            }
            // The results stream ends once the session has published
            // everything — normally within a fraction of a second. A session
            // that hangs must not hold the dictation open: the app cannot
            // start another until this one is done.
            let deadline = Date().addingTimeInterval(6)
            while !resultsEnded, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if !resultsEnded {
                fputs("NotchWhisper[live]: Apple Speech did not finish in time — ending it\n", stderr)
                resultsTask?.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        resultsTask = nil
        analyzer = nil
        if !volatileWords.isEmpty {
            volatileWords = []
            onUpdate?()
        }
    }

    func cancel() {
        feed?.finish()
        feed = nil
        resultsTask?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result) {
        if RedecodeLiveRecognizer.debugLog {
            let words = Self.words(in: result).map {
                "\($0.text.trimmingCharacters(in: .whitespaces))@\(String(format: "%.2f", $0.start))"
            }
            fputs(String(format: "NotchWhisper[live]: apple %@ %.2f–%.2f: ", result.isFinal ? "FINAL" : "guess",
                         result.range.start.seconds, result.range.end.seconds)
                  + (result.isFinal ? words.joined(separator: " ") : String(result.text.characters)) + "\n", stderr)
        }
        if result.isFinal {
            let words = Self.words(in: result)
            finalWords.append(contentsOf: words)
            // Until the next guess arrives, keep the part of the previous one
            // that runs past this final text — clearing it would delete words
            // from the page for the moment in between.
            let guessed = volatileWords.flatMap { $0.text.split(separator: " ") }
            let finalCount = words.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let end = result.range.end.seconds
            if guessed.count > finalCount, end.isFinite {
                let rest = guessed.dropFirst(finalCount).joined(separator: " ")
                volatileWords = [LiveWord(text: " " + rest, start: end, end: end)]
            } else {
                volatileWords = []
            }
        } else {
            let text = String(result.text.characters)
            let start = result.range.start.seconds, end = result.range.end.seconds
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !start.isFinite {
                volatileWords = []
            } else {
                volatileWords = [LiveWord(text: text, start: start, end: end.isFinite ? end : start)]
            }
        }
        onUpdate?()
    }

    /// A final result's words, each timed by its own run.
    private static func words(in result: SpeechTranscriber.Result) -> [LiveWord] {
        var words: [LiveWord] = []
        let fallbackStart = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
        let fallbackEnd = result.range.end.seconds.isFinite ? result.range.end.seconds : fallbackStart
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            guard !text.isEmpty else { continue }
            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                words.append(LiveWord(text: text, start: range.start.seconds, end: range.end.seconds))
            } else if !words.isEmpty {
                words[words.count - 1].text += text
            } else {
                words.append(LiveWord(text: text, start: fallbackStart, end: fallbackEnd))
            }
        }
        return words
    }
}
