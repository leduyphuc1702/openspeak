import Foundation
import Security

/// The learner's own LLM account. When it is turned on, every request to the OpenSpeak server carries it
/// in `X-LLM-*` headers and the server uses it for that request instead of its own LLM.
/// The API key lives in the Keychain; everything else in UserDefaults.
struct UserLLM: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case chatCompletions = "openai-chat-completions"
        case responses = "openai-responses"
        case anthropic = "anthropic-messages"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chatCompletions: return "OpenAI Chat Completions"
            case .responses: return "OpenAI Responses"
            case .anthropic: return "Anthropic Messages"
            }
        }

        var exampleBaseURL: String {
            self == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        }
    }

    var enabled = false
    var format = Format.chatCompletions
    var baseURL = ""
    var model = ""
    var visionModel = ""
    var key = ""

    var isComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Headers for requests to the OpenSpeak server; empty when the learner's LLM is off or unfinished.
    var headers: [String: String] {
        guard enabled, isComplete else { return [:] }
        var headers = ["X-LLM-Format": format.rawValue,
                       "X-LLM-Base-URL": baseURL.trimmingCharacters(in: .whitespaces),
                       "X-LLM-Model": model.trimmingCharacters(in: .whitespaces)]
        let vision = visionModel.trimmingCharacters(in: .whitespaces)
        if !vision.isEmpty { headers["X-LLM-Vision-Model"] = vision }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { headers["X-LLM-Key"] = key }
        return headers
    }

    // MARK: Storage

    private enum Keys {
        static let enabled = "userLLM.enabled"
        static let format = "userLLM.format"
        static let baseURL = "userLLM.baseURL"
        static let model = "userLLM.model"
        static let visionModel = "userLLM.visionModel"
        static let keychainAccount = "userLLM.apiKey"
    }

    static func load(_ defaults: UserDefaults = .standard) -> UserLLM {
        UserLLM(enabled: defaults.bool(forKey: Keys.enabled),
                format: Format(rawValue: defaults.string(forKey: Keys.format) ?? "") ?? .chatCompletions,
                baseURL: defaults.string(forKey: Keys.baseURL) ?? "",
                model: defaults.string(forKey: Keys.model) ?? "",
                visionModel: defaults.string(forKey: Keys.visionModel) ?? "",
                key: Keychain.read(Keys.keychainAccount) ?? "")
    }

    /// Saves the settings; throws if the Keychain refuses the key.
    func save(_ defaults: UserDefaults = .standard) throws {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(format.rawValue, forKey: Keys.format)
        defaults.set(baseURL, forKey: Keys.baseURL)
        defaults.set(model, forKey: Keys.model)
        defaults.set(visionModel, forKey: Keys.visionModel)
        try Keychain.write(key, account: Keys.keychainAccount)
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in [Keys.enabled, Keys.format, Keys.baseURL, Keys.model, Keys.visionModel] {
            defaults.removeObject(forKey: key)
        }
        try? Keychain.write("", account: Keys.keychainAccount)
    }

    // MARK: Session

    /// A URLSession that adds the current headers to every request. Rebuilt only when the settings change.
    static func session() -> URLSession {
        SessionCache.shared.session(for: load().headers)
    }
}

private final class SessionCache: @unchecked Sendable {
    static let shared = SessionCache()
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var cached: URLSession?

    func session(for headers: [String: String]) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if headers.isEmpty { return .shared }
        if let cached, headers == self.headers { return cached }
        cached?.finishTasksAndInvalidate()
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = headers
        let session = URLSession(configuration: configuration)
        self.headers = headers
        cached = session
        return session
    }
}

enum Keychain {
    private static let service = "OpenSpeak"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or deletes the item when `value` is empty.
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Không lưu được khoá API vào Keychain (mã \(status))."])
        }
    }
}
