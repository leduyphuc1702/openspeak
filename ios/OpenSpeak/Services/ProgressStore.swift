import Foundation
import Observation

/// Everything the learner has done, persisted locally.
@Observable
final class ProgressStore {
    /// Leitner-style spaced repetition card for a sound symbol or a vocabulary word.
    struct ReviewCard: Codable, Hashable {
        var box: Int = 0          // 0...5; higher = longer interval
        var due: Date = .now
        var lapses: Int? = nil    // times answered wrong

        static let intervals: [Double] = [0, 1, 2, 4, 8, 16] // days

        mutating func grade(correct: Bool, now: Date = .now) {
            box = correct ? min(box + 1, Self.intervals.count - 1) : 0
            if !correct { lapses = (lapses ?? 0) + 1 }
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
        var listeningWrong: [String: Int] = [:]
        var pathLessons: [PathLesson] = []
        var pathResults: [String: PathResult] = [:]     // lesson index -> result
        var pathExams: [PathExam] = []
        var examResults: [String: ExamResult] = [:]     // exam index -> result
        var vocabLessons: [VocabPathLesson] = []
        var vocabResults: [String: Int] = [:]           // vocabulary lesson index -> words remembered

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
            listeningWrong = try c.decodeIfPresent([String: Int].self, forKey: .listeningWrong) ?? [:]
            // Lessons come from the server; if their shape changes, drop them rather than every other field.
            pathLessons = (try? c.decodeIfPresent([PathLesson].self, forKey: .pathLessons)) ?? []
            pathResults = (try? c.decodeIfPresent([String: PathResult].self, forKey: .pathResults)) ?? [:]
            pathExams = (try? c.decodeIfPresent([PathExam].self, forKey: .pathExams)) ?? []
            examResults = (try? c.decodeIfPresent([String: ExamResult].self, forKey: .examResults)) ?? [:]
            vocabLessons = (try? c.decodeIfPresent([VocabPathLesson].self, forKey: .vocabLessons)) ?? []
            vocabResults = (try? c.decodeIfPresent([String: Int].self, forKey: .vocabResults)) ?? [:]
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
        } else {
            snapshot.listeningWrong[id, default: 0] += 1
        }
    }

