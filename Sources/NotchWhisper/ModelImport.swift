import Foundation
import AppKit
import UniformTypeIdentifiers

/// Brings a model in from the user's own disk (§33, §34).
///
/// Treated with the same suspicion as a download (§79): the contents are
/// inspected and validated against a shipped runtime before anything is
/// registered, and file names from the source can never escape the managed
/// model directory.
@MainActor
final class ModelImporter: ObservableObject {
    static let shared = ModelImporter()

    /// What inspection found, before the user commits to adding it.
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let suggestedName: String
        let engine: ModelEngine
        let format: ModelFileFormat
        let sizeBytes: Int64
        let fileCount: Int
        /// Files that make up the model, for the confirmation sheet.
        let notes: [String]

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    enum ImportError: LocalizedError {
        case unreadable
        case unrecognized(String)
        case incompleteCoreML([String])
        case ggufMissingProjector
        case unsafePath
        case alreadyInstalled(String)
        case copyFailed(String)
        case insufficientSpace(needed: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "NotchWhisper couldn't read that location."
            case .unrecognized(let name):
                return "\(name) doesn't look like a model NotchWhisper can run. It accepts a Core ML Whisper folder or a GGUF speech model with its mmproj file."
            case .incompleteCoreML(let missing):
                return "That Core ML folder is missing \(missing.joined(separator: ", ")). All three compiled bundles are required."
            case .ggufMissingProjector:
                return "That GGUF has no matching mmproj file next to it. The speech backend needs the audio projector to read audio."
            case .unsafePath:
                return "That model contains file paths that point outside its own folder, so it wasn't imported."
            case .alreadyInstalled(let name):
                return "\(name) is already installed."
            case .copyFailed(let why):
                return "The copy didn't finish: \(why)"
            case .insufficientSpace(let needed, let free):
                let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                return "That model needs \(n) and there's \(f) free."
            }
        }
    }

    @Published var candidate: Candidate?
    @Published var isImporting = false
    @Published var error: String?

    private init() {}

    // MARK: Picking

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Model"
        panel.message = "Choose a Core ML Whisper folder or a GGUF speech model."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        if let type = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [type, .folder]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspect(url)
    }

    /// Handle a drag-and-drop onto the Models page.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            guard let url else { return }
            Task { @MainActor in self?.inspect(url) }
        }
        return true
    }

    // MARK: Inspection

    /// Identify what is at `url` without copying anything yet.
    func inspect(_ url: URL) {
        error = nil
        do {
            candidate = try detect(url)
        } catch {
            candidate = nil
            self.error = error.localizedDescription
        }
    }

    private func detect(_ url: URL) throws -> Candidate {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ImportError.unreadable }

        // A single .gguf file: pair it with the mmproj sitting beside it.
        if !isDir.boolValue {
            guard url.pathExtension.lowercased() == "gguf" else {
                throw ImportError.unrecognized(url.lastPathComponent)
            }
            let dir = url.deletingLastPathComponent()
            let siblings = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard let projector = siblings.first(where: {
                $0.lastPathComponent.lowercased().hasPrefix("mmproj")
                    && $0.pathExtension.lowercased() == "gguf"
            }) else { throw ImportError.ggufMissingProjector }
            return Candidate(
                sourceURL: url,
                suggestedName: url.deletingPathExtension().lastPathComponent,
                engine: .llamaCPP,
                format: .gguf,
                sizeBytes: ModelDisk.directoryBytes(url) + ModelDisk.directoryBytes(projector),
                fileCount: 2,
                notes: ["\(url.lastPathComponent) — model weights",
                        "\(projector.lastPathComponent) — audio projector"]
            )
        }

        // A folder: Core ML bundle set, or a GGUF pair inside.
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let names = Set(contents.map(\.lastPathComponent))
        let missing = ModelDisk.coreMLBundles.filter { !names.contains($0) }
        if missing.count < ModelDisk.coreMLBundles.count {
            guard missing.isEmpty else { throw ImportError.incompleteCoreML(missing) }
            guard ModelDisk.hasCoreMLWeights(url) else {
                throw ImportError.incompleteCoreML(["the compiled weight data"])
            }
            return Candidate(
                sourceURL: url,
                suggestedName: url.lastPathComponent,
                engine: .whisperKit,
                format: .coreML,
                sizeBytes: ModelDisk.directoryBytes(url),
                fileCount: ModelDisk.coreMLBundles.count,
                notes: ModelDisk.coreMLBundles.map { "\($0) — verified" }
            )
        }

        let ggufs = contents.filter { $0.pathExtension.lowercased() == "gguf" }
        if !ggufs.isEmpty {
            let projectors = ggufs.filter { $0.lastPathComponent.lowercased().hasPrefix("mmproj") }
            let weights = ggufs.filter { !$0.lastPathComponent.lowercased().hasPrefix("mmproj") }
            guard let weight = weights.first else { throw ImportError.unrecognized(url.lastPathComponent) }
            guard let projector = projectors.first else { throw ImportError.ggufMissingProjector }
            return Candidate(
                sourceURL: url,
                suggestedName: url.lastPathComponent,
                engine: .llamaCPP,
                format: .gguf,
                sizeBytes: ModelDisk.directoryBytes(weight) + ModelDisk.directoryBytes(projector),
                fileCount: 2,
                notes: ["\(weight.lastPathComponent) — model weights",
                        "\(projector.lastPathComponent) — audio projector"]
            )
        }

        // Say what it *is*, so the user isn't left guessing (§69).
        if contents.contains(where: { $0.pathExtension.lowercased() == "safetensors" }) {
            throw ImportError.unrecognized("\(url.lastPathComponent) (Safetensors)")
        }
        if contents.contains(where: { $0.pathExtension.lowercased() == "onnx" }) {
            throw ImportError.unrecognized("\(url.lastPathComponent) (ONNX)")
        }
        throw ImportError.unrecognized(url.lastPathComponent)
    }

    // MARK: Committing

    /// Add the inspected candidate to the model list.
    ///
    /// - Parameter copyIntoManagedStorage: `false` registers the model where it
    ///   already lives, which avoids duplicating multi-gigabyte files. It is
    ///   only offered when the source is somewhere durable — never for a
    ///   removable volume or a temporary directory, where the files would
    ///   vanish out from under the engine.
    func commit(_ candidate: Candidate, name: String, copyIntoManagedStorage: Bool) async {
        isImporting = true
        error = nil
        defer { isImporting = false }

        let cleanName = Self.sanitize(name.isEmpty ? candidate.suggestedName : name)
        let modelId = "imported:\(cleanName)"
        guard ModelRegistry.shared.installations[modelId] == nil else {
            error = ImportError.alreadyInstalled(cleanName).localizedDescription
            return
        }

        let finalURL: URL
        if copyIntoManagedStorage {
            let destination = ModelDisk.importedRoot().appendingPathComponent(cleanName, isDirectory: true)
            // The destination is built from a sanitized name, never from a path
            // inside the source, so nothing can be written outside Imported/.
            guard destination.path.hasPrefix(ModelDisk.importedRoot().path) else {
                error = ImportError.unsafePath.localizedDescription
                return
            }
            let free = HardwareInfo.freeDiskBytes()
            if free > 0, candidate.sizeBytes > 0, free < candidate.sizeBytes + 200_000_000 {
                error = ImportError.insufficientSpace(needed: candidate.sizeBytes, free: free)
                    .localizedDescription
                return
            }
            let source = candidate.sourceURL
            let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            let isFile = !sourceIsDirectory
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    if isFile {
                        // A loose .gguf: bring its projector along too.
                        let dir = source.deletingLastPathComponent()
                        let siblings = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                        let wanted = siblings.filter {
                            $0 == source
                                || ($0.pathExtension.lowercased() == "gguf"
                                    && $0.lastPathComponent.lowercased().hasPrefix("mmproj"))
                        }
                        for file in wanted {
                            let target = destination.appendingPathComponent(file.lastPathComponent)
                            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                            try fm.copyItem(at: file, to: target)
                        }
                    } else {
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        try fm.copyItem(at: source, to: destination)
                    }
                }.value
            } catch {
                self.error = ImportError.copyFailed(error.localizedDescription).localizedDescription
                return
            }
            finalURL = destination
        } else {
            finalURL = candidate.format == .gguf && candidate.sourceURL.pathExtension.lowercased() == "gguf"
                ? candidate.sourceURL.deletingLastPathComponent()
                : candidate.sourceURL
        }

        let record = ModelInstallation(
            id: modelId,
            repositoryId: finalURL.path,
            commitSha: nil,
            pinnedRevision: nil,
            displayName: cleanName,
            provider: "Imported",
            source: .imported,
            format: candidate.format,
            engine: candidate.engine,
            quantization: HFRepoMetadata.quantizationHint(candidate.sourceURL.lastPathComponent),
            languages: [],
            parameterCount: nil,
            license: nil,
            sizeBytes: candidate.sizeBytes,
            estimatedMemoryBytes: Self.estimateMemory(diskBytes: candidate.sizeBytes,
                                                      engine: candidate.engine),
            installedPath: finalURL.path,
            folderName: candidate.engine == .whisperKit ? finalURL.lastPathComponent : nil,
            installedAt: Date(),
            lastUsedAt: nil,
            usageCount: 0,
            verification: .verified,
            isFavorite: false
        )
        ModelRegistry.shared.registerImported(record)
        self.candidate = nil
        await ModelRegistry.shared.scan()
        AppState.shared.showToast("\(cleanName) added to your models.")
    }

    /// Strip anything that could traverse out of the managed directory.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "..", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported model" : String(cleaned.prefix(80))
    }

    /// A rough resident footprint, labelled as an estimate wherever it's shown.
    /// Core ML weights are largely mapped; GGUF is fully resident plus a KV
    /// cache, so the multipliers differ.
    static func estimateMemory(diskBytes: Int64, engine: ModelEngine) -> Int64 {
        guard diskBytes > 0 else { return 0 }
        switch engine {
        case .whisperKit: return Int64(Double(diskBytes) * 1.4)
        case .llamaCPP:   return Int64(Double(diskBytes) * 1.6)
        }
    }
}
