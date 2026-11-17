import Foundation

/// The key a server asks for when it is shared by several learners. Kept in the Keychain, never in
/// UserDefaults, and sent as `Authorization: Bearer` on every request. An empty key means the server is open.
enum ServerAccess {
    private static let account = "server.accessKey"

    static var key: String {
        (Keychain.read(account) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String) throws {
        try Keychain.write(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
    }

    /// Headers for a key being typed but not saved yet; nil means use the saved key.
    static func authorization(_ key: String? = nil) -> [String: String] {
        let value = (key ?? Self.key).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [:] : ["Authorization": "Bearer \(value)"]
    }
}
