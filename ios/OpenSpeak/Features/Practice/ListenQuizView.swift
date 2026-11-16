import SwiftUI

/// Hear a sound, pick its IPA symbol.
struct ListenQuizView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress

    private struct Question {
        let answer: Phoneme
        let options: [Phoneme]
        var correctIndex: Int { options.firstIndex(of: answer) ?? 0 }
    }

    @State private var questions: [Question] = []
    @State private var index = 0
    @State private var score = 0
    @State private var state: AnswerState = .unanswered

    private let length = 10

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
        .inlineNavigationTitle("Nghe và nhận diện")
        .onAppear { if questions.isEmpty { start() } }
    }

    private func question(_ q: Question) -> some View {
        VStack(spacing: 22) {
            QuizHeader(index: index, total: questions.count, score: score)
            Spacer()
            Text("Âm bạn nghe được là gì?").font(.title3.bold())
            Button {
                SpeechPlayer.shared.speak(phoneme: q.answer)
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 110)
                    .background(Theme.hero, in: Circle())
            }
            .buttonStyle(.plain)
            Button("Nghe trong từ “\(q.answer.examples.first?.word ?? "")”") {
                if let word = q.answer.examples.first?.word { SpeechPlayer.shared.speak(word) }
            }
            .font(.subheadline)
            Spacer()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                    OptionButton(index: i, state: state, action: { answer(i, in: q) }) {
                        Text("/\(option.symbol)/")
                            .font(.system(.title, design: .serif).weight(.semibold))
                            .foregroundStyle(Theme.ink)
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
            if index < questions.count { autoplay() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!state.isAnswered)
        .opacity(state.isAnswered ? 1 : 0.5)
    }

    private func start() {
        let pool = content.phonemes
        questions = Array(pool.shuffled().prefix(length)).map { answer in
            // A distractor heard in the hint word ("dog" for /g/ next to /d/) would also be a right answer.
            let inHint = Set(answer.examples.first?.phones ?? [])
            let sameKind = pool.filter { $0.category == answer.category && ($0.id == answer.id || !inHint.contains($0.id)) }
            return Question(answer: answer, options: sameKind.options(including: answer, count: 4, where: { $0.id == $1.id }))
        }
        index = 0
        score = 0
        state = .unanswered
        autoplay()
    }

    private func autoplay() {
        guard index < questions.count else { return }
        let phoneme = questions[index].answer
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            SpeechPlayer.shared.speak(phoneme: phoneme)
        }
    }

    private func answer(_ i: Int, in q: Question) {
        let correct = i == q.correctIndex
        state = .answered(choice: i, correct: q.correctIndex)
        if correct { score += 1 }
        progress.gradeSound(q.answer.id, correct: correct)
        Haptics.result(success: correct)
    }
}
