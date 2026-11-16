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

struct RoleplayMessage: Identifiable, Hashable {
    let id = UUID()
    let fromAI: Bool
    let text: String
    var corrections: [RoleplayTurn.Correction] = []
    var betterVersion: String?
}
