import Foundation
import Security

/// Tiny Keychain wrapper for storing secrets (HF token, local LLM server API
/// key). API keys never touch UserDefaults or the filesystem as plain text.
enum Keychain {
    static let service = "com.behkha.notchwhisper"
    static let account = "hf_token"

    static func getToken() -> String? {
        get(account: account)
    }

    static func setToken(_ token: String?) {
        set(token, for: account)
    }

    // MARK: - Generic get/set

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        guard let data = value.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(add as CFDictionary, nil)
    }
}
