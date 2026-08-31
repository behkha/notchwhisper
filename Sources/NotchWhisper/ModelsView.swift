import SwiftUI
import WhisperKit

/// Models browser — the single place to manage models (merges the old grid
/// and the former "Find Models" tab):
///
///   1. BUILT-IN section: the argmaxinc/whisperkit-coreml catalog as cards
///      with accuracy/speed guidance, each opening a detail page.
///   2. SEARCH HUGGING FACE section: live HF search (server-side filtered to
///      automatic-speech-recognition + CoreML, so only voice-to-text-usable
///      models appear). Expanding a repo lists its downloadable folders with
///      EXACT sizes, downloads, likes, license and dates straight from the
///      HF API. Downloading adds the model to the same list as built-ins
///      (id = "<repoId>:<folder>").
struct ModelsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var catalog = ModelCatalog.shared

    @State private var selected: WhisperModelOption?
    @State private var onlyCompatible = false

    private let hw = HardwareInfo.current

    /// Catalog ordered best-fit-for-this-Mac first, then by accuracy.
    private var orderedModels: [WhisperModelOption] {
        let list = onlyCompatible
            ? WhisperModelOption.all.filter { $0.fit(on: hw) >= .tight }
            : WhisperModelOption.all
        return list.sorted { a, b in
            let fa = a.fit(on: hw), fb = b.fit(on: hw)
            if fa != fb { return fa > fb }
            return a.englishWERValue < b.englishWERValue
        }
    }

    var body: some View {
        if let model = selected {
            ModelDetailView(model: model, onBack: { selected = nil })
                .environmentObject(state)
                .environmentObject(settings)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.x6) {
                    SectionHeader("Models", eyebrow: "on-device · private",
                                  subtitle: "Whisper models run entirely on your Mac. Nothing is uploaded.")

                    hardwareBanner

                    if state.isLoadingModel { ModelLoadBar() }

                    HFSearchSection(onUse: { selected = $0 })

                    VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                        Text("BUILT-IN CATALOG")
                            .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                            .foregroundStyle(Tokens.Color.textTert)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: Tokens.Space.x4)],
                            spacing: Tokens.Space.x4
                        ) {
                            ForEach(orderedModels) { m in
                                Button { selected = m } label: {
                                    ModelCard(model: m, isActive: settings.modelId == m.id, hw: hw)
                                }
                                .buttonStyle(Pressable(scale: 0.985))
                            }
                        }
                    }

                    if hw.isAppleSilicon {
                        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
                            Text("QWEN3-ASR · LLAMA.CPP")
                                .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                                .foregroundStyle(Tokens.Color.textTert)
                            Text("Qwen's multilingual speech model, run on the Metal GPU via llama.cpp. Hold-to-talk only — live dictation uses Whisper.")
                                .font(Tokens.TypeScale.caption)
                                .foregroundStyle(Tokens.Color.textSec)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: Tokens.Space.x4)],
                                spacing: Tokens.Space.x4
                            ) {
                                ForEach(LlamaModelOption.all) { m in
                                    LlamaModelCard(model: m, hw: hw)
                                }
                            }
                        }
                    }
                }
                .padding(Tokens.Space.x8)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onAppear { catalog.refreshIfNeeded() }
        }
    }

    /// This-Mac summary + a filter for models that actually fit it (req 4).
    private var hardwareBanner: some View {
        HStack(spacing: Tokens.Space.x3) {
            IconTile(hw.isAppleSilicon ? "memorychip.fill" : "cpu")
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Mac")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
                Text(hw.summary)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.text)
            }
            Spacer()
            Toggle("Fits this Mac", isOn: $onlyCompatible)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
        }
        .padding(Tokens.Space.x4)
        .card(padding: nil, elevated: false)
    }
}

// MARK: - HF search section (the merged "Find Models")

