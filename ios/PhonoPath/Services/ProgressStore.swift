import Foundation
import Observation

/// Everything the learner has done, persisted locally.
@Observable
final class ProgressStore {
    /// Leitner-style spaced repetition card for a sound symbol or a vocabulary word.
    struct ReviewCard: Codable, Hashable {
        var box: Int = 0          // 0...5; higher = longer interval
        var due: Date = .now

        static let intervals: [Double] = [0, 1, 2, 4, 8, 16] // days

        mutating func grade(correct: Bool, now: Date = .now) {
            box = correct ? min(box + 1, Self.intervals.count - 1) : 0
            due = now.addingTimeInterval(Self.intervals[box] * 86_400)
        }
    }

    private struct Snapshot: Codable {
        var completedLessons: Set<String> = []          // phoneme ids whose lesson is finished
        var soundCards: [String: ReviewCard] = [:]
        var wordCards: [String: ReviewCard] = [:]
        var savedWords: [String: VocabWord] = [:]
        var soundScores: [String: [Int]] = [:]          // recent per-sound speaking scores
        var bestSentenceScores: [String: Int] = [:]
        var xpByDay: [String: Int] = [:]                // "yyyy-MM-dd" -> xp
        var listeningCorrect: [String: Int] = [:]
        var skillScores: [String: [Int]] = [:]          // "pronunciation", "fluency", ... -> recent scores
        var roleplayTurns: Int = 0
        var roleplayTasks: Int = 0

        init() {}

