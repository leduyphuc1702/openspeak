import Foundation

/// One question about a sound, written by the server (by the LLM, checked against the scorer's dictionary)
/// or built on the device from the bundled minimal pairs. None of them is answered by picking one of a few
/// options: the learner marks, types, sorts or builds, and the app checks the answer itself.
struct Exercise: Codable, Hashable {
    enum Kind: String, Codable {
        /// Hear three readings of a minimal pair, mark each one.
        case sequence
        /// Hear a whole sentence, type the word that fills the gap.
        case dictation
        /// See similarly spelled words, mark every one that has the sound.
        case sort
        /// Hear a short word, build its transcription from symbol tiles.
        case build

        /// Lessons saved before these kinds existed had pair, gap and spelling questions.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "pair": self = .sequence
            case "gap": self = .dictation
            case "spelling": self = .sort
            default:
                guard let kind = Kind(rawValue: raw) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "kind \(raw)"))
                }
                self = kind
            }
        }
    }

    let kind: Kind
    let sound: String
    let options: [PathLesson.Word]
    let answer: Int
    /// sequence: which option is read each time.
    var order: [Int]? = nil
    /// sort: whether each option has the sound.
    var marks: [Bool]? = nil
    /// build: the symbols to choose from, and the transcription in order.
    var tiles: [String]? = nil
    var solution: [String]? = nil
    /// dictation: spellings counted as right (the word and its homophones).
    var accept: [String]? = nil
    var text: String? = nil
    var sentence: String? = nil
    var noteVi: String? = nil
    var meaningVi: String? = nil
    var topic: String? = nil

    var correct: PathLesson.Word { options[answer] }

    /// Sequence, dictation and build questions test hearing; sort questions test reading.
    var testsHearing: Bool { kind != .sort }

    /// The words worth hearing again or prefetching for this question.
    var words: [String] { options.map(\.word) }

    /// Offline fallback from a bundled minimal pair. Both words are read, so the answer is never the same word three times.
    static func sequence(_ a: WordEntry, _ b: WordEntry, sound: String) -> Exercise {
        let order = ([0, 1] + [Int.random(in: 0...1)]).shuffled()
        return Exercise(kind: .sequence, sound: sound, options: [PathLesson.Word(a), PathLesson.Word(b)], answer: 0, order: order)
    }

    /// Whether a typed dictation answer is right: case, spaces and curly apostrophes do not matter.
    func accepts(_ typed: String) -> Bool {
        let clean = Self.normalised(typed)
        return (accept ?? [correct.word]).contains { Self.normalised($0) == clean }
    }

    static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(["'"])))
            .replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }
}

extension Exercise {
    /// Saved lessons from before the current kinds lack their answers in the new shape; derive them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        sound = try c.decode(String.self, forKey: .sound)
        options = try c.decode([PathLesson.Word].self, forKey: .options)
        answer = try c.decode(Int.self, forKey: .answer)
        order = try c.decodeIfPresent([Int].self, forKey: .order)
        marks = try c.decodeIfPresent([Bool].self, forKey: .marks)
        tiles = try c.decodeIfPresent([String].self, forKey: .tiles)
        solution = try c.decodeIfPresent([String].self, forKey: .solution)
        accept = try c.decodeIfPresent([String].self, forKey: .accept)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        sentence = try c.decodeIfPresent(String.self, forKey: .sentence)
        noteVi = try c.decodeIfPresent(String.self, forKey: .noteVi)
        meaningVi = try c.decodeIfPresent(String.self, forKey: .meaningVi)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        if kind == .sequence, order == nil, options.count == 2 { order = [answer, 1 - answer, answer] }
        if kind == .sort, marks == nil { marks = options.indices.map { $0 == answer } }
        if kind == .build, tiles == nil || solution == nil {
            throw DecodingError.dataCorruptedError(forKey: .tiles, in: c, debugDescription: "build without tiles")
        }
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