/// Live Hugging Face search embedded at the top of the Models page. Only
/// automatic-speech-recognition CoreML repos are returned by the API (the
/// filter is server-side), and every repo expands to its downloadable model
/// folders with exact sizes + full repo metadata from HF.
struct HFSearchSection: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    /// Lets a downloaded custom model open the (enriched) detail page.
    var onUse: (WhisperModelOption) -> Void

    @State private var query = ""
    @State private var results: [HFModelSearch.Repo] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var expandedRepo: String?
    @State private var folders: [String: [HFModelSearch.FolderInfo]] = [:]   // repoId → folders
    @State private var loadingFolders = Set<String>()
    @State private var folderErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack {
                Text("SEARCH HUGGING FACE")
                    .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer()
                Text("any Whisper / CoreML speech model")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
            }

            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textTert)
                TextField("e.g. whisper, distil-whisper, <org>/<model>", text: $query)
                    .textFieldStyle(.plain)
                    .font(Tokens.TypeScale.body)
                    .onSubmit { Task { await runSearch() } }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await runSearch() }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 18))
                    }
                    .buttonStyle(Pressable())
                    .foregroundStyle(Tokens.Color.accent)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, Tokens.Space.x3)
            .padding(.vertical, 9)
            .background(Tokens.Color.fillQuiet, in: Capsule())
            .overlay(Capsule().strokeBorder(Tokens.Color.hairline, lineWidth: 1))

            if let err = searchError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.danger)
            }

            if !results.isEmpty {
                Text("\(results.count) speech-recognition CoreML repos · press ⏎ to refresh")
                    .font(Tokens.TypeScale.micro)
                    .foregroundStyle(Tokens.Color.textTert)
                LazyVStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    ForEach(results) { repo in
                        repoRow(repo)
                    }
                }
            }
        }
    }

    // MARK: Repo row (full HF metadata)

    @ViewBuilder
    private func repoRow(_ repo: HFModelSearch.Repo) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            Button {
                toggleExpand(repo)
            } label: {
                HStack(spacing: Tokens.Space.x2) {
                    Image(systemName: expandedRepo == repo.repoId ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .foregroundStyle(Tokens.Color.textTert)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.repoId)
                            .font(Tokens.TypeScale.headline)
                            .foregroundStyle(Tokens.Color.text)
                        // Full metadata line, straight from the HF API.
                        HStack(spacing: Tokens.Space.x2) {
                            Label("\(repo.downloads)", systemImage: "arrow.down.circle")
                            Label("\(repo.likes)", systemImage: "heart")
                            if !repo.lastModified.isEmpty { Text("· \(repo.lastModified)") }
                            if let lib = repo.library { Text("· \(lib)") }
                            if let lic = repo.license { Text("· \(lic)") }
                            if repo.isGated { Text("· gated").foregroundStyle(Tokens.Color.record) }
                        }
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                    }
                    Spacer()
                    Text("ASR · CoreML")
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.success)
                }
                .padding(Tokens.Space.x3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedRepo == repo.repoId {
                if loadingFolders.contains(repo.repoId) {
                    HStack { ProgressView().controlSize(.small); Text("Loading models…").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert) }
                        .padding(.leading, Tokens.Space.x4)
                } else if let err = folderErrors[repo.repoId] {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(Tokens.TypeScale.caption)
                        .foregroundStyle(Tokens.Color.danger)
                        .padding(.leading, Tokens.Space.x4)
                } else if let list = folders[repo.repoId] {
                    ForEach(list.filter { $0.hasWeights }) { f in
                        folderRow(repoId: repo.repoId, folder: f)
                    }
                    if list.filter({ $0.hasWeights }).isEmpty {
                        Text("No complete CoreML model folders in this repo (single-file or config-only repos can't be loaded).")
                            .font(Tokens.TypeScale.caption)
                            .foregroundStyle(Tokens.Color.textTert)
                            .padding(.leading, Tokens.Space.x4)
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Space.x2)
        // Liquid Glass row — tappable, so it gets the system's interactive
        // pointer response on macOS 26.
        .glassRow()
    }

    // MARK: Downloadable folder row inside an expanded repo

    @ViewBuilder
    private func folderRow(repoId: String, folder: HFModelSearch.FolderInfo) -> some View {
        let modelId = "\(repoId):\(folder.name)"
        let isDownloadingThis = state.downloadingModelId == modelId
        let isLocal = !isDownloadingThis
            && (AppDelegate.shared?.transcriberRef.hasLocalModelFolder(folder.name) ?? false)
        let isActive = settings.modelId == modelId

        HStack(spacing: Tokens.Space.x2) {
            Image(systemName: isActive ? "checkmark.circle.fill" : (isLocal ? "circle.circle" : "arrow.down.circle"))
                .foregroundStyle(isActive ? Tokens.Color.success : (isLocal ? Tokens.Color.textSec : Tokens.Color.accent))
            Text(folder.name)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.text)
            Text("· \(folder.sizeLabel)")                    // exact size from HF
                .font(Tokens.TypeScale.micro)
                .foregroundStyle(Tokens.Color.textTert)
            Spacer()
            if isActive {
                Text("ACTIVE").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.success)
            } else if isDownloadingThis {
                Text("Downloading… \(Int(state.displayProgress * 100))%")
                    .font(Tokens.TypeScale.captionSB)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.accent)
            } else if isLocal {
                Button("Use") {
                    settings.modelId = modelId
                    NotificationCenter.default.post(name: .modelChanged, object: nil)
                }
                .buttonStyle(.borderless)
                .font(Tokens.TypeScale.captionSB)
            } else {
                Button(state.isDownloading ? "…" : "Download") {
                    Task { await downloadRepoModel(repoId: repoId, folder: folder) }
                }
                .buttonStyle(.borderless)
                .font(Tokens.TypeScale.captionSB)
                .foregroundStyle(Tokens.Color.accent)
                .disabled(state.isDownloading)
            }
        }
        .padding(.horizontal, Tokens.Space.x4)
        .padding(.vertical, Tokens.Space.x1)
    }

    // MARK: Actions

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await HFModelSearch.search(q, limit: 30)
            if results.isEmpty { searchError = "No speech-recognition CoreML repos matched “\(q)”." }
        } catch {
            searchError = "Search failed: \(error.localizedDescription) — check your connection."
        }
    }

    private func toggleExpand(_ repo: HFModelSearch.Repo) {
        if expandedRepo == repo.repoId {
            expandedRepo = nil
            return
        }
        expandedRepo = repo.repoId
        if folders[repo.repoId] != nil { return }   // cached
        loadingFolders.insert(repo.repoId)
        Task {
            do {
                let list = try await HFModelSearch.listModelFolders(repoId: repo.repoId)
                folders[repo.repoId] = list
                loadingFolders.remove(repo.repoId)
            } catch {
                folderErrors[repo.repoId] = "Couldn't list models: \(error.localizedDescription)"
                loadingFolders.remove(repo.repoId)
            }
        }
    }

    private func downloadRepoModel(repoId: String, folder: HFModelSearch.FolderInfo) async {
        // WhisperKit's bareId convention: strip the publisher prefix so the
        // "*<variant>/*" glob resolves inside the custom repo.
        let variant = folder.name
            .replacingOccurrences(of: "openai_whisper-", with: "whisper-")
            .replacingOccurrences(of: "distil-whisper_", with: "distil-")
        let modelId = "\(repoId):\(folder.name)"
        let transcriber = AppDelegate.shared?.transcriberRef
        state.isDownloading = true
        state.downloadingModelId = modelId
        state.downloadProgress = 0
        state.downloadLabel = "Downloading \(folder.name)…"
        state.resetDownloadStats()
        // Byte-accurate stats sampled from disk. The total comes straight
        // from the HF API (FolderInfo.sizeBytes) so it is exact here.
        let base = transcriber?.modelDir
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NotchWhisper/Models")
        let repoRoot = base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
        let sampler = transcriber?.startDownloadStatsSampler(
            repoRoot: repoRoot,
            folder: folder.name,
            totalBytes: folder.sizeBytes
        )
        defer {
            sampler?.cancel()
            state.isDownloading = false
            state.downloadingModelId = nil
            state.downloadLabel = ""
        }
        do {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: transcriber?.modelDir,
                from: repoId,
                token: Keychain.getToken()
            ) { progress in
                let f = progress.fractionCompleted
                Task { @MainActor in
                    let p = AppState.shared.downloadProgress
                    if f > p { AppState.shared.downloadProgress = f }
                }
            }
            // Verify the weights actually landed before calling it done, then
            // activate + load it directly (parity with the built-in path — the
            // old code just told the user to go pick it manually).
            if transcriber?.hasLocalModelFolder(folder.name) == true {
                settings.modelId = modelId
                _ = await transcriber?.ensureLoaded(modelId: modelId)
                state.showToast("Downloaded and activated \(folder.name).")
            } else {
                state.showToast("Download finished but the model files look incomplete — try again.")
            }
        } catch {
            state.showToast("Download failed: \(error.localizedDescription)")
        }
    }
}

