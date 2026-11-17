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
            .map { Exercise.pair($0.a, $0.b, sound: phoneme.id) }
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

/// Hear the sound, tap its symbol. Three correct answers in a row.
private struct RecogniseStep: View {
    let phoneme: Phoneme
    let options: [Phoneme]
    let next: () -> Void

    private let rounds = 3
    @State private var correct = 0
    @State private var shuffled: [Phoneme] = []
    @State private var wrong: Phoneme?
    @State private var showRight = false

    var body: some View {
        LessonStepLayout(showsActions: showRight) {
            Text("Nghe rồi chạm vào ký hiệu đúng (\(correct)/\(rounds))")
                .font(.headline)
            Button { SpeechPlayer.shared.speak(phoneme: phoneme) } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 40))
                    .frame(width: 110, height: 110)
                    .background(Theme.primaryFill, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

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
                            .answerMark(showRight && option == phoneme ? .right : option == wrong ? .wrong : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let wrong {
                Text("Đó là /\(wrong.symbol)/. Nghe lại và thử lần nữa nhé.")
                    .font(.subheadline).foregroundStyle(Theme.bad)
            }
        } actions: {
            Label("Chính xác: /\(phoneme.symbol)/", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(Theme.good)
            Button("Tiếp") {
                correct += 1
                if correct >= rounds { next() } else { newRound() }
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.good))
        }
        .onAppear(perform: newRound)
    }

    private func tileColor(_ option: Phoneme) -> Color {
        if showRight && option == phoneme { return Theme.good.opacity(0.2) }
        if option == wrong { return Theme.bad.opacity(0.15) }
        return Theme.surface
    }

    private func borderColor(_ option: Phoneme) -> Color {
        if showRight && option == phoneme { return Theme.good }
        if option == wrong { return Theme.bad }
        return Theme.subtle
    }

    private func pick(_ option: Phoneme) {
        guard !showRight else { return }
        if option == phoneme {
            showRight = true
            wrong = nil
            Haptics.result(success: true)
        } else {
            wrong = option
            Haptics.result(success: false)
            SpeechPlayer.shared.speak(phoneme: option)
        }
    }

    private func newRound() {
        shuffled = options.shuffled()
        wrong = nil
        showRight = false
        SpeechPlayer.shared.speak(phoneme: phoneme)
    }
}

/// Multiple-choice questions about sounds: hear a word or a sentence and pick what was said, or spot
/// the one word whose letters spell the sound.
struct ListenStep: View {
    let questions: [Exercise]
    /// Who wrote the questions, shown above them.
    var source: String? = nil
    var onAnswer: ((Exercise, Bool) -> Void)? = nil
    let next: () -> Void

    @Environment(ContentStore.self) private var content
    @State private var index = 0
    @State private var picked: Int?

    var body: some View {
        LessonStepLayout(showsActions: picked != nil || index >= questions.count) {
            if let question = questions[safe: index] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Câu \(index + 1)/\(questions.count)").font(.subheadline.monospacedDigit())
                    if let source { Text(source).font(.caption) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                prompt(question)
                options(question)
                if picked != nil { explanation(question) }
            } else {
                Text("Chưa có câu hỏi cho âm này.").foregroundStyle(.secondary)
            }
        } actions: {
            if let picked, let question = questions[safe: index] {
                let right = picked == question.answer
                Label(right ? "Chính xác: \(question.correct.word) /\(question.correct.ipa)/"
                            : "Chưa đúng. Đáp án: \(question.correct.word) /\(question.correct.ipa)/",
                      systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(right ? Theme.good : Theme.bad)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Tiếp") {
                    self.picked = nil
                    index += 1
                    if index >= questions.count { next() } else { speakCurrent() }
                }
                .buttonStyle(PrimaryButtonStyle(color: right ? Theme.good : Theme.primary))
            } else {
                Button("Tiếp tục", action: next).buttonStyle(PrimaryButtonStyle())
            }
        }
        .onAppear(perform: speakCurrent)
    }

    private func symbol(_ id: String) -> String { "/\(content.phoneme(id)?.symbol ?? id)/" }

    @ViewBuilder
    private func prompt(_ question: Exercise) -> some View {
        switch question.kind {
        case .pair:
            speaker(question.correct.word)
            Text("Bạn nghe thấy từ nào?").font(.headline)
        case .gap:
            speaker(question.sentence ?? question.correct.word)
            Text("Nghe cả câu rồi chọn từ bạn nghe thấy ở chỗ trống").font(.headline)
                .multilineTextAlignment(.center)
            SwiftUI.Text(question.text ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .card(padding: 16)
        case .spelling:
            Text("Từ nào có âm \(symbol(question.sound))?").font(.title3.bold()).foregroundStyle(Theme.ink)
            Text("Các từ viết gần giống nhau, chỉ một từ đọc có âm này.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func speaker(_ text: String) -> some View {
        Button { SpeechPlayer.shared.speak(text) } label: {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 40))
                .frame(width: 110, height: 110)
                .background(Theme.primaryFill, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nghe lại")
    }

    @ViewBuilder
    private func options(_ question: Exercise) -> some View {
        // IPA under a spelling option would give the answer away, so it shows only after answering.
        let showIPA = question.kind != .spelling || picked != nil
        if question.kind == .spelling {
            VStack(spacing: 12) {
                ForEach(question.options.indices, id: \.self) { i in
                    answerButton(question, i, subtitle: showIPA ? "/\(question.options[i].ipa)/" : nil)
                }
            }
        } else {
            HStack(spacing: 14) {
                ForEach(question.options.indices, id: \.self) { i in
                    answerButton(question, i, subtitle: "/\(question.options[i].ipa)/")
                }
            }
        }
    }

    @ViewBuilder
    private func explanation(_ question: Exercise) -> some View {
        let lines = [question.kind == .gap ? question.sentence : nil, question.meaningVi, question.noteVi].compactMap { $0 }
        if !lines.isEmpty || question.kind == .spelling {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.subheadline).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if question.kind == .spelling {
                    Button { SpeechPlayer.shared.speak(question.correct.word, slow: true) } label: {
                        Label("Nghe \(question.correct.word)", systemImage: "speaker.wave.2.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
        }
    }

    private func answerButton(_ question: Exercise, _ i: Int, subtitle: String?) -> some View {
        let option = question.options[i]
        let tint: Color? = picked == nil ? nil : i == question.answer ? Theme.good : picked == i ? Theme.bad : nil
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            picked = i
            let right = i == question.answer
            Haptics.result(success: right)
            onAnswer?(question, right)
        } label: {
            VStack(spacing: 4) {
                Text(option.word).font(.title3.bold()).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: question.kind == .spelling ? 64 : 84)
            .background(tint?.opacity(0.15) ?? Theme.surface, in: shape)
            .overlay(shape.stroke(tint ?? Theme.subtle, lineWidth: 2))
            .answerMark(picked == nil ? nil : i == question.answer ? .right : picked == i ? .wrong : nil)
        }
        .buttonStyle(FlatButtonStyle())
        .disabled(picked != nil)
        .accessibilityIdentifier("option.\(option.word)")
    }

    private func speakCurrent() {
        guard let text = questions[safe: index]?.spoken else { return }
        SpeechPlayer.shared.speak(text)
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
