import SwiftUI

/// See a transcription, pick the word it spells.
struct ReadIPAQuizView: View {
    @Environment(ContentStore.self) private var content

    private struct Question {
        let answer: WordEntry
        let options: [WordEntry]
        var correctIndex: Int { options.firstIndex(of: answer) ?? 0 }
    }

    @State private var questions: [Question] = []
    @State private var index = 0
    @State private var score = 0
    @State private var state: AnswerState = .unanswered

    var body: some View {
        Group {
            if questions.isEmpty {
                ProgressView()
            } else if index >= questions.count {
                QuizSummaryView(score: score, total: questions.count, restart: start)
            } else {
                question(questions[index])
                    .scrollingWhenNeeded()
                    .actionBar { continueButton }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .inlineNavigationTitle("Đọc phiên âm")
        .onAppear { if questions.isEmpty { start() } }
    }

    private func question(_ q: Question) -> some View {
        VStack(spacing: 22) {
            QuizHeader(index: index, total: questions.count, score: score)
            Spacer()
            Text("Phiên âm này là từ nào?").font(.title3.bold())
            Text("/\(q.answer.ipa)/")
                .font(.system(size: 44, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .card()
            Text("Mẹo: ˈ đứng trước âm tiết được nhấn mạnh.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                    OptionButton(index: i, state: state, action: { answer(i, in: q) }) {
                        Text(option.word)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(20)
    }

    private var continueButton: some View {
        Button("Tiếp tục") {
            state = .unanswered
            index += 1
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!state.isAnswered)
        .opacity(state.isAnswered ? 1 : 0.5)
    }

    private func start() {
        let pool = content.readingWords
        questions = Array(pool.shuffled().prefix(10)).map { answer in
            Question(answer: answer, options: ([answer] + Self.lookalikes(of: answer, in: pool)).shuffled())
        }
        index = 0
        score = 0
        state = .unanswered
    }

    /// Three words that sound and look most like the answer, so the first letter or the length of the
    /// transcription does not give it away; random ones let the first letter alone pick the answer about half the time.
    static func lookalikes(of answer: WordEntry, in pool: [WordEntry]) -> [WordEntry] {
        func similarity(_ w: WordEntry) -> Double {
            let a = Set(answer.phones), b = Set(w.phones)
            var score = Double(a.intersection(b).count) / Double(max(a.union(b).count, 1))
            if w.phones.first == answer.phones.first { score += 1 }
            if w.word.first == answer.word.first { score += 1 }
            score -= Double(abs(w.phones.count - answer.phones.count)) * 0.2
            return score
        }
        let ranked = pool.filter { $0.word != answer.word }.sorted { similarity($0) > similarity($1) }
        return Array(ranked.prefix(5).shuffled().prefix(3))
    }

    private func answer(_ i: Int, in q: Question) {
        let correct = i == q.correctIndex
        state = .answered(choice: i, correct: q.correctIndex)
        if correct { score += 1 }
        Haptics.result(success: correct)
        SpeechPlayer.shared.speak(q.answer.word)
    }
}