/// A single model card in the grid: name, size, accuracy & speed at a glance.
struct ModelCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var theme = Tokens.ThemeManager.shared
    @ObservedObject private var catalog = ModelCatalog.shared
    let model: WhisperModelOption
    let isActive: Bool
    var hw: HardwareInfo = .current

    var body: some View {
        let _ = theme.theme   // card accent re-tints on theme change
        let _ = catalog.sizeByFolder
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.display)
                            .font(Tokens.TypeScale.title2)
                            .foregroundStyle(Tokens.Color.text)
                        if isActive {
                            Text("ACTIVE")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.success)
                                .padding(.horizontal, Tokens.Space.x2)
                                .padding(.vertical, Tokens.Space.x1)
                                .background(Capsule().fill(Tokens.Color.success.opacity(0.16)))
                        } else if state.downloadingModelId == model.id {
                            Text("DOWNLOADING")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.accent)
                                .padding(.horizontal, Tokens.Space.x2)
                                .padding(.vertical, Tokens.Space.x1)
                                .background(Capsule().fill(Tokens.Color.accent.opacity(0.16)))
                        }
                    }
                    Text(model.quality)
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? Tokens.Color.success : Tokens.Color.textTert)
            }

            ModelFitBadge(fit: model.fit(on: hw))

            Text(model.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            // Decision tag (ChatGPT rec: lead with the verdict)
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.accent)
                Text(model.decision)
                    .font(Tokens.TypeScale.captionSB)
                    .foregroundStyle(Tokens.Color.accent)
                Spacer(minLength: 0)
            }

            // Accuracy + speed bars
            MetricBar(label: "Accuracy", value: model.accuracyFraction,
                      display: "WER \(model.englishWER)", tone: .good)
            MetricBar(label: "Speed", value: model.speedFraction,
                      display: model.speedLabel, tone: .accent)

            // Two-axis Accuracy <-> Speed marker + time estimate (ChatGPT rec)
            AxisMarker(accuracy: model.accuracyFraction, speed: model.speedFraction)
            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "timer")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.secPerMin)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }

            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(catalog.sizeLabel(for: model)).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Image(systemName: model.englishOnly ? "globe.americas" : "globe")
                    .font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.lang)
                    .font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }

            Divider().overlay(Tokens.Color.hairline)
            ModelAttribution(
                org: model.attribution.org, display: model.attribution.display,
                note: model.attribution.note, link: model.attribution.url,
                compact: true, showLink: false     // card is one big Button
            )
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Liquid Glass card — the system's own hover/press response and depth
        // replace the hand-drawn border + hover shadow. Interactive glass
        // degrades to a plain frosted panel on macOS 14/15.
        .glassSurface(interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
        // VoiceOver: one coherent element naming the model, not a pile of text.
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows model details")
    }
}