    /// A listening answer inside a lesson: counted for planning, without touching the review schedule.
    func recordHearing(_ id: String, correct: Bool) {
        if correct {
            snapshot.listeningCorrect[id, default: 0] += 1
        } else {
            snapshot.listeningWrong[id, default: 0] += 1
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
                if tallySounds.contains(id) { tally[id, default: []].append(score) }
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

    // MARK: Personal path

    /// Scores of the sounds being tested, collected while a personal-path lesson or exam is open.
    @ObservationIgnored private var tallyOwner: String?
    @ObservationIgnored private var tallySounds: Set<String> = []
    @ObservationIgnored private var tally: [String: [Int]] = [:]

    private func startTally(_ owner: String, sounds: [String]) {
        guard tallyOwner != owner else { return }
        tallyOwner = owner
        tallySounds = Set(sounds)
        tally = [:]
    }

    var pathLessons: [PathLesson] { snapshot.pathLessons }

    func pathResult(_ lesson: PathLesson) -> PathResult? { snapshot.pathResults[String(lesson.index)] }

    /// The first lesson that has been written but not finished.
    var currentPathLesson: PathLesson? { snapshot.pathLessons.first { pathResult($0) == nil } }

    func addPathLesson(_ lesson: PathLesson) {
        snapshot.pathLessons.removeAll { $0.index == lesson.index }
        snapshot.pathLessons.append(lesson)
    }

    /// Safe to call again on the same lesson (e.g. when the view reappears after a sheet).
    func startPathLesson(_ lesson: PathLesson) {
        startTally("lesson:\(lesson.index)", sounds: [lesson.focus])
    }

    var pathLessonScore: Int? {
        let all = tally.values.flatMap { $0 }
        return all.isEmpty ? nil : all.reduce(0, +) / all.count
    }

    func finishPathLesson(_ lesson: PathLesson) {
        snapshot.pathResults[String(lesson.index)] = PathResult(score: pathLessonScore, date: .now)
        abandonPathLesson()
        addXP(25)
    }

    func abandonPathLesson() {
        tallyOwner = nil
        tallySounds = []
        tally = [:]
    }

    // MARK: Path exams

    static let lessonsPerExam = 4

    var pathExams: [PathExam] { snapshot.pathExams }

    func examResult(_ exam: PathExam) -> ExamResult? { snapshot.examResults[String(exam.index)] }

    /// The exam that is due: one after every `lessonsPerExam` finished lessons, until it is taken.
    var dueExamIndex: Int? {
        let finished = snapshot.pathLessons.filter { pathResult($0) != nil }.count
        let index = finished / Self.lessonsPerExam
        guard index >= 1, snapshot.examResults[String(index)] == nil else { return nil }
        return index
    }

    var dueExam: PathExam? {
        guard let index = dueExamIndex else { return nil }
        return snapshot.pathExams.first { $0.index == index }
    }

    func addExam(_ exam: PathExam) {
        snapshot.pathExams.removeAll { $0.index == exam.index }
        snapshot.pathExams.append(exam)
    }

    func startExam(_ exam: PathExam) {
        startTally("exam:\(exam.index)", sounds: exam.sounds)
    }

    /// Average speaking score per exam sound so far.
    var examSpeaking: [String: Int] {
        tally.compactMapValues { $0.isEmpty ? nil : $0.reduce(0, +) / $0.count }
    }

    func finishExam(_ exam: PathExam, listeningRight: Int, listeningTotal: Int) {
        snapshot.examResults[String(exam.index)] = ExamResult(listeningRight: listeningRight, listeningTotal: listeningTotal,
                                                              speaking: examSpeaking, date: .now)
        abandonPathLesson()
        addXP(40)
    }

    func examRequest(level: String, topics: [String], index: Int) -> PathRequest {
        var request = pathRequest(level: level, topics: topics)
        request.examIndex = index
        return request
    }

    /// Everything the server needs to plan the next lesson: per-sound results, skills and recent lessons.
    func pathRequest(level: String, topics: [String]) -> PathRequest {
        let ids = Set(snapshot.soundScores.keys).union(snapshot.listeningCorrect.keys)
            .union(snapshot.listeningWrong.keys).union(snapshot.completedLessons)
        let sounds = ids.sorted().map { id -> PathRequest.Sound in
            let scores = snapshot.soundScores[id] ?? []
            return PathRequest.Sound(id: id, speak: scores.isEmpty ? nil : Double(scores.reduce(0, +)) / Double(scores.count),
                                     takes: scores.count, heardRight: snapshot.listeningCorrect[id] ?? 0,
                                     heardWrong: snapshot.listeningWrong[id] ?? 0, learned: isLessonDone(id))
        }
        let history = snapshot.pathLessons.suffix(10).map {
            PathRequest.Record(index: $0.index, focus: $0.focus, contrast: $0.contrast, difficulty: $0.difficulty,
                               score: pathResult($0)?.score)
        }
        var skills: [String: Int] = [:]
        for name in ["pronunciation", "fluency", "intonation", "stress", "linking"] {
            if let value = skill(name) { skills[name] = value }
        }
        return PathRequest(level: level, topics: topics, nextIndex: (snapshot.pathLessons.map(\.index).max() ?? 0) + 1,
                           sounds: sounds, skills: skills, history: Array(history),
                           recentWords: snapshot.pathLessons.suffix(12).flatMap { $0.words.map(\.word) }
                               + snapshot.pathExams.suffix(3).flatMap(\.keywords))
    }

    #if DEBUG
    /// UI tests: a learner who is weak at /r/ and mixes up /ɪ/, with no personal lessons yet.
    func seedForUITests(finishedSounds: [String]) {
        snapshot.soundScores = ["R": [45, 52, 40, 48, 50, 44], "TH": [88, 91, 86, 90], "L": [72, 70, 75], "IY": [80, 84]]
        snapshot.listeningCorrect = ["IH": 1]
        snapshot.listeningWrong = ["IH": 3]
        snapshot.completedLessons = Set(finishedSounds)
        snapshot.pathLessons = []
        snapshot.pathResults = [:]
        snapshot.pathExams = []
        snapshot.examResults = [:]
    }

    /// UI tests: the same learner after four finished path lessons, so the first exam is due.
    func seedFinishedLessons(_ focuses: [String], symbol: (String) -> String) {
        snapshot.pathLessons = focuses.enumerated().map { i, focus in
            PathLesson(index: i + 1, title: "Âm /\(symbol(focus))/", focus: focus, contrast: nil, difficulty: 2,
                       reasonVi: "Bài mẫu cho kiểm thử.", tipVi: nil, words: [], pairs: [], sentences: [],
                       exercises: nil, source: "rules")
        }
        snapshot.pathResults = Dictionary(uniqueKeysWithValues: focuses.indices.map {
            (String($0 + 1), PathResult(score: 60 + 5 * $0, date: .now))
        })
    }
    #endif

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

    /// Due words, the longest overdue first.
    func dueWords(now: Date = .now) -> [VocabWord] {
        snapshot.wordCards.filter { $0.value.due <= now }.sorted { $0.value.due < $1.value.due }
            .compactMap { snapshot.savedWords[$0.key] }
    }

    func isSaved(_ word: VocabWord) -> Bool { snapshot.savedWords[word.id] != nil }

    /// Words answered wrong at least once and not yet remembered twice in a row since.
    var weakWords: [String] {
        snapshot.wordCards.filter { ($0.value.lapses ?? 0) > 0 && $0.value.box <= 1 }
            .compactMap { snapshot.savedWords[$0.key]?.word }.sorted()
    }

    /// Words remembered at the longest intervals (a week or more).
    var masteredWordCount: Int { snapshot.wordCards.values.filter { $0.box >= 3 }.count }

    // MARK: Vocabulary programme

    var currentVocabLesson: VocabPathLesson? {
        snapshot.vocabLessons.first { snapshot.vocabResults[String($0.index)] == nil }
    }

    var finishedVocabLessons: Int { snapshot.vocabResults.count }

    func vocabRequest(level: String, topics: [String]) -> VocabPathRequest {
        VocabPathRequest(level: level, topics: topics,
                         lessonIndex: (snapshot.vocabLessons.map(\.index).max() ?? 0) + 1,
                         known: knownWordList, weak: weakWords)
    }

    func startVocabLesson(_ lesson: VocabPathLesson) {
        snapshot.vocabLessons.removeAll { $0.index == lesson.index }
        snapshot.vocabLessons.append(lesson)
        snapshot.vocabLessons = Array(snapshot.vocabLessons.suffix(40))
    }

    /// Every word of the lesson goes into review: those answered right the first time are due tomorrow,
    /// the others come back in the next review.
    func finishVocabLesson(_ lesson: VocabPathLesson, remembered: [String: Bool]) {
        for word in lesson.words { gradeWord(word, remembered: remembered[word.id] ?? false) }
        snapshot.vocabResults[String(lesson.index)] = lesson.words.filter { remembered[$0.id] == true }.count
        addXP(25)
    }

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
