import Foundation

/// Mirrors the JSON returned by the backend's POST /v1/assess.
struct Assessment: Codable {
    struct Scores: Codable {
        let overall: Int?
        let pronunciation: Int?
        let intonation: Int?
        let stress: Int?
        let fluency: Int?
        let linking: Int?
    }

    struct Link: Codable, Hashable {
        let index: Int
        let type: String
        let display: String
        let connectedIpa: String
        let hint: String
        let linked: Bool
        let gap: Double
        let problem: String?
        let flapRealized: Bool?
    }

    struct Linking: Codable {
        let connectedIpa: String
        let links: [Link]
    }

    struct Phone: Codable, Hashable {
        enum Status: String, Codable {
            case good, weak, substituted, missing
        }

        let id: String?
        let expected: String
        let heard: String?
        let heardId: String?
        let score: Int?
        let status: Status
        let start: Double
        let end: Double
    }

    struct Stress: Codable, Hashable {
        let expected: Int
        let detected: Int
        let correct: Bool
    }

    struct Word: Codable, Hashable, Identifiable {
        let word: String
        let ipa: String
        let score: Int?
        let start: Double
        let end: Double
        let stress: Stress?
        let phones: [Phone]

        var id: String { "\(word)@\(start)" }

        var worstPhone: Phone? {
            phones.filter { $0.status != .good }.min { ($0.score ?? 0) < ($1.score ?? 0) }
        }
    }

    struct Intonation: Codable {
        let expected: String
        let detected: String?
        let finalSlope: Double?
        let pitchRange: Double?
        let referenceSimilarity: Int?
    }

    struct Pause: Codable, Hashable {
        let start: Double
        let end: Double
    }

    struct Fluency: Codable {
        let syllablesPerSecond: Double
        let pauses: [Pause]
    }

    struct PitchContour: Codable {
        let user: [[Double]]
        let reference: [[Double]]?
    }

    let text: String
    let scores: Scores
    let words: [Word]
    let linking: Linking
    let heardPhones: [String]
    let intonation: Intonation
    let fluency: Fluency
    let pitchContour: PitchContour
    let feedback: String?
    /// Words left out of the score because the pronunciation dictionary lacks them (free speech only).
    var skippedWords: [String]? = nil
}

extension Assessment {
    static func decode(_ data: Data) throws -> Assessment {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Assessment.self, from: data)
    }
}