/// A card for a GGUF Qwen3-ASR model (llama.cpp engine). Simpler than
/// `ModelCard` — Qwen3-ASR has no per-model WER/speed table.
struct LlamaModelCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    let model: LlamaModelOption
    var hw: HardwareInfo = .current

    private var isActive: Bool { settings.modelId == model.id }
    private var isDownloadingThis: Bool { state.downloadingModelId == model.id }
    private var isLocal: Bool {
        !isDownloadingThis && GGUFDownloader.isDownloaded(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x3) {
            HStack(alignment: .top, spacing: Tokens.Space.x2) {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    HStack(spacing: Tokens.Space.x2) {
                        Text(model.display)
                            .font(Tokens.TypeScale.title2)
                            .foregroundStyle(Tokens.Color.text)
                        if isActive {
                            Text("ACTIVE")
                                .font(Tokens.TypeScale.micro)
                                .foregroundStyle(Tokens.Color.success)
                                .padding(.horizontal, Tokens.Space.x2).padding(.vertical, Tokens.Space.x1)
                                .background(Capsule().fill(Tokens.Color.success.opacity(0.16)))
                        }
                    }
                    Text("\(model.quant) · llama.cpp")
                        .font(Tokens.TypeScale.captionSB)
                        .foregroundStyle(Tokens.Color.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(isActive ? Tokens.Color.success : Tokens.Color.textTert)
            }

            ModelFitBadge(fit: model.fit(on: hw))

            Text(model.blurb)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            HStack(spacing: Tokens.Space.x2) {
                Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text(model.sizeLabel).font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Image(systemName: "memorychip").font(.system(size: 11)).foregroundStyle(Tokens.Color.textTert)
                Text("~\(model.ramLabel) RAM").font(Tokens.TypeScale.caption).foregroundStyle(Tokens.Color.textTert)
            }

            Divider().overlay(Tokens.Color.hairline)
            // Maker (Qwen) + the GGUF repo actually downloaded (ggml-org).
            ModelAttribution(
                org: model.makerOrg, display: model.makerDisplay,
                note: "GGUF by ggml-org", link: model.ggufURL, compact: true
            )

            if isDownloadingThis {
                VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                    ProgressView(value: max(state.displayProgress, 0.02))
                        .tint(Tokens.Color.accent)
                    if !state.downloadDetailText.isEmpty {
                        Text(state.downloadDetailText)
                            .font(Tokens.TypeScale.micro).monospacedDigit()
                            .foregroundStyle(Tokens.Color.textTert)
                    }
                }
            } else {
                Button {
                    if isActive { return }
                    if isLocal {
                        settings.modelId = model.id
                        NotificationCenter.default.post(name: .modelChanged, object: nil)
                    } else {
                        AppDelegate.shared?.requestDownload(modelId: model.id)
                    }
                } label: {
                    HStack(spacing: Tokens.Space.x2) {
                        Image(systemName: isActive ? "checkmark.circle.fill"
                              : (isLocal ? "checkmark.circle" : "arrow.down.circle.fill"))
                        Text(isActive ? "Active" : (isLocal ? "Use this model" : "Download & use"))
                    }
                    .font(Tokens.TypeScale.captionSB)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? Tokens.Color.success : Tokens.Color.accent)
                .disabled(state.isDownloading || model.fit(on: hw) == .notRecommended)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(interactive: false)
        .accessibilityElement(children: .combine)
    }
}

/// A labeled progress bar used on cards and the detail page.
struct MetricBar: View {
    let label: String
    let value: Double        // 0…1
    let display: String
    let tone: Tone

    enum Tone { case good, accent }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack {
                Text(label)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Text(display)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(Tokens.Color.fillQuiet)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fill)
                            .frame(width: max(6, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    }
            }
            .frame(height: 6)
            // Values change when the active model switches — morph the fill
            // instead of jumping (Reduce Motion: quick fade, no travel).
            .animation(Tokens.Motion.quick(reduceMotion: Tokens.A11y.reduceMotion), value: value)
        }
    }

    private var fill: SwiftUI.Color {
        switch tone {
        case .good:   return Tokens.Color.success
        case .accent: return Tokens.Color.accent
        }
    }
}

