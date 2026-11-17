import Foundation

/// Mirrors the backend's POST /v1/vocab/lesson (decoded with convertFromSnakeCase).
struct VocabWord: Codable, Hashable, Identifiable {
    let word: String
    let pos: String
    let meaningVi: String
    let exampleEn: String
    let exampleVi: String
    let tipVi: String?
    let ipa: String
    let connectedIpa: String?
    let phones: [String]
    let syllables: Int
    /// From the vocabulary programme: a second sentence in another situation, with the word hidden in it,
    /// and the form of the word that fills the gap.
    var practiceEn: String? = nil
    var practiceVi: String? = nil
    var clozeEn: String? = nil
    var clozeAnswer: String? = nil

    var id: String { word.lowercased() }
}

/// One lesson of the vocabulary programme (POST /v1/vocab/next).
struct VocabPathLesson: Codable, Hashable, Identifiable {
    let index: Int
    let topic: String
    let topicTitle: String
    let situationVi: String?
    let title: String
    let goalVi: String?
    let words: [VocabWord]
    let source: String

    var id: Int { index }
    var writtenByAI: Bool { source == "llm" }
}

struct VocabPathRequest: Encodable {
    let level: String
    let topics: [String]
    let lessonIndex: Int
    let known: [String]
    let weak: [String]
}

struct VocabLesson: Codable, Hashable {
    let topic: String
    let title: String
    let source: String
    let words: [VocabWord]
}

struct DictionaryResult: Codable, Hashable {
    struct Sense: Codable, Hashable {
        let gloss: String
        let vi: [String]
    }

    struct Entry: Codable, Hashable {
        let pos: String?
        let ipaUs: String?
        let ipaUk: String?
        let senses: [Sense]
    }

    let word: String
    let ipa: String?
    let phones: [String]
    let entries: [Entry]
    let source: String?
    let cambridgeUrl: String
}

/// Mirrors POST /v1/articulation-feedback.
struct ArticulationFeedback: Codable {
    struct Finding: Codable, Hashable {
        let index: Int
        let word: String
        let phoneId: String
        let status: String     // ok, fix, needs_visual
        let message: String
    }

    struct Coach: Codable {
        struct Frame: Codable, Hashable {
            let index: Int
            let ok: Bool
            let advice: String
        }

        let summary: String?
        let frames: [Frame]?
    }

    let text: String
    let findings: [Finding]
    let coach: Coach?
}

struct LipSample: Codable, Hashable {
    let index: Int
    let word: String
    let phoneId: String
    let time: Double
    let open: Double
    let width: Double

    enum CodingKeys: String, CodingKey {
        case index, word, time, open, width
        case phoneId = "phone_id"
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
