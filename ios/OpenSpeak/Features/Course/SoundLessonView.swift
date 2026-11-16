import SwiftUI

/// One sound, taught the way children learn letters: meet it, recognise it,
/// write it, hear it, find it inside words, then say it.
struct SoundLessonView: View {
    let phoneme: Phoneme
    let unit: CourseUnit

    enum Step: Int, CaseIterable {
        case meet, recognise, trace, listen, find, speak, done

        var title: String {
            switch self {
            case .meet: return "Làm quen"
            case .recognise: return "Nhận mặt ký hiệu"
            case .trace: return "Tô ký hiệu"
            case .listen: return "Nghe phân biệt"
            case .find: return "Tìm âm trong từ"
            case .speak: return "Nói thành tiếng"
            case .done: return "Hoàn thành"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var step: Step = .meet

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
            ListenStep(phoneme: phoneme, questions: listenQuestions,
                       onAnswer: { progress.recordHearing(phoneme.id, correct: $0) }, next: advance)
        case .find:
            FindStep(phoneme: phoneme, words: Array(content.words(containing: phoneme.id).prefix(3)), next: advance)
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

    private var listenQuestions: [ListenStep.Question] {
        let pairs = content.minimalPairs.filter { $0.contrast.contains(phoneme.id) }.shuffled().prefix(2)
        var questions: [ListenStep.Question] = pairs.map { pair in
            let target = pair.a.phones.contains(phoneme.id) ? pair.a : pair.b
            let other = target == pair.a ? pair.b : pair.a
            return .pair(play: Bool.random() ? target : other, options: [pair.a, pair.b])
        }
        let others = (unit.sounds + unit.confusables).filter { $0 != phoneme.id }
        let with = content.words(containing: phoneme.id).shuffled()
        let without = content.words(without: phoneme.id)
            .filter { word in others.isEmpty || word.phones.contains(where: others.contains) }
            .shuffled()
        let needed = max(4 - questions.count, 2)
        for i in 0..<needed {
            let useTarget = i.isMultiple(of: 2)
            if let word = useTarget ? with.dropFirst(i / 2).first : without.dropFirst(i / 2).first {
                questions.append(.contains(word: word, answer: useTarget))
            }
        }
        return questions.shuffled()
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

struct ListenStep: View {
    enum Question {
        case pair(play: WordEntry, options: [WordEntry])
        case contains(word: WordEntry, answer: Bool)

        var spoken: WordEntry {
            switch self {
            case .pair(let play, _): return play
            case .contains(let word, _): return word
            }
        }
    }

    let phoneme: Phoneme
    let questions: [Question]
    var onAnswer: ((Bool) -> Void)? = nil
    let next: () -> Void

    @State private var index = 0
    @State private var feedback: (correct: Bool, text: String)?
    @State private var picked: String?

    var body: some View {
        LessonStepLayout(showsActions: feedback != nil || index >= questions.count) {
            if index < questions.count {
                let question = questions[index]
                Text("Câu \(index + 1)/\(questions.count)").font(.subheadline).foregroundStyle(.secondary)
                Button { SpeechPlayer.shared.speak(question.spoken.word) } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 40))
                        .frame(width: 110, height: 110)
                        .background(Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                switch question {
                case .pair(let play, let options):
                    Text("Bạn nghe thấy từ nào?").font(.headline)
                    HStack(spacing: 14) {
                        ForEach(options) { option in
                            answerButton(title: option.word, subtitle: "/\(option.ipa)/", correct: option == play) {
                                answer(correct: option == play, reveal: play)
                            }
                        }
                    }
                case .contains(let word, let expected):
                    Text("Từ này có âm /\(phoneme.symbol)/ không?").font(.headline)
                    HStack(spacing: 14) {
                        answerButton(title: "Có", subtitle: nil, correct: expected) { answer(correct: expected, reveal: word) }
                        answerButton(title: "Không", subtitle: nil, correct: !expected) { answer(correct: !expected, reveal: word) }
                    }
                }
            }
        } actions: {
            if let feedback {
                Label(feedback.text, systemImage: feedback.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(feedback.correct ? Theme.good : Theme.bad)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Tiếp") {
                    self.feedback = nil
                    index += 1
                    if index >= questions.count { next() } else { speakCurrent() }
                }
                .buttonStyle(PrimaryButtonStyle(color: feedback.correct ? Theme.good : Theme.primary))
            } else {
                Button("Tiếp tục", action: next).buttonStyle(PrimaryButtonStyle())
            }
        }
        .onAppear(perform: speakCurrent)
    }

    private func speakCurrent() {
        guard index < questions.count else { return }
        SpeechPlayer.shared.speak(questions[index].spoken.word)
    }

    private func answerButton(title: String, subtitle: String?, correct: Bool, action: @escaping () -> Void) -> some View {
        let tint: Color? = feedback == nil ? nil : correct ? Theme.good : picked == title ? Theme.bad : nil
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            picked = title
            action()
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.title3.bold()).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(tint?.opacity(0.15) ?? Theme.surface, in: shape)
            .overlay(shape.stroke(tint ?? Theme.subtle, lineWidth: 2))
            .answerMark(feedback == nil ? nil : correct ? .right : picked == title ? .wrong : nil)
        }
        .buttonStyle(FlatButtonStyle())
        .disabled(feedback != nil)
    }

    private func answer(correct: Bool, reveal word: WordEntry) {
        Haptics.result(success: correct)
        onAnswer?(correct)
        feedback = (correct, correct ? "Chính xác: \(word.word) /\(word.ipa)/" : "Chưa đúng. Đó là \(word.word) /\(word.ipa)/")
    }
}

/// Tap every place the sound appears in the transcription.
private struct FindStep: View {
    let phoneme: Phoneme
    let words: [WordEntry]
    let next: () -> Void