/// Two-axis Accuracy <-> Speed marker (ChatGPT rec): a single dot positioned by
/// speed (x, left=fast) and accuracy (y, top=accurate) is more intuitive than
/// two separate bars for non-technical users.
struct AxisMarker: View {
    let accuracy: Double   // 0…1, higher = more accurate
    let speed: Double       // 0…1, higher = faster

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            Text("Accuracy  ↔  Speed")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            GeometryReader { geo in
                let w = geo.size.width
                let h = max(34, geo.size.height)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Color.fillQuiet)
                    // faint diagonal hint: fast+accurate is top-right
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: CGPoint(x: w, y: 0))
                    }
                    .stroke(Tokens.Color.separator, lineWidth: 1)
                    .opacity(0.6)
                    Circle()
                        .fill(Tokens.Color.accent)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Tokens.Color.surface, lineWidth: 2))
                        .position(
                            x: CGFloat(speed) * (w - 14) + 7,
                            y: (1 - CGFloat(accuracy)) * (h - 14) + 7
                        )
                        .animation(Tokens.Motion.meter, value: accuracy)
                        .animation(Tokens.Motion.meter, value: speed)
                }
                .frame(height: h)
            }
            .frame(height: 40)
            HStack {
                Text("Fast").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
                Spacer(minLength: 0)
                Text("Accurate").font(Tokens.TypeScale.micro).foregroundStyle(Tokens.Color.textTert)
            }
        }
    }
}

