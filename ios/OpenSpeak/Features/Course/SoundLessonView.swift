import SwiftUI

/// One sound, taught the way children learn letters: meet it, recognise it,
/// write it, hear it among similar sounds and spellings, then say it.
struct SoundLessonView: View {
    let phoneme: Phoneme
    let unit: CourseUnit

    enum Step: Int, CaseIterable {
        case meet, recognise, trace, listen, speak, done

        var title: String {
            switch self {
            case .meet: return "Làm quen"
            case .recognise: return "Nhận mặt ký hiệu"
            case .trace: return "Tô ký hiệu"
            case .listen: return "Nghe và nhận âm"
            case .speak: return "Nói thành tiếng"
            case .done: return "Hoàn thành"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var step: Step = .meet
    @State private var exercises: [Exercise]?
    @State private var exerciseSource: String?
    @AppStorage(Prefs.level) private var level = "beginner"
    @AppStorage(Prefs.topics) private var topicsRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
        }
        .environment(\.lessonStepTitle, step.title)
        .screenBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await loadExercises() }
    }

    /// Asked for while the learner is still on the first steps, so the questions are ready by the listening step.
    private func loadExercises() async {
        guard exercises == nil else { return }
        let request = ExerciseRequest(sound: phoneme.id, contrasts: unit.sounds + unit.confusables, level: level,
                                      topics: Prefs.topicIDs(topicsRaw), avoidWords: [], seed: Int.random(in: 0..<1_000_000))
        do {
            let set = try await APIClient.current().exercises(request)
            exercises = set.exercises
            exerciseSource = set.source == "llm" ? "AI soạn theo chủ đề của bạn" : "Soạn tự động từ kho từ của máy chủ"
        } catch {
            exercises = localPairs
            exerciseSource = "Không kết nối được máy chủ: chỉ có câu nghe cặp từ có sẵn trong app"
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Đóng")
            .padding(.leading, -12)
            ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                .tint(Theme.good)
                .scaleEffect(x: 1, y: 2)
            Text("/\(phoneme.symbol)/")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .meet:
            MeetStep(phoneme: phoneme, next: advance)
        case .recognise:
            RecogniseStep(phoneme: phoneme, options: symbolOptions, next: advance)
        case .trace:
            TraceView(symbol: phoneme.symbol, onSuccess: advance)
        case .listen:
            if let exercises {
                ListenStep(questions: exercises, source: exerciseSource,
                           onAnswer: { question, right in
                               if question.testsHearing { progress.recordHearing(phoneme.id, correct: right) }
                           },
                           next: advance)
            } else {
                LessonStepLayout {
                    ProgressView("Đang soạn câu hỏi cho âm /\(phoneme.symbol)/…")
                        .padding(.top, 40)
                } actions: {
                    Button("Bỏ qua bước này", action: advance)
                        .buttonStyle(PrimaryButtonStyle(color: Theme.subtle))
                }
            }
        case .speak:
            SpeakStep(phoneme: phoneme, words: Array(phoneme.examples.prefix(3)), next: advance)
        case .done:
            DoneStep(phoneme: phoneme) {
                progress.completeLesson(phoneme.id)
                dismiss()
            }
        }
    }

    private func advance() {
        Haptics.tap()
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { step = next }
    }

    /// The sound plus the sounds it is most easily confused with, then same-type fillers.
    private var symbolOptions: [Phoneme] {
        var pool = (unit.sounds + unit.confusables).filter { $0 != phoneme.id }.compactMap(content.phoneme)
        let fillers = content.phonemes(in: phoneme.category).filter { $0 != phoneme && !pool.contains($0) }.shuffled()
        pool += fillers
        return Array(pool.prefix(3)) + [phoneme]
    }

    /// Offline fallback: the bundled minimal pairs for this sound.
    private var localPairs: [Exercise] {
        content.minimalPairs.filter { $0.contrast.contains(phoneme.id) }.shuffled().prefix(4)
            .map { Exercise.sequence($0.a, $0.b, sound: phoneme.id) }
    }
}

// MARK: Steps

/// One step of a lesson: the step's title and content scroll, and its action stays pinned below.
struct LessonStepLayout<Content: View, Actions: View>: View {
    var showsActions = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @Environment(\.lessonStepTitle) private var title

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                content
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .actionBar(isPresented: showsActions) { actions }
    }
}

private struct LessonStepTitleKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var lessonStepTitle: String {
        get { self[LessonStepTitleKey.self] }
        set { self[LessonStepTitleKey.self] = newValue }
    }
}

private struct MeetStep: View {
    let phoneme: Phoneme
    let next: () -> Void

