import Foundation
import Security

enum SpotifyKeychain {
    struct PlayerSession: Codable {
        let accountID: String
        let token: Data
        let tokenFilename: String?
        let credentials: Data?
    }

    static func loadPlayerSession() throws -> PlayerSession? {
        guard let data = try load(service: "spotify-player") else { return nil }
        return try JSONDecoder().decode(PlayerSession.self, from: data)
    }

    static func savePlayerSession(_ session: PlayerSession) throws {
        try save(JSONEncoder().encode(session), service: "spotify-player")
    }

    static func deletePlayerSession() throws {
        try delete(service: "spotify-player")
    }

    private static func load(service: String) throws -> Data? {
        var query = sessionItem(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return data
    }

    private static func save(_ session: Data, service: String) throws {
        let query = sessionItem(service)
        let values = [kSecValueData as String: session]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = session
            try check(SecItemAdd(attributes as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func delete(service: String) throws {
        let status = SecItemDelete(sessionItem(service) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func sessionItem(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "local.bop.prototype").\(service)",
            kSecAttrAccount as String: "session",
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "Bop couldn’t access Spotify’s sign-in in Keychain (\(status))."
        }
    }
}
