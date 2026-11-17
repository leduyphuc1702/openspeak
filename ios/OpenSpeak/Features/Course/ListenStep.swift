import SwiftUI

/// Questions about sounds that cannot be answered by elimination: mark what was heard, type it, sort words by
/// sound, or build a transcription. A question answered wrong comes back once at the end, and the step closes
/// with what is worth remembering: the words that were missed and the spelling rules met on the way.
struct ListenStep: View {
    let questions: [Exercise]
    /// Who wrote the questions, shown above them.
    var source: String? = nil
    /// Called once per question, for the first attempt only, so a retried question does not count twice.
    var onAnswer: ((Exercise, Bool) -> Void)? = nil
    let next: () -> Void

    @Environment(ContentStore.self) private var content
    @State private var queue: [Int]
    @State private var position = 0
    @State private var retried: Set<Int> = []
    @State private var firstTry: [Int: Bool] = [:]
    @State private var result: Bool?
    @State private var input = ExerciseInput()
    @State private var finished = false

    init(questions: [Exercise], source: String? = nil, onAnswer: ((Exercise, Bool) -> Void)? = nil,
         next: @escaping () -> Void) {
        self.questions = questions
        self.source = source
        self.onAnswer = onAnswer
        self.next = next
        _queue = State(initialValue: Array(questions.indices))
    }

    private var current: (index: Int, question: Exercise)? {
        guard let i = queue[safe: position], let q = questions[safe: i] else { return nil }
        return (i, q)
    }

    var body: some View {
        Group {
            if finished || questions.isEmpty {
                ListenSummary(questions: questions, firstTry: firstTry, next: next)
            } else if let current {
                LessonStepLayout {
                    header(current.index)
                    ExerciseView(question: current.question, input: $input, result: result)
                        .id("\(current.index)-\(position)")
                } actions: {
                    actions(current.question)
                }
            }
        }
    }

    private func header(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Câu \(min(position + 1, queue.count))/\(queue.count)").font(.subheadline.monospacedDigit())
                if retried.contains(index) && position >= questions.count {
                    Label("Làm lại câu sai", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
                }
            }
            if let source { Text(source).font(.caption) }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ question: Exercise) -> some View {
        if let result {
            Label(result ? "Chính xác" : verdict(question), systemImage: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result ? Theme.good : Theme.bad)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Tiếp", action: advance)
                .buttonStyle(PrimaryButtonStyle(color: result ? Theme.good : Theme.primary))
        } else {
            let ready = input.isComplete(for: question)
            Button("Kiểm tra") { check(question) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!ready)
                .opacity(ready ? 1 : 0.5)
        }
    }

    private func verdict(_ question: Exercise) -> String {
        let comesBack = current.map { queue[(position + 1)...].contains($0.index) } ?? false
        return comesBack ? "Chưa đúng · câu này sẽ quay lại cuối bài" : "Chưa đúng"
    }

    private func check(_ question: Exercise) {
        guard let current else { return }
        let right = input.isRight(for: question)
        result = right
        Haptics.result(success: right)
        if firstTry[current.index] == nil {
            firstTry[current.index] = right
            onAnswer?(question, right)
        }
        if !right, !retried.contains(current.index) {
            retried.insert(current.index)
            queue.append(current.index)
        }
    }

    private func advance() {
        SpeechPlayer.shared.stop()
        result = nil
        input = ExerciseInput()
        if position + 1 < queue.count {
            position += 1
        } else {
            finished = true
        }
    }
}

/// What the learner has entered for the current question.
struct ExerciseInput: Equatable {
    var sequence: [Int?] = []
    var typed = ""
    var sorted: Set<Int> = []
    var built: [String] = []

    func isComplete(for q: Exercise) -> Bool {
        switch q.kind {
        case .sequence: return sequence.count == (q.order?.count ?? 0) && !sequence.contains(nil)
        case .dictation: return !Exercise.normalised(typed).isEmpty
        case .sort: return true
        case .build: return built.count == (q.solution?.count ?? 0)
        }
    }

    func isRight(for q: Exercise) -> Bool {
        switch q.kind {
        case .sequence: return sequence.compactMap { $0 } == (q.order ?? [])
        case .dictation: return q.accepts(typed)
        case .sort: return sorted == Set((q.marks ?? []).indices.filter { q.marks?[$0] == true })
        case .build: return built == (q.solution ?? [])
        }
    }
}

/// One question: its prompt, the way to answer it, and after checking, why the answer is what it is.
private struct ExerciseView: View {
    let question: Exercise
    @Binding var input: ExerciseInput
    let result: Bool?

