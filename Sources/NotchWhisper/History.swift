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

    enum Source: String, Codable { case hotkey, button }

    var corrected: Bool { !corrections.isEmpty }
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

    func add(raw: String, final: String, corrections: [CorrectionChange], source: TranscriptRecord.Source) {
        let rec = TranscriptRecord(
            id: UUID(), createdAt: Date(),
            rawText: raw, finalText: final,
            corrections: corrections, source: source
        )
        records.insert(rec, at: 0)
        if records.count > 500 { records = Array(records.prefix(500)) }
        persist()
    }

    func delete(_ rec: TranscriptRecord) {
        records.removeAll { $0.id == rec.id }
        persist()
    }

    func clear() { records = []; persist() }

    func filtered() -> [TranscriptRecord] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.finalText.localizedCaseInsensitiveContains(q) ||
            $0.rawText.localizedCaseInsensitiveContains(q)
        }
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