/// Full model detail page (req 7).
struct ModelDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var catalog = ModelCatalog.shared
    let model: WhisperModelOption
    let onBack: () -> Void

    private var isActive: Bool { settings.modelId == model.id }
    /// True while THIS model is the one being downloaded.
    private var isDownloadingThis: Bool { state.downloadingModelId == model.id }
    private var isLocal: Bool {
        // A model currently downloading is by definition not complete yet —
        // never consult the disk check for it (its bundle directories appear
        // long before its weights do).
        guard !isDownloadingThis else { return false }
        return (AppDelegate.shared?.transcriberRef.availableLocalModels() ?? []).contains(model.folderName)
    }

    var body: some View {
        let _ = catalog.sizeByFolder   // re-render when HF sizes land
        return ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.x5) {
                Button(action: onBack) {
                    Label("Models", systemImage: "chevron.left")
                        .font(Tokens.TypeScale.caption.weight(.semibold))
                        .foregroundStyle(Tokens.Color.textSec)
                }
                .buttonStyle(.plain)

                // Header
                HStack(alignment: .top, spacing: Tokens.Space.x3) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.quality.uppercased())
                            .font(Tokens.TypeScale.eyebrow).tracking(1.2)
                            .foregroundStyle(Tokens.Color.accent)
                        HStack(spacing: Tokens.Space.x2) {
                            Text(model.display)
                                .font(Tokens.TypeScale.largeTitle)
                                .foregroundStyle(Tokens.Color.text)
                            if isActive {
                                Chip(text: "Active", tint: Tokens.Color.success)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    statusBadge
                }

                Text(model.blurb)
                    .font(Tokens.TypeScale.body)
                    .foregroundStyle(Tokens.Color.textSec)
                    .fixedSize(horizontal: false, vertical: true)

                ModelAttribution(
                    org: model.attribution.org, display: model.attribution.display,
                    note: model.attribution.note, link: model.attribution.url
                )
                .padding(Tokens.Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassRow(cornerRadius: Tokens.Radius.md)

                // Big metrics
                HStack(spacing: Tokens.Space.x4) {
                    MetricBar(label: "Accuracy (English WER)", value: model.accuracyFraction,
                              display: model.englishWER, tone: .good)
                        .frame(maxWidth: .infinity)
                    MetricBar(label: "Speed", value: model.speedFraction,
                              display: model.speedLabel, tone: .accent)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Tokens.Space.x4)

                // Compatibility with THIS Mac (req 4)
                compatibilitySection
                    .padding(.horizontal, Tokens.Space.x4)

                // Spec grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Tokens.Space.x4)],
                          spacing: Tokens.Space.x4) {
                    SpecTile(title: "Parameters", value: model.params)
                    SpecTile(title: "Download size", value: ModelCatalog.shared.sizeLabel(for: model))
                    SpecTile(title: "Runtime RAM", value: model.ram)
                    SpecTile(title: "English WER", value: model.englishWER)
                    SpecTile(title: "Multilingual WER", value: model.multiWER)
                    SpecTile(title: "Language", value: model.lang)
                }
                .padding(.horizontal, Tokens.Space.x4)

                // Recommendation
                VStack(alignment: .leading, spacing: Tokens.Space.x2) {
                    Label("When to use this model", systemImage: "lightbulb.fill")
                        .font(Tokens.TypeScale.headline)
                        .foregroundStyle(Tokens.Color.text)
                    Text(model.recommendation.isEmpty ? "A good general-purpose choice." : model.recommendation)
                        .font(Tokens.TypeScale.callout)
                        .foregroundStyle(Tokens.Color.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Tokens.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface()
                .padding(.horizontal, Tokens.Space.x4)

                // Action
                actionButton
                    .padding(.horizontal, Tokens.Space.x4)

                if state.isDownloading, state.downloadingModelId == model.id {
                    VStack(alignment: .leading, spacing: Tokens.Space.x1) {
                        ProgressView(value: state.displayProgress) {
                            Text(state.downloadLabel).font(Tokens.TypeScale.caption)
                        }
                        if !state.downloadDetailText.isEmpty {
                            Text(state.downloadDetailText)
                                .font(Tokens.TypeScale.micro)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.Color.textTert)
                        }
                    }
                    .frame(width: 360, alignment: .leading)
                    .padding(.horizontal, Tokens.Space.x4)
                } else if state.isLoadingModel {
                    // Load progress (req 3) — shown after a download completes
                    // and while switching to an already-downloaded model.
                    ModelLoadBar()
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.x4)
                }
            }
            .padding(.vertical, Tokens.Space.x6)
            .padding(.horizontal, Tokens.Space.x5)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    /// "Runs great / Tight fit / Not recommended" with a plain-language reason
    /// and a disk-space check for the download.
    @ViewBuilder
    private var compatibilitySection: some View {
        let hw = HardwareInfo.current
        let fit = model.fit(on: hw)
        let need = ModelCatalog.shared.downloadTotalBytes(for: model)
        let free = HardwareInfo.freeDiskBytes()
        let lowDisk = need > 0 && free > 0 && free < need + 500_000_000

        VStack(alignment: .leading, spacing: Tokens.Space.x2) {
            HStack(spacing: Tokens.Space.x2) {
                Label("On your Mac", systemImage: "checkmark.seal")
                    .font(Tokens.TypeScale.headline)
                    .foregroundStyle(Tokens.Color.text)
                Spacer(minLength: 0)
                ModelFitBadge(fit: fit)
            }
            Text(model.fitExplanation(on: hw))
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.textSec)
                .fixedSize(horizontal: false, vertical: true)
            Text("This Mac: \(hw.summary)")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            if lowDisk {
                Label("Low disk space — needs \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isDownloadingThis {
            Text("Downloading…")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.accent)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, Tokens.Space.x1)
                .background(Capsule().fill(Tokens.Color.accent.opacity(0.14)))
        } else {
            Text(isLocal ? "Downloaded" : "Not downloaded")
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(isLocal ? Tokens.Color.success : Tokens.Color.textTert)
                .padding(.horizontal, Tokens.Space.x3)
                .padding(.vertical, Tokens.Space.x1)
                .background(Capsule().fill((isLocal ? Tokens.Color.success : Tokens.Color.textTert).opacity(0.14)))
        }
    }

    private var actionButton: some View {
        // Native prominent button — Liquid Glass on macOS 26 (tinted by the
        // theme), borderedProminent on older releases. The system styles the
        // label; no custom capsule or on-accent color math needed.
        Button {
            if isActive, isLocal {
                // already active + local: nothing to do
            } else if isLocal {
                settings.modelId = model.id
                NotificationCenter.default.post(name: .modelChanged, object: nil)
            } else {
                AppDelegate.shared?.requestDownload(modelId: model.id)
            }
        } label: {
            HStack(spacing: Tokens.Space.x2) {
                if isDownloadingThis {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading… \(Int(state.displayProgress * 100))%")
                        .monospacedDigit()
                } else {
                    Image(systemName: isActive && isLocal ? "checkmark.circle.fill"
                                    : (isLocal ? "checkmark.circle" : "arrow.down.circle.fill"))
                    Text(isActive && isLocal ? "Active"
                            : (isLocal ? "Use this model" : "Download & use"))
                }
            }
        }
        .glassButton(prominent: true)
        .tint(isActive && isLocal ? Tokens.Color.success : Tokens.Color.accent)
        .controlSize(.large)
        .disabled(state.isDownloading)
    }
}

