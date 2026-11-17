import SwiftUI

/// One recall question about a word. None of them is graded by the learner: the app checks the answer.
struct VocabDrill: Identifiable, Hashable {
    enum Kind: String {
        /// Hear and see the word, pick its meaning among the meanings of other words being learned.
        case meaning
        /// See the meaning and hear the word, type it.
        case spell
        /// Read a sentence from a situation the word was not taught in, type the word into the gap.
        case cloze
    }

    enum Verdict: Equatable {
        case right
        /// The right word in the wrong form (deadline for deadlines): counted as remembered, with a note.
        case rightWord
        case wrong
    }

    let kind: Kind
    let word: VocabWord
    var choices: [String] = []

    var id: String { "\(kind.rawValue):\(word.id)" }

    var answer: String {
        kind == .cloze ? (word.clozeAnswer ?? word.word) : word.word
    }

    func verdict(typed: String) -> Verdict {
        let clean = Exercise.normalised(typed)
        if clean == Exercise.normalised(answer) { return .right }
        if kind == .cloze, clean == Exercise.normalised(word.word) { return .rightWord }
        return .wrong
    }

    /// The questions to ask about a word in review: a new context when there is one, else spelling.
    static func review(_ word: VocabWord) -> VocabDrill {
        VocabDrill(kind: word.clozeEn == nil ? .spell : .cloze, word: word)
    }

    /// A lesson's practice: every word's meaning first, then every word typed from its meaning,
    /// then every word typed into a new sentence. Each round is shuffled.
    static func practice(_ words: [VocabWord]) -> [VocabDrill] {
        let meanings = Array(Set(words.map(\.meaningVi)))
        let pick = words.compactMap { word -> VocabDrill? in
            let others = meanings.filter { $0 != word.meaningVi }.shuffled().prefix(3)
            guard others.count >= 2 else { return nil }
            return VocabDrill(kind: .meaning, word: word, choices: ([word.meaningVi] + others).shuffled())
        }
        let spell = words.map { VocabDrill(kind: .spell, word: $0) }
        let cloze = words.filter { $0.clozeEn != nil }.map { VocabDrill(kind: .cloze, word: $0) }
        return pick.shuffled() + spell.shuffled() + cloze.shuffled()
    }
}

/// One drill on screen, with its own Check / I don't remember / Next actions pinned below.
struct VocabDrillView: View {
    let drill: VocabDrill
    var caption: String? = nil
    let onNext: (Bool) -> Void

    @State private var typed = ""
    @State private var picked: String?
    @State private var verdict: VocabDrill.Verdict?
    @FocusState private var typing: Bool