    @Environment(ContentStore.self) private var content
    @State private var playing: Int?
    @State private var playback: Task<Void, Never>?
    @FocusState private var typing: Bool

    private var answered: Bool { result != nil }
    private var symbol: String { "/\(content.phoneme(question.sound)?.symbol ?? question.sound)/" }

    var body: some View {
        VStack(spacing: 18) {
            switch question.kind {
            case .sequence: sequence
            case .dictation: dictation
            case .sort: sort
            case .build: build
            }
        }
        .onAppear(perform: start)
        .onDisappear { playback?.cancel() }
        .onChange(of: result) { _, new in if new != nil { typing = false } }
    }

    private func start() {
        switch question.kind {
        case .sequence:
            if input.sequence.isEmpty { input.sequence = Array(repeating: nil, count: question.order?.count ?? 0) }
            playSequence()
        case .dictation:
            if let sentence = question.sentence { SpeechPlayer.shared.speak(sentence) }
        case .build:
            SpeechPlayer.shared.speak(question.correct.word)
        case .sort:
            break
        }
    }

    // MARK: Sequence

    @ViewBuilder
    private var sequence: some View {
        Text("Nghe 3 lần đọc, đánh dấu mỗi lần là từ nào").font(.headline).multilineTextAlignment(.center)
        SpeakerButton(label: "Nghe lại cả 3 lần", action: playSequence)
        Text("Cả hai từ đều xuất hiện ít nhất một lần.")
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        VStack(spacing: 10) {
            ForEach(Array((question.order ?? []).enumerated()), id: \.offset) { slot, truth in
                sequenceRow(slot: slot, truth: truth)
            }
        }
        if answered {
            explanation {
                Text("Thứ tự đúng: " + (question.order ?? []).map { question.options[$0].word }.joined(separator: " – "))
                    .font(.subheadline.weight(.semibold))
                ForEach(question.options.indices, id: \.self) { i in
                    hearRow(question.options[i])
                }
            }
        }
    }

