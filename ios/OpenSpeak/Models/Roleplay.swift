import Foundation

struct RoleplayScenario: Codable, Hashable, Identifiable {
    struct Task: Codable, Hashable {
        let en: String
        let vi: String
    }

    let id: String
    let title: String
    let titleVi: String
    let minutes: String
    let level: String
    let partner: String
    let settingVi: String
    let tasks: [Task]
    let opening: String
}

struct RoleplayTurn: Codable, Hashable {
    struct Correction: Codable, Hashable {
        let original: String
        let better: String
        let explainVi: String
    }

    let reply: String
    let corrections: [Correction]
    let tasksDone: [Bool]
    let betterVersion: String?
    let hintVi: String?
}

struct RoleplayMessage: Identifiable {
    let id = UUID()
    let fromAI: Bool
    var text: String
    var corrections: [RoleplayTurn.Correction] = []
    var betterVersion: String?
    /// The learner's recording of a spoken turn, scored by the phoneme model.
    var audio: URL?
    var assessment: Assessment?
    var scoring = false
    var scoreError: String?
}
