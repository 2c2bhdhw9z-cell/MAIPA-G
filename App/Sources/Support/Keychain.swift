import Foundation
import Security

/// Secrets (the OpenRouter key, the GitHub app's private key and tokens) live in the iPhone's
/// Keychain, never in files. Items stay on this phone only, are readable once it has been unlocked
/// after a restart, and survive deleting the app when it is reinstalled with the same certificate.
enum Keychain {
    static let service = "dev.maipag.app"

    enum Item: String, CaseIterable {
        case openRouterKey = "openrouter.key"
        case githubApp = "github.app"
        case githubUserToken = "github.user-token"
        case githubInstallation = "github.installation"
    }

    static func data(_ item: Item) -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for item: Item) -> Bool {
        let query = baseQuery(item)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func remove(_ item: Item) {
        SecItemDelete(baseQuery(item) as CFDictionary)
    }

    static func string(_ item: Item) -> String? {
        data(item).map { String(decoding: $0, as: UTF8.self) }
    }

    static func setString(_ value: String, for item: Item) {
        set(Data(value.utf8), for: item)
    }

    static func value<T: Decodable>(_ type: T.Type, for item: Item) -> T? {
        guard let data = data(item) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func setValue<T: Encodable>(_ value: T, for item: Item) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, for: item)
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}
