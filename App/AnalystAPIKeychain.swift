import Foundation
import Security

enum AnalystAPIKeychain {
    private static let account = "llm-provider-api-key"
    private static var service: String { Bundle.main.bundleIdentifier ?? "stock-monitor-v6" }

    static func save(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KeychainFailure.invalidValue }
        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            for (name, value) in attributes { add[name] = value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainFailure.status(status) }
        } else if updateStatus != errSecSuccess {
            throw KeychainFailure.status(updateStatus)
        }
    }

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw KeychainFailure.invalidValue
        }
        return value
    }

    static func hasKey() -> Bool {
        do { return try load()?.isEmpty == false } catch { return false }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure.status(status) }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private enum KeychainFailure: Error, LocalizedError {
        case invalidValue
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidValue: return "密钥内容无效。"
            case .status(let status): return "Keychain 操作失败（状态码 \(status)）。"
            }
        }
    }
}