    @State private var index = 0
    @State private var found: Set<Int> = []
    @State private var missed: Int?

    var body: some View {
        LessonStepLayout(showsActions: words[safe: index].map(complete) ?? true) {
            if let word = words[safe: index] {
                Text("Chạm vào âm /\(phoneme.symbol)/ trong từ").font(.headline)
                Button { SpeechPlayer.shared.speak(word.word, slow: true) } label: {
                    Label(word.word, systemImage: "speaker.wave.2.fill")
                        .font(.largeTitle.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink)

                HStack(spacing: 8) {
                    ForEach(Array(tiles(word).enumerated()), id: \.offset) { _, tile in
                        if let slot = tile.slot {
                            Button { tap(slot, in: word) } label: {
                                Text(tile.text)
                                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                                    .frame(minWidth: 52, minHeight: 64)
                                    .padding(.horizontal, 4)
                                    .background(color(slot), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .foregroundStyle(found.contains(slot) ? .white : Theme.ink)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(tile.text).font(.system(.title, design: .serif)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Từ \(index + 1)/\(words.count)").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Không có từ để luyện.").foregroundStyle(.secondary)
            }
        } actions: {
            if let word = words[safe: index] {
                Label("Đúng rồi: \(word.word) /\(word.ipa)/", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Theme.good)
                Button("Tiếp") {
                    found = []
                    index += 1
                    if index >= words.count { next() }
                }
                .buttonStyle(PrimaryButtonStyle(color: Theme.good))
            } else {
                Button("Tiếp tục", action: next).buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private struct Tile {
        let text: String
        let slot: Int?
    }

    private func tiles(_ word: WordEntry) -> [Tile] {
        var slot = 0
        return IPATokenizer.tokenize(word.ipa).map { token in
            guard token.isPhone else { return Tile(text: token.text, slot: nil) }
            defer { slot += 1 }
            return Tile(text: token.text, slot: slot)
        }
    }

    private func color(_ slot: Int) -> Color {
        if found.contains(slot) { return Theme.goodFill }
        if missed == slot { return Theme.bad.opacity(0.2) }
        return Theme.surface
    }

    private func complete(_ word: WordEntry) -> Bool {
        let targets = Set(word.phones.indices.filter { word.phones[$0] == phoneme.id })
        return !targets.isEmpty && targets.isSubset(of: found)
    }

    private func tap(_ slot: Int, in word: WordEntry) {
        guard slot < word.phones.count, !complete(word) else { return }
        if word.phones[slot] == phoneme.id {
            found.insert(slot)
            missed = nil
            Haptics.result(success: true)
        } else {
            missed = slot
            Haptics.result(success: false)
        }
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
