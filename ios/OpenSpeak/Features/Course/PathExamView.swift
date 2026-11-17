import SwiftUI

/// A checkpoint exam of the personal path: listening and spelling questions, then words and sentences
/// to say, all on the sounds of the last lessons and the learner's topics.
struct PathExamView: View {
    let exam: PathExam

    enum Step: Int, CaseIterable {
        case intro, listen, words, sentences, done

        var title: String {
            switch self {
            case .intro: return "Bài kiểm tra"
            case .listen: return "Nghe và nhận âm"
            case .words: return "Nói từ"
            case .sentences: return "Nói câu"
            case .done: return "Kết quả"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var step: Step = .intro
    @State private var right = 0
    @State private var answered = 0

    private var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .listen: return !exam.listening.isEmpty
            case .words: return !exam.words.isEmpty
            case .sentences: return !exam.sentences.isEmpty
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .environment(\.lessonStepTitle, step.title)
        .screenBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear { progress.startExam(exam) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                progress.abandonPathLesson()
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Đóng")
            .padding(.leading, -12)
            ProgressView(value: Double(steps.firstIndex(of: step) ?? 0), total: Double(max(steps.count - 1, 1)))
                .tint(Theme.good)
                .scaleEffect(x: 1, y: 2)
            Text("Kiểm tra \(exam.index)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .intro:
            ExamIntroStep(exam: exam, symbols: symbols, next: advance)
        case .listen:
            ListenStep(questions: exam.listening,
                       source: exam.writtenByAI ? "AI ra đề theo chủ đề của bạn" : "Ra đề tự động từ kho từ của máy chủ",
                       onAnswer: { question, correct in
                           answered += 1
                           if correct { right += 1 }
                           if question.testsHearing { progress.recordHearing(question.sound, correct: correct) }
                       },
                       next: advance)
        case .words:
            PathSpeakStep(hint: "Nói từng từ. AI chấm riêng âm được kiểm tra trong mỗi từ (tô màu).",
                          items: exam.words.map { word in
                              (item: PracticeItem(word: word.entry, focus: word.sound), entry: word.entry, meaning: word.meaningVi)
                          },
                          focus: exam.sounds.first ?? "", next: advance)
        case .sentences:
            PathSpeakStep(hint: "Đọc cả câu, chú ý các âm \(symbols) và chỗ nối âm.",
                          items: exam.sentences.map { sentence in
                              (item: PracticeItem(key: "p:\(sentence.text.lowercased())", text: sentence.text, ipa: sentence.ipa,
                                                  connectedIPA: sentence.connectedIpa, links: sentence.links,
                                                  intonation: sentence.intonation, focusPhone: sentence.sound),
                               entry: nil, meaning: sentence.meaningVi)
                          },
                          focus: exam.sounds.first ?? "", next: advance)
        case .done:
            ExamDoneStep(exam: exam, result: ExamResult(listeningRight: right, listeningTotal: answered,
                                                        speaking: progress.examSpeaking, date: .now),
                         symbol: symbol) {
                progress.finishExam(exam, listeningRight: right, listeningTotal: answered)
                dismiss()
            }
        }
    }

    private func symbol(_ id: String) -> String { "/\(content.phoneme(id)?.symbol ?? id)/" }

    private var symbols: String { exam.sounds.map(symbol).joined(separator: " ") }

    private func advance() {
        Haptics.tap()
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) { step = steps[index + 1] }
    }
}

private struct ExamIntroStep: View {
    let exam: PathExam
    let symbols: String
    let next: () -> Void

    var body: some View {
        LessonStepLayout {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44))
                Text(symbols).font(.system(size: 44, weight: .bold, design: .serif))
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Theme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(exam.title).font(.title3.bold()).foregroundStyle(Theme.ink)
                Text("\(exam.listening.count) câu nghe và chính tả · \(exam.words.count) từ · \(exam.sentences.count) câu để nói")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Label(exam.writtenByAI ? "AI ra đề cho bạn" : "Ra đề tự động (không dùng AI)",
                      systemImage: exam.writtenByAI ? "sparkles" : "list.bullet.rectangle")
                    .font(.caption.bold()).foregroundStyle(Theme.accent)
                Text("Kiểm tra các âm của bài \(max(exam.afterLesson - ProgressStore.lessonsPerExam + 1, 1))–\(exam.afterLesson) và âm bạn cần luyện nhất. Mỗi từ khoá chỉ xuất hiện một lần, không lặp lại từ của các bài gần đây.")
                    .font(.subheadline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                Text("Chủ đề trong đề").font(.headline)
                ForEach(exam.topics, id: \.id) { topic in
                    HStack {
                        Text(topic.title).font(.subheadline)
                        Spacer()
                        Text("\(topic.items) mục").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
        } actions: {
            Button("Bắt đầu kiểm tra", action: next).buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct ExamDoneStep: View {
    let exam: PathExam
    let result: ExamResult
    let symbol: (String) -> String
    let finish: () -> Void

    var body: some View {
        LessonStepLayout {
            HStack(spacing: 16) {
                ScoreRing(score: result.score, size: 96, lineWidth: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Xong bài kiểm tra \(exam.index)").font(.title3.bold()).foregroundStyle(Theme.ink)
                    if let listening = result.listeningScore {
                        Text("Nghe và nhận âm: \(result.listeningRight)/\(result.listeningTotal) câu đúng (\(listening))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(result.speakingScore.map { "Nói: trung bình \($0) điểm" } ?? "Nói: chưa có lượt nào được chấm")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("Điểm nói theo âm").font(.headline)
                ForEach(exam.sounds, id: \.self) { sound in
                    HStack {
                        Text(symbol(sound)).font(.system(.title3, design: .serif).weight(.semibold))
                        Spacer()
                        if let score = result.speaking[sound] {
                            Text("\(score)").font(.headline.monospacedDigit()).foregroundStyle(Theme.scoreColor(score))
                        } else {
                            Text("chưa chấm").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)

            Text("+40 XP · Điểm nghe và nói ở đây được tính vào hồ sơ của bạn, nên âm nào thấp sẽ được ưu tiên ở bài tiếp theo.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Hoàn thành", action: finish).buttonStyle(PrimaryButtonStyle(color: Theme.good))
        }
        .onAppear { Haptics.result(success: true) }
    }
}