    var body: some View {
        LessonStepLayout {
            if let caption {
                Text(caption).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch drill.kind {
            case .meaning: meaning
            case .spell: spell
            case .cloze: cloze
            }
            if verdict != nil { reveal }
        } actions: {
            if let verdict {
                Label(verdictText(verdict), systemImage: verdict == .wrong ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(verdict == .wrong ? Theme.bad : Theme.good)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Tiếp") { onNext(verdict != .wrong) }
                    .buttonStyle(PrimaryButtonStyle(color: verdict == .wrong ? Theme.primary : Theme.good))
            } else if drill.kind == .meaning {
                Button("Không nhớ") { finish(.wrong) }.buttonStyle(SecondaryButtonStyle())
            } else {
                let ready = !Exercise.normalised(typed).isEmpty
                HStack(spacing: 12) {
                    Button("Không nhớ") { finish(.wrong) }.buttonStyle(SecondaryButtonStyle())
                    Button("Kiểm tra") { finish(drill.verdict(typed: typed)) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!ready)
                        .opacity(ready ? 1 : 0.5)
                }
            }
        }
        .onAppear {
            if drill.kind != .cloze { SpeechPlayer.shared.speak(drill.word.word) }
        }
    }

    private func verdictText(_ verdict: VocabDrill.Verdict) -> String {
        switch verdict {
        case .right: return "Chính xác"
        case .rightWord: return "Đúng từ · câu cần dạng \"\(drill.answer)\""
        case .wrong: return drill.kind == .meaning ? "Chưa đúng · nghĩa đúng tô xanh" : "Đáp án: \(drill.answer)"
        }
    }

    private func finish(_ result: VocabDrill.Verdict) {
        typing = false
        verdict = result
        Haptics.result(success: result != .wrong)
        SpeechPlayer.shared.speak(drill.word.word)
    }

    // MARK: Kinds

    @ViewBuilder
    private var meaning: some View {
        Text("Từ này nghĩa là gì?").font(.headline)
        Button { SpeechPlayer.shared.speak(drill.word.word) } label: {
            VStack(spacing: 6) {
                Text(drill.word.word).font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                    .accessibilityIdentifier("drill.prompt")
                Label("Nghe", systemImage: "speaker.wave.2.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            .frame(maxWidth: .infinity)
            .card(padding: 18)
        }
        .buttonStyle(.plain)
        VStack(spacing: 10) {
            ForEach(drill.choices, id: \.self) { choice in
                let mark: AnswerMark? = verdict == nil ? nil : choice == drill.word.meaningVi ? .right : choice == picked ? .wrong : nil
                Button {
                    picked = choice
                    finish(choice == drill.word.meaningVi ? .right : .wrong)
                } label: {
                    Text(choice)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(fill(mark), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(stroke(mark), lineWidth: 2))
                        .answerMark(mark)
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(verdict != nil)
                .accessibilityValue(mark == .right ? "đúng" : mark == .wrong ? "sai" : "")
                .accessibilityIdentifier("meaning.\(drill.choices.firstIndex(of: choice) ?? 0)")
            }
        }
    }

    @ViewBuilder
    private var spell: some View {
        Text("Nghe và gõ từ có nghĩa:").font(.headline)
        VStack(spacing: 10) {
            Text(drill.word.meaningVi).font(.title2.bold()).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                .accessibilityIdentifier("drill.prompt")
            HStack(spacing: 14) {
                Button { SpeechPlayer.shared.speak(drill.word.word) } label: {
                    Label("Nghe", systemImage: "speaker.wave.2.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(PillButtonStyle())
                Button { SpeechPlayer.shared.speak(drill.word.word, slow: true) } label: {
                    Label("Nghe chậm", systemImage: "tortoise.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(PillButtonStyle())
            }
            SwiftUI.Text(Self.hint(drill.word.word))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Gợi ý: bắt đầu bằng \(String(drill.word.word.prefix(1))), \(drill.word.word.count) ký tự")
        }
        .frame(maxWidth: .infinity)
        .card(padding: 18)
        field
    }

    @ViewBuilder
    private var cloze: some View {
        Text("Điền từ đã học vào chỗ trống").font(.headline)
        VStack(alignment: .leading, spacing: 10) {
            SwiftUI.Text(drill.word.clozeEn ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("drill.prompt")
            if let vi = drill.word.practiceVi, !vi.isEmpty {
                Text(vi).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Gợi ý: bắt đầu bằng \"\(String(drill.answer.prefix(1)))\"").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
        field
    }

    private var field: some View {
        TextField("Gõ từ", text: $typed)
            .font(.title3)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            #endif
            .autocorrectionDisabled()
            .focused($typing)
            .disabled(verdict != nil)
            .onSubmit { if !Exercise.normalised(typed).isEmpty { finish(drill.verdict(typed: typed)) } }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(verdict == nil ? Theme.subtle : verdict == .wrong ? Theme.bad : Theme.good, lineWidth: 2))
            .accessibilityIdentifier("vocab.field")
    }

    /// The word after answering: how it sounds, what it means, and the sentence it fills.
    private var reveal: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { SpeechPlayer.shared.speak(drill.word.word, slow: true) } label: {
                HStack {
                    Text(drill.word.word).font(.headline).foregroundStyle(Theme.ink)
                    Text("/\(drill.word.ipa)/").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(drill.word.meaningVi).font(.subheadline.weight(.semibold))
            if let sentence = drill.kind == .cloze ? drill.word.practiceEn : drill.word.exampleEn.nilIfEmpty {
                Text(sentence).font(.subheadline.italic()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private func fill(_ mark: AnswerMark?) -> Color {
        mark == .right ? Theme.good.opacity(0.15) : mark == .wrong ? Theme.bad.opacity(0.15) : Theme.surface
    }

    private func stroke(_ mark: AnswerMark?) -> Color {
        mark == .right ? Theme.good : mark == .wrong ? Theme.bad : Theme.subtle
    }

    /// "d _ _ _ _ _ _ _", spaces of a phrase kept.
    static func hint(_ word: String) -> String {
        word.enumerated().map { i, c in i == 0 ? String(c) : c == " " ? "  " : "_" }.joined(separator: " ")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Runs drills in order; a drill answered wrong comes back once at the end. Reports the first try of each.
struct DrillRunner: View {
    let drills: [VocabDrill]
    let title: String
    let onFirstTry: (VocabDrill, Bool) -> Void
    let finished: () -> Void

    @State private var queue: [VocabDrill]
    @State private var position = 0
    @State private var answered: Set<String> = []

    init(drills: [VocabDrill], title: String, onFirstTry: @escaping (VocabDrill, Bool) -> Void,
         finished: @escaping () -> Void) {
        self.drills = drills
        self.title = title
        self.onFirstTry = onFirstTry
        self.finished = finished
        _queue = State(initialValue: drills)
    }

    var body: some View {
        if let drill = queue[safe: position] {
            VocabDrillView(drill: drill, caption: "\(title) · \(position + 1)/\(queue.count)") { right in
                if !answered.contains(drill.id) {
                    answered.insert(drill.id)
                    onFirstTry(drill, right)
                    if !right { queue.append(drill) }
                }
                if position + 1 < queue.count { position += 1 } else { finished() }
            }
            .id("\(drill.id)-\(position)")
        } else {
            Color.clear.onAppear(perform: finished)
        }
    }
}

// MARK: Programme

/// The vocabulary programme on the Vocabulary tab: the next lesson, and how far the learner has come.
struct VocabPathCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        TaskLink { VocabPathLessonView() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "text.book.closed.fill", color: Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lộ trình từ vựng").font(.headline).foregroundStyle(Theme.ink)
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                HStack(spacing: 18) {
                    stat("\(progress.finishedVocabLessons)", "bài đã học")
                    stat("\(progress.savedWords.count)", "từ đang học")
                    stat("\(progress.masteredWordCount)", "từ đã nhớ lâu")
                }
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vocab.path")
    }

    private var subtitle: String {
        if let current = progress.currentVocabLesson { return "Học tiếp bài \(current.index): \(current.title)" }
        return "Bài \(progress.finishedVocabLessons + 1) · AI soạn theo chủ đề và trình độ của bạn"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One lesson of the programme: warm up on words due for review, meet the new words, recall each of them
/// three ways, then see which ones to come back to.
struct VocabPathLessonView: View {
    enum Phase: Equatable {
        case loading, failed(String), intro, warmup, learn(Int), practice, done
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.level) private var level = "beginner"
    @AppStorage(Prefs.topics) private var topicsRaw = ""
    @State private var lesson: VocabPathLesson?
    @State private var phase: Phase = .loading
    @State private var warmup: [VocabWord] = []
    @State private var warmupRight = 0
    @State private var wrong: Set<String> = []
    @State private var practising: PracticeItem?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("AI đang soạn bài từ vựng cho bạn…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                LessonStepLayout {
                    Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(Theme.bad)
                } actions: {
                    Button("Thử lại") { Task { await load() } }.buttonStyle(PrimaryButtonStyle())
                }
            case .intro:
                if let lesson { intro(lesson) }
            case .warmup:
                DrillRunner(drills: warmup.map(VocabDrill.review), title: "Ôn từ cũ") { drill, right in
                    progress.gradeWord(drill.word, remembered: right)
                    if right { warmupRight += 1 }
                } finished: {
                    phase = .learn(0)
                }
            case .learn(let i):
                if let lesson, let word = lesson.words[safe: i] { learn(lesson, word, i) }
            case .practice:
                if let lesson {
                    DrillRunner(drills: VocabDrill.practice(lesson.words), title: "Nhớ lại") { drill, right in
                        if !right { wrong.insert(drill.word.id) }
                    } finished: {
                        phase = .done
                    }
                }
            case .done:
                if let lesson { done(lesson) }
            }
        }
        .environment(\.lessonStepTitle, title)
        .screenBackground()
        .inlineNavigationTitle(lesson.map { "Bài \($0.index)" } ?? "Từ vựng")
        .task { if lesson == nil { await load() } }
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }

    private var title: String {
        switch phase {
        case .intro: return lesson?.title ?? ""
        case .warmup: return "Khởi động: ôn từ đến hạn"
        case .learn: return "Làm quen từ mới"
        case .practice: return "Nhớ lại từ mới"
        case .done: return "Hoàn thành"
        default: return ""
        }
    }

    private func load() async {
        phase = .loading
        if let current = progress.currentVocabLesson {
            lesson = current
        } else {
            do {
                let request = progress.vocabRequest(level: level, topics: Prefs.topicIDs(topicsRaw))
                let next = try await APIClient.current().vocabNext(request)
                guard !next.words.isEmpty else { phase = .failed("Chưa có từ mới cho bài này."); return }
                progress.startVocabLesson(next)
                lesson = next
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        let fresh = Set(lesson?.words.map(\.id) ?? [])
        warmup = Array(progress.dueWords().filter { !fresh.contains($0.id) }.shuffled().prefix(4))
        WordAudioCache.prefetch((lesson?.words ?? []).map(\.word))
        phase = .intro
    }

    private func intro(_ lesson: VocabPathLesson) -> some View {
        LessonStepLayout {
            VStack(alignment: .leading, spacing: 8) {
                Label(lesson.topicTitle, systemImage: "tag.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                if let situation = lesson.situationVi {
                    Text("Tình huống: \(situation)").font(.subheadline).foregroundStyle(.secondary)
                }
                if let goal = lesson.goalVi {
                    Text(goal).font(.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: 10) {
                step("1", warmup.isEmpty ? "Không có từ cũ đến hạn ôn" : "Ôn \(warmup.count) từ cũ đến hạn")
                step("2", "Làm quen \(lesson.words.count) từ mới: nghĩa, phát âm, câu ví dụ")
                step("3", "Nhớ lại mỗi từ 3 cách: chọn nghĩa, nghe rồi gõ, điền vào câu mới")
                step("4", "Từ nào sai sẽ quay lại cuối bài và được nhắc ôn sớm hơn")
            }
            .card()
            Text(lesson.writtenByAI ? "AI soạn theo chủ đề, trình độ và các từ bạn đã biết"
                                    : "Gói từ có sẵn (máy chủ chưa có AI hoặc AI lỗi)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            Button("Bắt đầu") { phase = warmup.isEmpty ? .learn(0) : .warmup }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.subheadline.bold()).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Theme.primary, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func learn(_ lesson: VocabPathLesson, _ word: VocabWord, _ i: Int) -> some View {
        LessonStepLayout {
            HStack {
                Text("Từ \(i + 1)/\(lesson.words.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: Double(i + 1), total: Double(lesson.words.count)).tint(Theme.primary)
            }
            WordCard(word: word, saved: progress.isSaved(word), toggleSave: { progress.save(word) },
                     speak: { practising = $0 })
                .id(word.id)
        } actions: {
            Button(i + 1 < lesson.words.count ? "Từ tiếp theo" : "Bắt đầu nhớ lại") {
                phase = i + 1 < lesson.words.count ? .learn(i + 1) : .practice
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .onAppear { SpeechPlayer.shared.speakRecording(word.word) }
    }

    private func done(_ lesson: VocabPathLesson) -> some View {
        let remembered = lesson.words.filter { !wrong.contains($0.id) }
        let again = lesson.words.filter { wrong.contains($0.id) }
        return LessonStepLayout {
            HStack(spacing: 14) {
                ScoreRing(score: 100 * remembered.count / max(lesson.words.count, 1), size: 64, lineWidth: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nhớ ngay \(remembered.count)/\(lesson.words.count) từ mới").font(.headline).foregroundStyle(Theme.ink)
                    if !warmup.isEmpty {
                        Text("Ôn từ cũ: \(warmupRight)/\(warmup.count)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            if !again.isEmpty { wordList("Cần ôn lại sớm", again) }
            if !remembered.isEmpty { wordList("Đã nhớ · ôn lại sau 1 ngày", remembered) }
        } actions: {
            Button("Hoàn thành") {
                progress.finishVocabLesson(lesson, remembered: Dictionary(uniqueKeysWithValues: lesson.words.map { ($0.id, !wrong.contains($0.id)) }))
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.good))
        }
        .onAppear { Haptics.result(success: true) }
    }

    private func wordList(_ title: String, _ words: [VocabWord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(words) { word in
                Button { SpeechPlayer.shared.speak(word.word) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.word).font(.headline).foregroundStyle(Theme.ink)
                            Text(word.meaningVi).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}
