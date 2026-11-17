import Foundation

/// One lesson of the endless personal path, as returned by POST /v1/path/next (decoded with convertFromSnakeCase).
struct PathLesson: Codable, Hashable, Identifiable {
    struct Word: Codable, Hashable {
        let word: String
        let ipa: String
        let phones: [String]
        let meaningVi: String?

        var entry: WordEntry { WordEntry(word: word, ipa: ipa, phones: phones) }
    }

    struct Pair: Codable, Hashable {
        let a: Word
        let b: Word
        let contrast: [String]
    }

    struct Sentence: Codable, Hashable {
        let text: String
        let ipa: String
        let connectedIpa: String
        let links: [SentenceLink]
        let intonation: String
        let meaningVi: String?
    }

    let index: Int
    let title: String
    let focus: String
    let contrast: String?
    let difficulty: Int
    let reasonVi: String
    let tipVi: String?
    let words: [Word]
    let pairs: [Pair]
    let sentences: [Sentence]
    /// Listening and spelling questions; missing in lessons saved before the server wrote them.
    let exercises: [Exercise]?
    /// "llm" when a language model wrote the lesson, "rules" when the server assembled it from its own word lists.
    let source: String

    var id: Int { index }
    var writtenByAI: Bool { source == "llm" }

    var difficultyTitle: String {
        switch difficulty {
        case 1: return "Dễ"
        case 2: return "Vừa"
        default: return "Khó"
        }
    }
}

/// What the learner did in a personal-path lesson.
struct PathResult: Codable, Hashable {
    /// Average score of the lesson's sound across every take in the lesson; nil if nothing was scored.
    var score: Int?
    var date: Date
}

/// The learner profile the server plans the next lesson from.
struct PathRequest: Encodable {
    struct Sound: Encodable {
        let id: String
        let speak: Double?
        let takes: Int
        let heardRight: Int
        let heardWrong: Int
        let learned: Bool
    }

    struct Record: Encodable {
        let index: Int
        let focus: String
        let contrast: String?
        let difficulty: Int
        let score: Int?
    }

    let level: String
    let topics: [String]
    let nextIndex: Int
    let sounds: [Sound]
    let skills: [String: Int]
    let history: [Record]
    let recentWords: [String]
    /// Set when asking for a checkpoint exam instead of a lesson.
    var examIndex: Int? = nil
}