/// A spec tile on the model detail page.
struct SpecTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            Text(title)
                .font(Tokens.TypeScale.caption)
                .foregroundStyle(Tokens.Color.textTert)
            Text(value)
                .font(Tokens.TypeScale.callout)
                .foregroundStyle(Tokens.Color.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Spec tile as a small Liquid Glass chip (frosted vibrancy on <26).
        .glassRow(cornerRadius: Tokens.Radius.md)
    }
}

/// Compatibility verdict pill for a model on this Mac (req 4).
struct ModelFitBadge: View {
    let fit: ModelFit

    private var tone: SwiftUI.Color {
        switch fit {
        case .great:          return Tokens.Color.success
        case .ok:             return Tokens.Color.success
        case .tight:          return Tokens.Color.warn
        case .notRecommended: return Tokens.Color.danger
        }
    }

    var body: some View {
        HStack(spacing: Tokens.Space.x1) {
            Image(systemName: fit.symbol).font(.system(size: 10))
            Text(fit.label).font(Tokens.TypeScale.micro)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, Tokens.Space.x2)
        .padding(.vertical, Tokens.Space.x1)
        .background(Capsule().fill(tone.opacity(0.14)))
    }
}

/// Indeterminate-but-phased progress bar for a model LOAD (req 3). WhisperKit
/// gives only coarse state transitions, so this shows the phase text plus a
/// stepped bar that always advances.
struct ModelLoadBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.x1) {
            HStack(spacing: Tokens.Space.x2) {
                ProgressView().controlSize(.small)
                Text(state.modelLoadPhase.isEmpty ? "Loading model…" : state.modelLoadPhase)
                    .font(Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                Spacer(minLength: 0)
                Text("\(Int((state.modelLoadProgress * 100).rounded()))%")
                    .font(Tokens.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.textTert)
            }
            ProgressView(value: min(max(state.modelLoadProgress, 0.02), 1))
                .progressViewStyle(.linear)
                .tint(Tokens.Color.accent)
                .animation(Tokens.Motion.ease, value: state.modelLoadProgress)
        }
        .padding(Tokens.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassRow(cornerRadius: Tokens.Radius.md)
    }
}
