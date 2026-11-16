import Foundation

struct WordEntry: Codable, Hashable, Identifiable {
    let word: String
    let ipa: String
    let phones: [String]

    var id: String { word }
}

struct ArticulationPose: Codable, Hashable {
    let lips: String            // closed, rounded, spread, neutral, labiodental
    let jaw: Double             // 0 closed ... 1 wide open
    let tongueHeight: Double
    let tongueFront: Double
    let tip: String             // rest, dental, alveolar, postalveolar, retroflex
    let contact: Bool
    let backContact: Bool

    static let rest = ArticulationPose(lips: "neutral", jaw: 0.2, tongueHeight: 0.45, tongueFront: 0.5,
                                       tip: "rest", contact: false, backContact: false)
}

struct Articulation: Codable, Hashable {
    let start: ArticulationPose
    let end: ArticulationPose?
    let voiced: Bool
    let nasal: Bool
    let manner: String
}

struct Phoneme: Codable, Hashable, Identifiable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case vowel, diphthong, consonant

        var id: String { rawValue }

        var title: String {
            switch self {
            case .vowel: return "Nguyên âm đơn"
            case .diphthong: return "Nguyên âm đôi"
            case .consonant: return "Phụ âm"
            }
        }
    }

    let id: String
    let symbol: String
    let category: Category
    let group: String
    let voiced: Bool?
    let examples: [WordEntry]
    let tip: String
    let speakIPA: String
    let articulation: Articulation
    let steps: [String]
}

struct CourseUnit: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let sounds: [String]
    let confusables: [String]
}

struct MinimalPair: Codable, Hashable, Identifiable {
    let id: String
    let a: WordEntry
    let b: WordEntry
    let contrast: [String]
    let note: String?
}

struct SentenceLink: Codable, Hashable {
    let display: String
    let type: String
    let hint: String
}

struct PracticeSentence: Codable, Hashable, Identifiable {
    let id: String
    let text: String
    let ipa: String
    let connectedIPA: String
    let links: [SentenceLink]
    let level: Int
    let intonation: String

    var levelTitle: String {
        switch level {
        case 1: return "Cơ bản"
        case 2: return "Trung bình"
        default: return "Nâng cao"
        }
    }
}

struct Topic: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let icon: String
}
