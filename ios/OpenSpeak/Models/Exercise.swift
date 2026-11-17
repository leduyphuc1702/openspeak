import Foundation

/// One multiple-choice question about a sound, written by the server (by the LLM, checked against the
/// scorer's dictionary) or built on the device from the bundled minimal pairs.
struct Exercise: Codable, Hashable {
    enum Kind: String, Codable {
        /// Hear one word of a minimal pair, pick it.
        case pair
        /// Hear a whole sentence, pick the word that filled the gap.
        case gap
        /// See similarly spelled words, pick the only one with the sound.
        case spelling
    }

    let kind: Kind
    let sound: String
    let options: [PathLesson.Word]
    let answer: Int
    var text: String? = nil
    var sentence: String? = nil
    var noteVi: String? = nil
    var meaningVi: String? = nil
    var topic: String? = nil

    var correct: PathLesson.Word { options[answer] }

    /// What the speaker button reads before the learner answers; spelling questions are read only afterwards.
    var spoken: String? {
        switch kind {
        case .pair: return correct.word
        case .gap: return sentence
        case .spelling: return nil
        }
    }

    /// Pair and gap questions test hearing; spelling questions test reading.
    var testsHearing: Bool { kind != .spelling }

    static func pair(_ a: WordEntry, _ b: WordEntry, sound: String) -> Exercise {
        Exercise(kind: .pair, sound: sound, options: [PathLesson.Word(a), PathLesson.Word(b)], answer: Int.random(in: 0...1))
    }
}

extension PathLesson.Word {
    init(_ entry: WordEntry) {
        self.init(word: entry.word, ipa: entry.ipa, phones: entry.phones, meaningVi: nil)
    }
}

/// POST /v1/exercises
struct ExerciseRequest: Encodable {
    let sound: String
    let contrasts: [String]
    let level: String
    let topics: [String]
    let avoidWords: [String]
    let seed: Int
}

struct ExerciseSet: Decodable {
    let sound: String
    let contrast: String?
    let exercises: [Exercise]
    /// "llm" or "rules"
    let source: String
}

/// A checkpoint exam of the personal path (POST /v1/path/exam).
struct PathExam: Codable, Hashable, Identifiable {
    struct Word: Codable, Hashable {
        let word: String
        let ipa: String
        let phones: [String]
        let meaningVi: String?
        let sound: String
        let topic: String?

        var entry: WordEntry { WordEntry(word: word, ipa: ipa, phones: phones) }
    }

    struct Sentence: Codable, Hashable {
        let text: String
        let ipa: String
        let connectedIpa: String
        let links: [SentenceLink]
        let intonation: String
        let meaningVi: String?
        let sound: String
        let topic: String?
    }

    struct Topic: Codable, Hashable {
        let id: String
        let title: String
        /// How many of the exam's questions, words and sentences are about this topic.
        let items: Int
    }

    let index: Int
    let afterLesson: Int
    let title: String
    let sounds: [String]
    let difficulty: Int
    let listening: [Exercise]
    let words: [Word]
    let sentences: [Sentence]
    let topics: [Topic]
    let source: String

    var id: Int { index }
    var writtenByAI: Bool { source == "llm" }

    var keywords: [String] {
        words.map(\.word) + listening.flatMap { $0.options.map(\.word) }
    }
}

struct ExamResult: Codable, Hashable {
    var listeningRight: Int
    var listeningTotal: Int
    /// Average speaking score per exam sound, for the sounds that were scored.
    var speaking: [String: Int]
    var date: Date

    var listeningScore: Int? { listeningTotal == 0 ? nil : 100 * listeningRight / listeningTotal }

    var speakingScore: Int? {
        speaking.isEmpty ? nil : speaking.values.reduce(0, +) / speaking.count
    }

    /// Listening and speaking weigh the same; either alone counts when the other is missing.
    var score: Int? {
        let parts = [listeningScore, speakingScore].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +) / parts.count
    }
}
