import Foundation

enum APIError: LocalizedError {
    case noSpeech
    case unknownWords([String])
    case server(String)
    case badURL
    case busy(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noSpeech: return "Không nghe thấy giọng nói. Hãy nói gần micro hơn."
        case .unknownWords(let words): return "Chưa có phiên âm cho: \(words.joined(separator: ", "))"
        case .server(let message): return "Lỗi máy chủ: \(message)"
        case .badURL: return "Địa chỉ máy chủ không hợp lệ. Kiểm tra trong Hồ sơ > Cài đặt."
        case .busy: return "Máy chủ đang bận, thử lại sau ít phút."
        }
    }
}

struct PhonemizeResult: Decodable {
    struct Word: Decodable {
        let word: String
        let ipa: String
    }

    struct Link: Decodable, Hashable {
        let display: String
        let type: String
        let hint: String
    }

    let intonation: String
    let connectedIpa: String
    let links: [Link]
    let words: [Word]

    var ipa: String { words.map(\.ipa).joined(separator: " ") }
}

struct LLMCheck: Decodable {
    let format: String
    let model: String
    let source: String
    let reply: String
    let ms: Int
}

/// Client for the OpenSpeak backend (scoring, vocabulary, dictionary, mouth coaching).
struct APIClient {
    /// The simulator talks to a backend on the same Mac; device builds use the server baked in at build time
    /// (`OPENSPEAK_SERVER_URL` in `ios/Config/Server.local.xcconfig`, kept out of git).
    static let defaultBaseURL: String = {
        #if targetEnvironment(simulator)
        return "http://localhost:8000"
        #else
        let configured = Bundle.main.object(forInfoDictionaryKey: "OpenSpeakServerURL") as? String ?? ""
        return configured.isEmpty ? "http://localhost:8000" : configured
        #endif
    }()
    static let storageKey = "backendURL"

    let baseURL: URL
    var session: URLSession = .shared