        /// Missing keys fall back to defaults, so adding a field never wipes saved progress.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            completedLessons = try c.decodeIfPresent(Set<String>.self, forKey: .completedLessons) ?? []
            soundCards = try c.decodeIfPresent([String: ReviewCard].self, forKey: .soundCards) ?? [:]
            wordCards = try c.decodeIfPresent([String: ReviewCard].self, forKey: .wordCards) ?? [:]
            savedWords = try c.decodeIfPresent([String: VocabWord].self, forKey: .savedWords) ?? [:]
            soundScores = try c.decodeIfPresent([String: [Int]].self, forKey: .soundScores) ?? [:]
            bestSentenceScores = try c.decodeIfPresent([String: Int].self, forKey: .bestSentenceScores) ?? [:]
            xpByDay = try c.decodeIfPresent([String: Int].self, forKey: .xpByDay) ?? [:]
            listeningCorrect = try c.decodeIfPresent([String: Int].self, forKey: .listeningCorrect) ?? [:]
            skillScores = try c.decodeIfPresent([String: [Int]].self, forKey: .skillScores) ?? [:]
            roleplayTurns = try c.decodeIfPresent(Int.self, forKey: .roleplayTurns) ?? 0
            roleplayTasks = try c.decodeIfPresent(Int.self, forKey: .roleplayTasks) ?? 0
        }
    }

    private var snapshot: Snapshot {
        didSet { save() }
    }
    private let defaults: UserDefaults
    private let key = "progress.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = Snapshot()
        }
    }

    // MARK: IPA course

    func isLessonDone(_ id: String) -> Bool { snapshot.completedLessons.contains(id) }

    func completeLesson(_ id: String) {
        snapshot.completedLessons.insert(id)
        if snapshot.soundCards[id] == nil {
            var card = ReviewCard()
            card.grade(correct: true)
            snapshot.soundCards[id] = card
        }
        addXP(20)
    }

    func unitProgress(_ unit: CourseUnit) -> Double {
        guard !unit.sounds.isEmpty else { return 0 }
        return Double(unit.sounds.filter(isLessonDone).count) / Double(unit.sounds.count)
    }

    func isUnitUnlocked(_ unit: CourseUnit, in units: [CourseUnit]) -> Bool {
        guard let index = units.firstIndex(of: unit), index > 0 else { return true }
        return unitProgress(units[index - 1]) >= 1
    }

    func courseProgress(_ phonemes: [Phoneme]) -> Double {
        guard !phonemes.isEmpty else { return 0 }
        return Double(phonemes.filter { isLessonDone($0.id) }.count) / Double(phonemes.count)
    }

    func dueSounds(now: Date = .now) -> [String] {
        snapshot.soundCards.filter { $0.value.due <= now }.map(\.key).sorted()
    }

    func gradeSound(_ id: String, correct: Bool) {
        var card = snapshot.soundCards[id] ?? ReviewCard()
        card.grade(correct: correct)
        snapshot.soundCards[id] = card
        if correct {
            snapshot.listeningCorrect[id, default: 0] += 1
            addXP(2)
        }
    }

    // MARK: Speaking

    func record(_ assessment: Assessment, key: String) {
        if let overall = assessment.scores.overall {
            snapshot.bestSentenceScores[key] = max(overall, snapshot.bestSentenceScores[key] ?? 0)
            addXP(5 + overall / 20)
        }
        let s = assessment.scores
        for (name, value) in [("pronunciation", s.pronunciation), ("fluency", s.fluency), ("intonation", s.intonation),
                              ("stress", s.stress), ("linking", s.linking)] {
            guard let value else { continue }
            snapshot.skillScores[name, default: []].append(value)
            snapshot.skillScores[name] = Array(snapshot.skillScores[name]!.suffix(30))
        }
        for word in assessment.words {
            for phone in word.phones {
                guard let id = phone.id, let score = phone.score else { continue }
                snapshot.soundScores[id, default: []].append(score)
                snapshot.soundScores[id] = Array(snapshot.soundScores[id]!.suffix(20))
            }
        }
    }

    func bestScore(_ key: String) -> Int? { snapshot.bestSentenceScores[key] }

    /// Average of the learner's recent speaking scores for a sound.
    func soundSkill(_ id: String) -> Int? {
        guard let scores = snapshot.soundScores[id], !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    /// Recent average for one radar axis (pronunciation, fluency, intonation, stress, linking).
    func skill(_ name: String) -> Int? {
        guard let scores = snapshot.skillScores[name], !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    /// How many scored takes back the pronunciation axis (capped by the recent-score window).
    var scoredTakeCount: Int { snapshot.skillScores["pronunciation"]?.count ?? 0 }

    /// Share of saved words currently remembered (not due, box >= 2).
    var vocabularySkill: Int? {
        guard !snapshot.wordCards.isEmpty else { return nil }
        let strong = snapshot.wordCards.values.filter { $0.box >= 2 }.count
        return 100 * strong / snapshot.wordCards.count
    }

    var masteredSoundCount: Int { snapshot.soundCards.values.filter { $0.box >= 3 }.count }

    // MARK: AI roleplay

    func recordRoleplayTurn(newTasksDone: Int) {
        snapshot.roleplayTurns += 1
        snapshot.roleplayTasks += newTasksDone
        addXP(3 + 5 * newTasksDone)
    }

    var roleplayTurns: Int { snapshot.roleplayTurns }

    // MARK: Vocabulary

    func save(_ word: VocabWord) {
        snapshot.savedWords[word.id] = word
        if snapshot.wordCards[word.id] == nil { snapshot.wordCards[word.id] = ReviewCard() }
    }

    func gradeWord(_ word: VocabWord, remembered: Bool) {
        save(word)
        snapshot.wordCards[word.id]?.grade(correct: remembered)
        addXP(remembered ? 3 : 1)
    }

    var savedWords: [VocabWord] { snapshot.savedWords.values.sorted { $0.word < $1.word } }

    var knownWordList: [String] { snapshot.savedWords.values.map(\.word) }

    func dueWords(now: Date = .now) -> [VocabWord] {
        snapshot.wordCards.filter { $0.value.due <= now }.compactMap { snapshot.savedWords[$0.key] }
    }

    func isSaved(_ word: VocabWord) -> Bool { snapshot.savedWords[word.id] != nil }

    // MARK: Streak and daily goal

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayKey(_ date: Date) -> String { Self.dayFormatter.string(from: date) }

    func addXP(_ amount: Int, now: Date = .now) {
        snapshot.xpByDay[dayKey(now), default: 0] += amount
    }

    func xpToday(now: Date = .now) -> Int { snapshot.xpByDay[dayKey(now)] ?? 0 }

    var totalXP: Int { snapshot.xpByDay.values.reduce(0, +) }

    /// Consecutive days with any XP, ending today (or yesterday if today is still empty).
    func streak(now: Date = .now) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        var day = now
        if (snapshot.xpByDay[dayKey(day)] ?? 0) == 0 {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var count = 0
        while (snapshot.xpByDay[dayKey(day)] ?? 0) > 0 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    func reset() { snapshot = Snapshot() }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}
