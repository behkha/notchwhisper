import Foundation
import SwiftUI

/// A single finished transcription, kept in the history list. Records the raw
/// engine output, the final (corrected) text, and which dictionary corrections
/// fired — so the user can see whether the dictionary is doing anything.
struct TranscriptRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var rawText: String          // what the engine produced
    var finalText: String        // after the correction pass
    var corrections: [CorrectionChange]
    var source: Source           // how it was captured
    /// Legacy field: the raw value of the built-in mode that processed this
    /// transcript, in archives written before every mode became the user's.
    /// New records carry `llmModeName` instead.
    var llmMode: String? = nil
    /// Display name of the mode that ran, built-in or custom. Recorded as text
    /// so a record still reads correctly after the mode is renamed or deleted.
    /// Optional: older archives simply don't carry it.
    var llmModeName: String? = nil
    var llmModeSymbol: String? = nil
    /// Name of the app profile that shaped this dictation (nil = global
    /// settings). Recorded as text so a record still reads correctly after the
    /// profile is renamed or deleted.
    var profileName: String? = nil
    /// Bundle id of the app the text was actually typed into, when it differed
    /// from the app the dictation started in. nil = it went where it was aimed.
    var insertedIntoBundleID: String? = nil

    /// How the audio was captured. `file` = imported from disk on the Upload
    /// page (older records only ever carry `hotkey`/`button`, so decoding
    /// existing archives is unaffected).
    enum Source: String, Codable { case hotkey, button, file }

    var corrected: Bool { !corrections.isEmpty }
    var processed: Bool { modeLabel != nil }

    /// The mode chip's text, or nil when nothing processed this transcript.
    var modeLabel: String? {
        if let llmModeName, !llmModeName.isEmpty { return llmModeName }
        return legacySeed?.name
    }

    var modeSymbol: String {
        llmModeSymbol ?? legacySeed?.symbolName ?? "wand.and.stars"
    }

    /// The mode a pre-modes record names, looked up among the seeds that
    /// replaced the built-ins, so old history still reads correctly.
    private var legacySeed: CustomMode? {
        guard let llmMode, let id = CustomMode.legacySeedID(forRaw: llmMode) else { return nil }
        return CustomMode.seed(id: id)
    }
}

@MainActor final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published var records: [TranscriptRecord] = []
    @Published var search: String = ""

    private let fileManager = FileManager.default
    private var url: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/transcripts.json")
    }

    private init() { load() }

    func add(raw: String, final: String, corrections: [CorrectionChange],
             source: TranscriptRecord.Source, mode: ProcessingMode? = nil,
             profileName: String? = nil, insertedIntoBundleID: String? = nil) {
        var name: String? = nil
        var symbol: String? = nil
        // `.off` means nothing processed the transcript — no chip to record.
        if let mode, !mode.isPassthrough {
            name = CustomModeStore.shared.label(for: mode)
            symbol = CustomModeStore.shared.symbol(for: mode)
        }
        let rec = TranscriptRecord(
            id: UUID(), createdAt: Date(),
            rawText: raw, finalText: final,
            corrections: corrections, source: source,
            llmModeName: name, llmModeSymbol: symbol,
            profileName: profileName, insertedIntoBundleID: insertedIntoBundleID
        )
        records.insert(rec, at: 0)
        if records.count > 500 { records = Array(records.prefix(500)) }
        persist()
    }

    func delete(_ rec: TranscriptRecord) {
        records.removeAll { $0.id == rec.id }
        persist()
    }

    /// Deletes only the records matching the current search — clearing a
    /// filtered view used to wipe the entire archive.
    func clearFiltered() {
        records.removeAll { matchesSearch($0) }
        persist()
    }

    func clear() { records = []; persist() }

    func filtered() -> [TranscriptRecord] {
        guard hasSearch else { return records }
        return records.filter(matchesSearch)
    }

    private var hasSearch: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ rec: TranscriptRecord) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rec.finalText.localizedCaseInsensitiveContains(q) ||
               rec.rawText.localizedCaseInsensitiveContains(q)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        records = (try? JSONDecoder().decode([TranscriptRecord].self, from: data)) ?? []
    }
}