    var body: some View {
        LessonStepLayout {
            Button { SpeechPlayer.shared.speak(phoneme: phoneme) } label: {
                VStack(spacing: 6) {
                    Text(phoneme.symbol)
                        .font(.system(size: 110, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                    Label("Chạm để nghe", systemImage: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Đây là âm /\(phoneme.symbol)/ · \(phoneme.group)")
                .font(.headline)

            ArticulationCard(phoneme: phoneme)

            VStack(alignment: .leading, spacing: 10) {
                Text("Âm này trong từ").font(.headline)
                ForEach(phoneme.examples) { example in
                    Button { SpeechPlayer.shared.speak(example.word, slow: true) } label: {
                        HStack {
                            Text(example.word).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(IPATokenizer.highlighted(example, phonemeID: phoneme.id))
                                .font(.system(.title3, design: .serif))
                            Spacer()
                            Image(systemName: "speaker.wave.2").foregroundStyle(Theme.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
        } actions: {
            Button("Mình đã hiểu", action: next).buttonStyle(PrimaryButtonStyle())
        }
        .onAppear { SpeechPlayer.shared.speak(phoneme: phoneme) }
    }
}

/// Hear a sound, tap its symbol. The sound read out changes between the lesson's sound and the sounds it is
/// confused with, so tapping the symbol in the header is not the answer; only a right first tap counts.
private struct RecogniseStep: View {
    let phoneme: Phoneme
    let options: [Phoneme]
    let next: () -> Void

    private let rounds = 4
    @State private var correct = 0
    @State private var plan: [Phoneme] = []
    @State private var round = 0
    @State private var shuffled: [Phoneme] = []
    @State private var wrong: Phoneme?
    @State private var missed = false
    @State private var showRight = false

    private var target: Phoneme { plan[safe: round] ?? phoneme }

    var body: some View {
        LessonStepLayout(showsActions: showRight) {
            Text("Nghe rồi chạm vào ký hiệu của âm vừa đọc (đúng ngay \(correct)/\(rounds))")
                .font(.headline)
            Text("Âm được đọc có thể là /\(phoneme.symbol)/ hoặc một âm dễ nhầm với nó.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { SpeechPlayer.shared.speak(phoneme: target) } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 40))
                    .frame(width: 110, height: 110)
                    .background(Theme.primaryFill, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nghe lại")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(shuffled) { option in
                    Button { pick(option) } label: {
                        Text(option.symbol)
                            .font(.system(size: 48, weight: .bold, design: .serif))
                            .frame(maxWidth: .infinity, minHeight: 110)
                            .foregroundStyle(Theme.ink)
                            .background(tileColor(option), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(borderColor(option), lineWidth: 3))
                            .answerMark(showRight && option == target ? .right : option == wrong ? .wrong : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("symbol.\(option.id)")
                }
            }
            if let wrong {
                Text("Đó là /\(wrong.symbol)/. Nghe lại và thử lần nữa nhé (lượt này không tính).")
                    .font(.subheadline).foregroundStyle(Theme.bad)
            }
        } actions: {
            Label(missed ? "Đáp án: /\(target.symbol)/ · chưa tính lượt này" : "Chính xác: /\(target.symbol)/",
                  systemImage: missed ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .font(.headline).foregroundStyle(missed ? Theme.ok : Theme.good)
            Button("Tiếp") {
                if !missed { correct += 1 }
                if correct >= rounds { next() } else { newRound() }
            }
            .buttonStyle(PrimaryButtonStyle(color: missed ? Theme.primary : Theme.good))
        }
        .onAppear {
            guard plan.isEmpty else { return }
            round = -1
            newRound()
        }
    }

    private func tileColor(_ option: Phoneme) -> Color {
        if showRight && option == target { return Theme.good.opacity(0.2) }
        if option == wrong { return Theme.bad.opacity(0.15) }
        return Theme.surface
    }

    private func borderColor(_ option: Phoneme) -> Color {
        if showRight && option == target { return Theme.good }
        if option == wrong { return Theme.bad }
        return Theme.subtle
    }

    private func pick(_ option: Phoneme) {
        guard !showRight else { return }
        if option == target {
            showRight = true
            wrong = nil
            Haptics.result(success: !missed)
        } else {
            wrong = option
            missed = true
            Haptics.result(success: false)
            SpeechPlayer.shared.speak(phoneme: option)
        }
    }

    /// Half the rounds read the lesson's sound, the rest one of the confusable ones, in random order.
    private func newRound() {
        round += 1
        if round >= plan.count {
            let others = options.filter { $0 != phoneme }
            plan = (Array(repeating: phoneme, count: 2) + others.shuffled().prefix(2)).shuffled()
            round = 0
        }
        shuffled = options.shuffled()
        wrong = nil
        missed = false
        showRight = false
        SpeechPlayer.shared.speak(phoneme: target)
    }
}

/// Say the example words; the AI scores each sound. Can be skipped when offline.
private struct SpeakStep: View {
    let phoneme: Phoneme
    let words: [WordEntry]
    let next: () -> Void

    @Environment(ProgressStore.self) private var progress
    @State private var practising: PracticeItem?

    var body: some View {
        LessonStepLayout {
            Text("Nói từng từ. AI sẽ chấm riêng âm /\(phoneme.symbol)/.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(words) { word in
                let item = PracticeItem(word: word, focus: phoneme.id)
                Button { practising = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(word.word).font(.title3.bold()).foregroundStyle(Theme.ink)
                            Text(IPATokenizer.highlighted(word, phonemeID: phoneme.id))
                                .font(.system(.body, design: .serif))
                        }
                        Spacer()
                        if let best = progress.bestScore(item.key) {
                            ScoreRing(score: best, size: 44, lineWidth: 5)
                        } else {
                            Image(systemName: "mic.circle.fill").font(.largeTitle).foregroundStyle(Theme.primary)
                        }
                    }
                    .card()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("speak.\(word.word)")
            }
        } actions: {
            Button(attempted ? "Tiếp tục" : "Bỏ qua bước nói", action: next)
                .buttonStyle(PrimaryButtonStyle(color: attempted ? Theme.primary : Theme.subtle))
        }
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }

    private var attempted: Bool {
        words.contains { progress.bestScore(PracticeItem(word: $0).key) != nil }
    }
}

private struct DoneStep: View {
    let phoneme: Phoneme
    let finish: () -> Void

    var body: some View {
        LessonStepLayout {
            VStack(spacing: 20) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Theme.ok)
                Text("Bạn đã học xong /\(phoneme.symbol)/!").font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("+20 XP · Âm này sẽ được nhắc ôn lại vào ngày mai.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 30)
        } actions: {
            Button("Hoàn thành", action: finish).buttonStyle(PrimaryButtonStyle(color: Theme.good))
        }
        .onAppear { Haptics.result(success: true) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