    init(baseURL: String) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            throw APIError.badURL
        }
        self.baseURL = url
    }

    /// Uses the address saved in Settings, and the learner's own LLM if they turned it on.
    static func current() throws -> APIClient {
        var client = try APIClient(baseURL: UserDefaults.standard.string(forKey: storageKey) ?? defaultBaseURL)
        client.session = UserLLM.session()
        return client
    }

    func health() async -> Bool {
        guard let (_, response) = try? await session.data(from: baseURL.appendingPathComponent("health")) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func phonemize(_ text: String) async throws -> PhonemizeResult {
        try await get("v1/phonemize", query: ["text": text])
    }

    func assess(text: String, audio: URL, reference: URL?, feedback: Bool = true, skipUnknown: Bool = false) async throws -> Assessment {
        var form = MultipartForm()
        form.addField("text", text)
        form.addField("feedback", feedback ? "true" : "false")
        if skipUnknown { form.addField("skip_unknown", "true") }
        try form.addFile("audio", url: audio, mimeType: "audio/wav")
        if let reference {
            try form.addFile("reference_audio", url: reference, mimeType: "audio/wav")
        }
        let data = try await post("v1/assess", form: form, timeout: 90)
        return try Assessment.decode(data)
    }

    func articulationFeedback(text: String, samples: [LipSample], frames: [Int: Data]) async throws -> ArticulationFeedback {
        struct Payload: Encodable {
            let text: String
            let samples: [LipSample]
        }
        var form = MultipartForm()
        let payload = try JSONEncoder().encode(Payload(text: text, samples: samples))
        form.addField("payload", String(decoding: payload, as: UTF8.self))
        for (index, jpeg) in frames.sorted(by: { $0.key < $1.key }) {
            form.addData("frames", filename: "\(index).jpg", data: jpeg, mimeType: "image/jpeg")
        }
        let data = try await post("v1/articulation-feedback", form: form, timeout: 120)
        return try JSONDecoder.snakeCase.decode(ArticulationFeedback.self, from: data)
    }

    func vocabLesson(topic: String, level: String, known: [String], count: Int = 8) async throws -> VocabLesson {
        struct Body: Encodable {
            let topic: String
            let level: String
            let count: Int
            let known: [String]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/vocab/lesson"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(topic: topic, level: level, count: count, known: known))
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return try JSONDecoder.snakeCase.decode(VocabLesson.self, from: data)
    }

    func define(_ word: String) async throws -> DictionaryResult {
        let path = "v1/dictionary/" + (word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)
        let url = URL(string: path, relativeTo: baseURL) ?? baseURL
        let (data, response) = try await session.data(from: url)
        try Self.check(data, response)
        return try JSONDecoder.snakeCase.decode(DictionaryResult.self, from: data)
    }

    /// One short call to the LLM the server would use with `llm` (or its own LLM when `llm` sends no headers).
    func checkLLM(_ llm: UserLLM) async throws -> LLMCheck {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/llm/check"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        for (name, value) in llm.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data, response)
        return try JSONDecoder.snakeCase.decode(LLMCheck.self, from: data)
    }

    // MARK: Personal path

    /// The next lesson of the endless path, planned by the server from the learner's own results.
    func pathNext(_ request: PathRequest) async throws -> PathLesson {
        try await postJSON("v1/path/next", body: request, timeout: 180)
    }

    func pathExam(_ request: PathRequest) async throws -> PathExam {
        try await postJSON("v1/path/exam", body: request, timeout: 180)
    }

    func vocabNext(_ request: VocabPathRequest) async throws -> VocabPathLesson {
        try await postJSON("v1/vocab/next", body: request, timeout: 180)
    }

    func exercises(_ request: ExerciseRequest) async throws -> ExerciseSet {
        try await postJSON("v1/exercises", body: request, timeout: 180)
    }

    // MARK: AI roleplay

    func roleplayScenarios() async throws -> [RoleplayScenario] {
        struct Response: Decodable { let scenarios: [RoleplayScenario] }
        let response: Response = try await get("v1/roleplay/scenarios", query: [:])
        return response.scenarios
    }

    func roleplayStart(topic: String, level: String) async throws -> RoleplayScenario {
        struct Body: Encodable { let topic: String; let level: String }
        return try await postJSON("v1/roleplay/start", body: Body(topic: topic, level: level), timeout: 60)
    }

    func roleplayTurn(scenario: RoleplayScenario, history: [RoleplayMessage], message: String, level: String) async throws -> RoleplayTurn {
        struct Line: Encodable { let role: String; let text: String }
        struct Body: Encodable {
            let scenario: RoleplayScenario
            let history: [Line]
            let message: String
            let level: String
        }
        let lines = history.map { Line(role: $0.fromAI ? "ai" : "user", text: $0.text) }
        return try await postJSON("v1/roleplay/turn",
                                  body: Body(scenario: scenario, history: lines, message: message, level: level), timeout: 60)
    }

    /// A person's recording of the word from Wikimedia Commons, or nil if Commons has none.
    func wordAudio(_ word: String) async throws -> (data: Data, credit: WordAudioCredit)? {
        let path = "v1/audio/word/" + (word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 404 { return nil }
        if http?.statusCode == 503 {
            throw APIError.busy(retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60)
        }
        try Self.check(data, response)
        func header(_ name: String) -> String {
            http?.value(forHTTPHeaderField: name)?.removingPercentEncoding ?? ""
        }
        let credit = WordAudioCredit(artist: header("X-Audio-Artist"), license: header("X-Audio-License"),
                                     source: header("X-Audio-Source"), accent: header("X-Audio-Accent"))
        return (data, credit)
    }

    // MARK: Plumbing

    private func postJSON<B: Encodable, T: Decodable>(_ path: String, body: B, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return try JSONDecoder.snakeCase.decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw APIError.badURL }
        let (data, response) = try await session.data(from: url)
        try Self.check(data, response)
        return try JSONDecoder.snakeCase.decode(T.self, from: data)
    }

    private func post(_ path: String, form: MultipartForm, timeout: TimeInterval) async throws -> Data {
        var form = form
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: form.finish())
        try Self.check(data, response)
        return data
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.server("no response") }
        guard http.statusCode != 200 else { return }

        struct ErrorBody: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
                let words: [String]?
            }
            let detail: Detail?
        }
        let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
        switch detail?.code {
        case "no_speech": throw APIError.noSpeech
        case "unknown_words": throw APIError.unknownWords(detail?.words ?? [])
        default: throw APIError.server(detail?.message ?? "HTTP \(http.statusCode)")
        }
    }
}

private struct MultipartForm {
    private let boundary = "OpenSpeak-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(_ name: String, url: URL, mimeType: String) throws {
        addData(name, filename: url.lastPathComponent, data: try Data(contentsOf: url), mimeType: mimeType)
    }

    mutating func addData(_ name: String, filename: String, data: Data, mimeType: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finish() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
