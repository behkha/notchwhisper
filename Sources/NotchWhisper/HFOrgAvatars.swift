import Foundation
import SwiftUI

/// Resolves a Hugging Face **organization avatar** (the "company logo" shown on
/// model cards) from its public API, cached on disk so the network is hit at
/// most once per org.
///
///   GET https://huggingface.co/api/organizations/<org>/avatar
///       → { "avatarUrl": "https://cdn-avatars.huggingface.co/…" }
///
/// The card then loads that CDN URL with `AsyncImage`.
@MainActor
final class HFOrgAvatars: ObservableObject {
    static let shared = HFOrgAvatars()

    /// org (lowercased) → avatar CDN URL string. A cached empty string means
    /// "looked up, none found" so we don't retry every render.
    @Published private(set) var byOrg: [String: String] = [:]

    private var inFlight = Set<String>()
    private let cacheURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWhisper/org-avatars.json")
    }()

    private init() { load() }

    /// The avatar URL for `org`, if resolved. Call `ensure(_:)` first.
    func avatarURL(for org: String) -> URL? {
        guard let s = byOrg[org.lowercased()], !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// Kick off a one-time lookup for `org` (no-op if cached or in flight).
    func ensure(_ org: String) {
        let key = org.lowercased()
        guard byOrg[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [weak self] in
            let url = await Self.fetchAvatarURL(org: org)
            await MainActor.run {
                guard let self else { return }
                self.byOrg[key] = url ?? ""
                self.inFlight.remove(key)
                self.save()
            }
        }
    }

    private static func fetchAvatarURL(org: String) async -> String? {
        // Try the organization endpoint, then fall back to the user endpoint
        // (some makers are HF "users", not "orgs").
        for path in ["organizations", "users"] {
            guard let url = URL(string: "https://huggingface.co/api/\(path)/\(org)/avatar") else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let avatar = obj["avatarUrl"] as? String, !avatar.isEmpty else { continue }
            return avatar
        }
        return nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        byOrg = map
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byOrg) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
    }
}

// MARK: - Attribution row

/// "Made by <org>" with the org's Hugging Face avatar and a link to the repo.
/// Shown on every model card and detail page so the maker is always visible.
struct ModelAttribution: View {
    /// HF org/user handle, e.g. "openai", "Qwen", "ggml-org".
    let org: String
    /// Human label, e.g. "OpenAI". Defaults to `org`.
    var display: String? = nil
    /// Extra note, e.g. "Core ML by Argmax" / "GGUF by ggml-org".
    var note: String? = nil
    /// The Hugging Face page this model comes from.
    let link: URL
    var compact: Bool = false
    /// Render the HF link as a real `Link`. Set false when the row sits inside
    /// an outer `Button` (a card) that would swallow the tap — the detail page
    /// carries the working link instead.
    var showLink: Bool = true

    @ObservedObject private var avatars = HFOrgAvatars.shared

    private var side: CGFloat { compact ? 16 : 20 }

    var body: some View {
        HStack(spacing: Tokens.Space.x2) {
            avatar
            VStack(alignment: .leading, spacing: 0) {
                Text(display ?? org)
                    .font(compact ? Tokens.TypeScale.micro : Tokens.TypeScale.caption)
                    .foregroundStyle(Tokens.Color.textSec)
                if let note {
                    Text(note)
                        .font(Tokens.TypeScale.micro)
                        .foregroundStyle(Tokens.Color.textTert)
                }
            }
            Spacer(minLength: 0)
            if showLink {
                Link(destination: link) {
                    hfLabel.foregroundStyle(Tokens.Color.accent)
                }
                .buttonStyle(.plain)
            } else {
                hfLabel.foregroundStyle(Tokens.Color.textTert)
            }
        }
        .onAppear { avatars.ensure(org) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Made by \(display ?? org)\(showLink ? ". Opens Hugging Face." : "")")
    }

    private var hfLabel: some View {
        HStack(spacing: 3) {
            Text("Hugging Face")
            Image(systemName: "arrow.up.right")
        }
        .font(Tokens.TypeScale.micro)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = avatars.avatarURL(for: org) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Tokens.Color.fillQuiet
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                    .strokeBorder(Tokens.Color.hairline, lineWidth: 1)
            )
        } else {
            Image(systemName: "building.2.crop.circle.fill")
                .font(.system(size: side * 0.8))
                .foregroundStyle(Tokens.Color.textTert)
                .frame(width: side, height: side)
        }
    }
}