    private func sequenceRow(slot: Int, truth: Int) -> some View {
        HStack(spacing: 10) {
            Button { play(slot: slot) } label: {
                Label("Lần \(slot + 1)", systemImage: playing == slot ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(playing == slot ? Theme.primary : Theme.ink)
                    .frame(width: 92, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("seq.play.\(slot)")
            ForEach(question.options.indices, id: \.self) { i in
                let chosen = input.sequence[safe: slot] == i
                let mark: AnswerMark? = !answered ? nil : i == truth ? .right : chosen ? .wrong : nil
                choiceButton(question.options[i].word, chosen: chosen, mark: mark) {
                    if input.sequence.indices.contains(slot) { input.sequence[slot] = i }
                }
                .accessibilityIdentifier("seq.\(slot).\(i)")
            }
        }
    }

    private func playSequence() {
        let words = (question.order ?? []).map { question.options[$0].word }
        playback?.cancel()
        playback = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            for (slot, word) in words.enumerated() {
                guard !Task.isCancelled else { return }
                playing = slot
                SpeechPlayer.shared.speak(word)
                try? await Task.sleep(for: .milliseconds(1400))
            }
            playing = nil
        }
    }

    private func play(slot: Int) {
        guard let truth = question.order?[safe: slot] else { return }
        playback?.cancel()
        playing = slot
        SpeechPlayer.shared.speak(question.options[truth].word)
        playback = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled { playing = nil }
        }
    }

    // MARK: Dictation

    @ViewBuilder
    private var dictation: some View {
        Text("Nghe cả câu rồi gõ từ còn thiếu").font(.headline).multilineTextAlignment(.center)
        HStack(spacing: 14) {
            SpeakerButton(label: "Nghe lại") { if let s = question.sentence { SpeechPlayer.shared.speak(s) } }
            Button { if let s = question.sentence { SpeechPlayer.shared.speak(s, slow: true) } } label: {
                Label("Nghe chậm", systemImage: "tortoise.fill").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(PillButtonStyle())
        }
        SwiftUI.Text(question.text ?? "")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .card(padding: 16)
        TextField("Gõ từ bạn nghe được", text: $input.typed)
            .font(.title3)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            #endif
            .autocorrectionDisabled()
            .focused($typing)
            .disabled(answered)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(result == nil ? Theme.subtle : result == true ? Theme.good : Theme.bad, lineWidth: 2))
            .accessibilityIdentifier("dictation.field")
        if answered {
            explanation {
                let other = question.options.indices.first { $0 != question.answer }.map { question.options[$0] }
                if result == false, let other, Exercise.normalised(input.typed) == other.word {
                    Text("Bạn nghe thành \(other.word) /\(other.ipa)/. Từ trong câu là \(question.correct.word) /\(question.correct.ipa)/ - khác nhau ở âm \(symbol).")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sentence = question.sentence {
                    Text(sentence).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let meaning = question.meaningVi {
                    Text(meaning).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(question.options.indices, id: \.self) { i in hearRow(question.options[i]) }
            }
        }
    }

    // MARK: Sort

    @ViewBuilder
    private var sort: some View {
        Text("Chạm vào mọi từ có âm \(symbol)").font(.title3.bold()).foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
        Text("Các từ viết gần giống nhau. Có thể có một hoặc nhiều từ có âm này.")
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(question.options.indices, id: \.self) { i in
                let chosen = input.sorted.contains(i)
                let has = question.marks?[safe: i] == true
                let mark: AnswerMark? = !answered ? nil : chosen ? (has ? .right : .wrong) : nil
                let missed = answered && has && !chosen
                Button {
                    if answered { SpeechPlayer.shared.speak(question.options[i].word, slow: true); return }
                    if chosen { input.sorted.remove(i) } else { input.sorted.insert(i) }
                } label: {
                    VStack(spacing: 4) {
                        Text(question.options[i].word).font(.title3.bold()).foregroundStyle(Theme.ink)
                        if answered {
                            Text("/\(question.options[i].ipa)/").font(.system(.subheadline, design: .serif))
                                .foregroundStyle(.secondary)
                        }
                        if missed {
                            Text("Bỏ sót: có \(symbol)").font(.caption.weight(.semibold)).foregroundStyle(Theme.good)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .padding(.vertical, missed ? 6 : 0)
                    .background(tileFill(chosen: chosen, mark: mark), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(missed ? Theme.good : tileStroke(chosen: chosen, mark: mark),
                                style: StrokeStyle(lineWidth: chosen || mark != nil || missed ? 3 : 2, dash: missed ? [7, 5] : [])))
                    .answerMark(mark)
                }
                .buttonStyle(FlatButtonStyle())
                .accessibilityIdentifier("sort.\(i)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        if answered {
            explanation {
                if let note = question.noteVi {
                    SwiftUI.Label { Text(note).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Theme.ok)
                    }
                    .font(.subheadline)
                }
                Text("Chạm vào một từ để nghe.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Build

    @ViewBuilder
    private var build: some View {
        Text("Nghe rồi ghép phiên âm của từ").font(.headline).multilineTextAlignment(.center)
        SpeakerButton(label: "Nghe lại") { SpeechPlayer.shared.speak(question.correct.word) }
        VStack(spacing: 6) {
            Text(question.correct.word).font(.title.bold()).foregroundStyle(Theme.ink)
            if let meaning = question.correct.meaningVi, !meaning.isEmpty {
                Text(meaning).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 6) {
            Text("/").font(.system(.title, design: .serif)).foregroundStyle(.secondary)
            ForEach(0..<(question.solution?.count ?? 0), id: \.self) { i in
                let symbol = input.built[safe: i]
                let wrong = answered && symbol != question.solution?[safe: i]
                SwiftUI.Text(symbol ?? " ")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(wrong ? Theme.bad : Theme.ink)
                    .frame(minWidth: 34, minHeight: 44)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(wrong ? Theme.bad : symbol == nil ? Theme.subtle : Theme.primary).frame(height: 2)
                    }
            }
            Text("/").font(.system(.title, design: .serif)).foregroundStyle(.secondary)
            if !answered && !input.built.isEmpty {
                Button { input.built.removeLast() } label: {
                    Image(systemName: "delete.left").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Xoá ký hiệu cuối")
                .accessibilityIdentifier("build.delete")
            }
        }
        .frame(maxWidth: .infinity)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(question.tiles ?? [], id: \.self) { tile in
                Button {
                    guard !answered, input.built.count < (question.solution?.count ?? 0) else { return }
                    input.built.append(tile)
                    if let phoneme = content.phonemes.first(where: { $0.symbol == tile }) {
                        SpeechPlayer.shared.speak(phoneme: phoneme)
                    }
                } label: {
                    SwiftUI.Text(tile)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.subtle, lineWidth: 2))
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(answered)
                .accessibilityIdentifier("tile.\(tile)")
            }
        }
        if answered {
            explanation {
                Text("Phiên âm đúng: /\(question.correct.ipa)/").font(.subheadline.weight(.semibold))
                hearRow(question.correct)
            }
        }
    }

    // MARK: Pieces

    private func choiceButton(_ title: String, chosen: Bool, mark: AnswerMark?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(tileFill(chosen: chosen, mark: mark), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tileStroke(chosen: chosen, mark: mark), lineWidth: chosen || mark != nil ? 3 : 2))
                .answerMark(mark)
        }
        .buttonStyle(FlatButtonStyle())
        .disabled(answered)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func tileFill(chosen: Bool, mark: AnswerMark?) -> Color {
        switch mark {
        case .right: return Theme.good.opacity(0.15)
        case .wrong: return Theme.bad.opacity(0.15)
        case nil: return chosen ? Theme.primary.opacity(0.15) : Theme.surface
        }
    }

    private func tileStroke(chosen: Bool, mark: AnswerMark?) -> Color {
        switch mark {
        case .right: return Theme.good
        case .wrong: return Theme.bad
        case nil: return chosen ? Theme.primary : Theme.subtle
        }
    }

    private func hearRow(_ word: PathLesson.Word) -> some View {
        Button { SpeechPlayer.shared.speak(word.word, slow: true) } label: {
            HStack {
                Text(word.word).font(.headline).foregroundStyle(Theme.ink)
                Text("/\(word.ipa)/").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func explanation<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
    }
}

private struct SpeakerButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 34))
                .frame(width: 88, height: 88)
                .background(Theme.primaryFill, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The end of the questions: how many were right the first time, the words missed, and the rules met.
private struct ListenSummary: View {
    let questions: [Exercise]
    let firstTry: [Int: Bool]
    let next: () -> Void

    @Environment(ContentStore.self) private var content

    var body: some View {
        LessonStepLayout {
            if questions.isEmpty {
                Text("Chưa có câu hỏi cho bài này.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    ScoreRing(score: 100 * firstTry.values.filter { $0 }.count / max(questions.count, 1), size: 64, lineWidth: 7)
                    Text("Đúng ngay lần đầu \(firstTry.values.filter { $0 }.count)/\(questions.count) câu")
                        .font(.headline).foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                let missed = questions.indices.filter { firstTry[$0] == false }.map { questions[$0] }
                if !missed.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Cần nhớ").font(.headline)
                        ForEach(missedRows(missed)) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                                    ForEach(row.words, id: \.word) { word in
                                        Button { SpeechPlayer.shared.speak(word.word, slow: true) } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 0) {
                                                    Text(word.word).font(.headline).foregroundStyle(Theme.ink)
                                                    Text("/\(word.ipa)/").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary)
                                                }
                                                Spacer(minLength: 0)
                                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.primary)
                                            }
                                            .padding(10)
                                            .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                let rules = questions.compactMap { $0.kind == .sort ? $0.noteVi : nil }
                if !rules.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quy tắc chính tả đã gặp").font(.headline)
                        ForEach(rules, id: \.self) { rule in
                            SwiftUI.Label { Text(rule).fixedSize(horizontal: false, vertical: true) } icon: {
                                Image(systemName: "lightbulb.fill").foregroundStyle(Theme.ok)
                            }
                            .font(.subheadline)
                        }
                    }
                    .card()
                }
            }
        } actions: {
            Button("Tiếp tục", action: next).buttonStyle(PrimaryButtonStyle())
        }
    }

    private struct MissedRow: Identifiable {
        let id: String
        let caption: String
        let words: [PathLesson.Word]
    }

    /// One row per missed question, so a pair is remembered as a contrast: both words of a pair, the words of
    /// a sort that have the sound, the word of a transcription. Repeated rows are dropped.
    private func missedRows(_ missed: [Exercise]) -> [MissedRow] {
        var seen = Set<String>()
        return missed.compactMap { q -> MissedRow? in
            let symbol = "/\(content.phoneme(q.sound)?.symbol ?? q.sound)/"
            let row: (String, [PathLesson.Word])
            switch q.kind {
            case .sequence, .dictation: row = ("Phân biệt \(symbol)", q.options)
            case .build: row = ("Phiên âm", [q.correct])
            case .sort: row = ("Có \(symbol)", q.options.indices.filter { q.marks?[safe: $0] == true }.map { q.options[$0] })
            }
            let id = row.1.map(\.word).sorted().joined(separator: "|")
            guard !row.1.isEmpty, seen.insert(id).inserted else { return nil }
            return MissedRow(id: id, caption: row.0, words: row.1)
        }
    }
}
