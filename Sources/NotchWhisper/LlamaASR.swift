import Foundation
import CLlama

/// Second transcription engine: runs a GGUF Qwen3-ASR model in-process through
/// llama.cpp's `mtmd` (multimodal) path — audio encoder + Qwen3 text decoder.
///
/// Used for **hold-to-talk (batch) dictation only**. Qwen3-ASR has no
/// timestamp / streaming API, so live dictation stays on WhisperKit
/// (`LiveTranscriber` needs per-segment timestamps for its confirmation logic).
///
/// All llama.cpp calls are serialized on `queue` — `llama_context` is not
/// thread-safe. The public API is `async` and hops back to the caller off that
/// queue; load/transcribe progress is reported on the MainActor via the same
/// `AppState` fields WhisperKit uses (`isLoadingModel`, `modelLoadProgress`, …).
final class LlamaASR: @unchecked Sendable {

    enum EngineError: LocalizedError {
        case modelLoadFailed
        case contextInitFailed
        case mmprojLoadFailed
        case audioUnsupported
        case notLoaded
        case tokenizeFailed(Int32)
        case evalFailed(Int32)
        case decodeFailed(Int32)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed:     return "Couldn't load the Qwen3-ASR model file."
            case .contextInitFailed:   return "Couldn't initialize the llama.cpp context."
            case .mmprojLoadFailed:     return "Couldn't load the Qwen3-ASR audio projector (mmproj)."
            case .audioUnsupported:     return "This model's projector has no audio encoder."
            case .notLoaded:            return "The Qwen3-ASR model isn't loaded."
            case .tokenizeFailed(let r):return "Prompt tokenization failed (mtmd code \(r))."
            case .evalFailed(let r):    return "Audio/prompt evaluation failed (code \(r))."
            case .decodeFailed(let r):  return "Token decoding failed (llama code \(r))."
            case .emptyResult:          return "The model produced no transcript."
            }
        }
    }

    // MARK: - Tuning

    /// Text context window. Audio is ~12.5 tokens/s for Qwen3-ASR, so an 80 s
    /// chunk ≈ 1000 audio tokens + prompt + output — well inside 8192.
    private let nCtx: UInt32 = 8192
    private let nBatch: UInt32 = 2048
    /// Longer clips are transcribed in non-overlapping chunks and concatenated.
    private let chunkSeconds: Double = 80
    private let sampleRate: Double = 16_000
    private let maxNewTokens = 640

    // MARK: - State (touch only on `queue`)

    private let queue = DispatchQueue(label: "com.behkha.notchwhisper.llama-asr", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var mctx: OpaquePointer?
    private(set) var loadedModelId: String?
    private static var backendInited = false

    // MARK: - Load

    /// Load `model.gguf` + `mmproj.gguf`. `progress` is called (off the main
    /// thread) with 0…1 and a phase label — callers hop to the MainActor
    /// themselves. Safe to call again for a different model (the previous one is
    /// torn down first).
    func load(
        modelId: String,
        modelPath: String,
        mmprojPath: String,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        progress(0.05, "Preparing Qwen3-ASR…")
        try await runOnQueue {
            try self.loadSync(
                modelId: modelId, modelPath: modelPath, mmprojPath: mmprojPath,
                threads: threads, progress: progress
            )
        }
        progress(1.0, "Ready")
    }

    private func loadSync(
        modelId: String,
        modelPath: String,
        mmprojPath: String,
        threads: Int,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        if !Self.backendInited {
            llama_backend_init()
            Self.silenceLogs()
            Self.backendInited = true
        }
        teardownSync()

        progress(0.10, "Loading Qwen3-ASR weights…")

        // Model — with a load-progress callback.
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999   // offload everything to Metal on Apple Silicon
        let progressBox = Unmanaged.passRetained(CallbackBox { frac in
            // 10 % … 60 % of the bar is the weight load.
            progress(0.10 + 0.50 * Double(frac), "Loading Qwen3-ASR weights…")
            return true
        })
        defer { progressBox.release() }
        mparams.progress_callback = { frac, ud in
            guard let ud else { return true }
            return Unmanaged<CallbackBox>.fromOpaque(ud).takeUnretainedValue().onProgress(frac)
        }
        mparams.progress_callback_user_data = progressBox.toOpaque()

        guard let m = modelPath.withCString({ llama_model_load_from_file($0, mparams) }) else {
            throw EngineError.modelLoadFailed
        }
        self.model = m

        progress(0.65, "Starting llama.cpp context…")
        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        cparams.n_batch = nBatch
        cparams.n_ubatch = nBatch
        cparams.n_threads = Int32(threads)
        cparams.n_threads_batch = Int32(threads)
        guard let c = llama_init_from_model(m, cparams) else {
            throw EngineError.contextInitFailed
        }
        self.ctx = c

        progress(0.80, "Loading audio encoder…")
        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = true
        mtmdParams.print_timings = false
        mtmdParams.n_threads = Int32(threads)
        mtmdParams.media_marker = mtmd_default_marker()
        guard let mc = mmprojPath.withCString({ mtmd_init_from_file($0, m, mtmdParams) }) else {
            throw EngineError.mmprojLoadFailed
        }
        self.mctx = mc

        guard mtmd_support_audio(mc) else {
            throw EngineError.audioUnsupported
        }

        self.loadedModelId = modelId
        progress(0.98, "Almost ready…")
    }

    var isLoaded: Bool { queue.sync { ctx != nil && mctx != nil } }

    // MARK: - Transcribe

    /// Transcribe `samples` (16 kHz mono). `context` is optional biasing text
    /// (dictionary terms, a language hint) placed in the system turn — Qwen3-ASR
    /// is trained to use it as hotword / context guidance.
    ///
    /// `isCancelled` / `onProgress` are for long imported files: progress is
    /// reported per 80 s chunk and a cancel is honoured between chunks. Both
    /// run on the engine queue, not the MainActor.
    func transcribe(
        _ samples: [Float],
        context: String,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        try await runOnQueue {
            try self.transcribeSync(
                samples, context: context, isCancelled: isCancelled, onProgress: onProgress
            )
        }
    }

    private func transcribeSync(
        _ samples: [Float],
        context: String,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> String {
        guard let ctx, let mctx, let model else { throw EngineError.notLoaded }
        let vocab = llama_model_get_vocab(model)

        let chunkSize = Int(chunkSeconds * sampleRate)
        let chunks: [[Float]]
        if samples.count <= chunkSize {
            chunks = [samples]
        } else {
            chunks = stride(from: 0, to: samples.count, by: chunkSize).map {
                Array(samples[$0 ..< min($0 + chunkSize, samples.count)])
            }
        }

        var pieces: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if isCancelled() { throw CancellationError() }
            // Fresh KV per chunk (each is an independent utterance segment).
            llama_memory_clear(llama_get_memory(ctx), true)

            let prompt = Self.buildPrompt(context: context)
            let bitmap = chunk.withUnsafeBufferPointer {
                mtmd_bitmap_init_from_audio($0.count, $0.baseAddress)
            }
            guard let bitmap else { throw EngineError.tokenizeFailed(-1) }
            defer { mtmd_bitmap_free(bitmap) }

            guard let inputChunks = mtmd_input_chunks_init() else {
                throw EngineError.tokenizeFailed(-2)
            }
            defer { mtmd_input_chunks_free(inputChunks) }

            let tokRes: Int32 = prompt.withCString { cPrompt in
                var text = mtmd_input_text(
                    text: cPrompt,
                    text_len: strlen(cPrompt),
                    add_special: false,      // Qwen tokenizer adds no BOS
                    parse_special: true
                )
                var bmp: [OpaquePointer?] = [bitmap]
                return bmp.withUnsafeMutableBufferPointer { bp in
                    mtmd_tokenize(mctx, inputChunks, &text, bp.baseAddress, bp.count)
                }
            }
            guard tokRes == 0 else { throw EngineError.tokenizeFailed(tokRes) }

            // Prefill: eval each chunk in order — text chunks directly, media
            // chunks through the batch-encode path (mirrors llama-mtmd-cli).
            var nPast: llama_pos = 0
            let nChunks = mtmd_input_chunks_size(inputChunks)
            for i in 0 ..< nChunks {
                guard let ch = mtmd_input_chunks_get(inputChunks, i) else { continue }
                let isLast = (i == nChunks - 1)
                let type = mtmd_input_chunk_get_type(ch)
                var newPast = nPast
                let r: Int32
                if type == MTMD_INPUT_CHUNK_TYPE_TEXT {
                    r = mtmd_helper_eval_chunk_single(
                        mctx, ctx, ch, nPast, 0, Int32(nBatch), isLast, &newPast
                    )
                } else {
                    guard let mb = mtmd_batch_init(mctx) else { throw EngineError.evalFailed(-10) }
                    defer { mtmd_batch_free(mb) }
                    var rr = mtmd_batch_add_chunk(mb, ch)
                    if rr == 0 { rr = mtmd_batch_encode(mb) }
                    guard rr == 0, let embd = mtmd_batch_get_output_embd(mb, ch) else {
                        throw EngineError.evalFailed(rr == 0 ? -11 : rr)
                    }
                    r = mtmd_helper_decode_image_chunk(
                        mctx, ctx, ch, embd, nPast, 0, Int32(nBatch), &newPast, nil, nil
                    )
                }
                guard r == 0 else { throw EngineError.evalFailed(r) }
                nPast = newPast
            }

            // Generation loop (greedy).
            let sampler = Self.makeGreedySampler()
            defer { llama_sampler_free(sampler) }

            var out: [llama_token] = []
            var batch = llama_batch_init(1, 0, 1)
            defer { llama_batch_free(batch) }

            for _ in 0 ..< maxNewTokens {
                if isCancelled() { throw CancellationError() }
                let tok = llama_sampler_sample(sampler, ctx, -1)
                llama_sampler_accept(sampler, tok)
                if llama_vocab_is_eog(vocab, tok) { break }
                out.append(tok)

                batch.n_tokens = 1
                batch.token[0] = tok
                batch.pos[0] = nPast
                batch.n_seq_id[0] = 1
                batch.seq_id[0]![0] = 0
                batch.logits[0] = 1
                nPast += 1
                let dr = llama_decode(ctx, batch)
                if dr != 0 { throw EngineError.decodeFailed(dr) }
            }

            pieces.append(Self.cleanOutput(Self.detokenize(out, vocab: vocab)))
            onProgress(Double(index + 1) / Double(chunks.count))
        }

        let text = pieces
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError.emptyResult }
        return text
    }

    /// Qwen3-ASR emits `language <lang><asr_text><transcript>` (and sometimes a
    /// trailing `<|im_end|>`). Keep only the transcript.
    static func cleanOutput(_ raw: String) -> String {
        var s = raw
        if let r = s.range(of: "<asr_text>") {
            s = String(s[r.upperBound...])
        } else if let r = s.range(of: #"^\s*language\s+\S+\s*"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        for marker in ["<|im_end|>", "<|endoftext|>", "<asr_text>", "<asr_label>"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Teardown

    func unload() { queue.sync { teardownSync() } }

    private func teardownSync() {
        if let mctx { mtmd_free(mctx); self.mctx = nil }
        if let ctx { llama_free(ctx); self.ctx = nil }
        if let model { llama_model_free(model); self.model = nil }
        loadedModelId = nil
    }

    /// Call once on app termination.
    func shutdown() {
        queue.sync {
            teardownSync()
            if Self.backendInited { llama_backend_free(); Self.backendInited = false }
        }
    }

    // MARK: - Helpers

    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Qwen3-ASR chatml prompt. mtmd replaces `<__media__>` with the encoded
    /// audio wrapped in the model's `<|audio_start|>…<|audio_end|>` tokens.
    static func buildPrompt(context: String) -> String {
        let system = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = String(cString: mtmd_default_marker())
        return """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(marker)<|im_end|>
        <|im_start|>assistant

        """
    }

    private static func makeGreedySampler() -> UnsafeMutablePointer<llama_sampler> {
        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        let chain = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }

    private static func detokenize(_ tokens: [llama_token], vocab: OpaquePointer?) -> String {
        guard !tokens.isEmpty else { return "" }
        var buf = [CChar](repeating: 0, count: max(256, tokens.count * 8))
        var n = tokens.withUnsafeBufferPointer {
            llama_detokenize(vocab, $0.baseAddress, Int32($0.count),
                             &buf, Int32(buf.count),
                             /* remove_special */ false, /* unparse_special */ false)
        }
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n) + 1)
            n = tokens.withUnsafeBufferPointer {
                llama_detokenize(vocab, $0.baseAddress, Int32($0.count),
                                 &buf, Int32(buf.count), false, false)
            }
        }
        guard n > 0 else { return "" }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func silenceLogs() {
        let sink: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            fputs(String(cString: text), stderr)
        }
        llama_log_set(sink, nil)
        ggml_log_set(sink, nil)
        mtmd_log_set(sink, nil)
    }

    /// Boxes a Swift closure so it can ride through a C `void *user_data`.
    private final class CallbackBox {
        let onProgress: (Float) -> Bool
        init(_ onProgress: @escaping (Float) -> Bool) { self.onProgress = onProgress }
    }
}
