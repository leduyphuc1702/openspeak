import SwiftUI

/// Asks the server for the next personal lesson.
@MainActor
@Observable
final class PathPlanner {
    enum Status: Equatable { case idle, loading, failed(String) }

    private(set) var status: Status = .idle

    func fetchNext(progress: ProgressStore, level: String, topics: [String]) async {
        guard status != .loading, progress.currentPathLesson == nil else { return }
        status = .loading
        do {
            let lesson = try await APIClient.current().pathNext(progress.pathRequest(level: level, topics: topics))
            progress.addPathLesson(lesson)
            status = .idle
        } catch is URLError {
            status = .failed("Không kết nối được máy chủ. Kiểm tra mạng rồi thử lại.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// The endless path in the Học tab: finished lessons, the current one and why it was chosen.
struct PersonalPathSection: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.level) private var level = "beginner"
    @AppStorage(Prefs.topics) private var topicsRaw = ""
    @State private var planner = PathPlanner()
    @State private var showAll = false

    private let recentCount = 8

    var body: some View {
        let done = progress.pathLessons.filter { progress.pathResult($0) != nil }
        let shown = showAll ? done : Array(done.suffix(recentCount))
        VStack(spacing: 4) {
            intro(doneCount: done.count)
                .padding(.bottom, 6)
            if shown.count < done.count {
                Button("Xem \(done.count - shown.count) bài trước") { showAll = true }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 8)
            }
            ForEach(shown) { lesson in
                TaskLink {
                    PathLessonView(lesson: lesson)
                } label: {
                    LessonRow(number: lesson.index, title: lesson.title, kind: kind(lesson), icon: icon(lesson),
                              done: true, current: false, locked: false)
                }
                .buttonStyle(FlatButtonStyle())
            }
            if let current = progress.currentPathLesson {
                TaskLink {
                    PathLessonView(lesson: current)
                } label: {
                    LessonRow(number: current.index, title: current.title, kind: kind(current), icon: icon(current),
                              done: false, current: true, locked: false)
                }
                .buttonStyle(FlatButtonStyle())
                .accessibilityIdentifier("path.current")
                PathReasonCard(lesson: current)
                    .padding(.top, 6)
                LessonRow(number: current.index + 1, title: "Bài tiếp theo",
                          kind: "Được lập sau khi bạn học xong bài \(current.index)", icon: "lock.fill",
                          done: false, current: false, locked: true)
            } else {
                status
            }
        }
        .task(id: progress.currentPathLesson?.index) {
            await planner.fetchNext(progress: progress, level: level, topics: Prefs.topicIDs(topicsRaw))
        }
    }

    private func intro(doneCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Không giới hạn")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.primaryDeep, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                Text("đã học \(doneCount) bài").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Lộ trình cá nhân").font(.title3.bold()).foregroundStyle(Theme.ink)
            Text("Mỗi bài được lập từ điểm nói và nghe của bạn. Học xong một bài, bài sau tự điều chỉnh âm luyện và độ khó.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch planner.status {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Chưa lập được bài tiếp theo", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(Theme.bad)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("Thử lại") {
                    Task { await planner.fetchNext(progress: progress, level: level, topics: Prefs.topicIDs(topicsRaw)) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .card()
        default:
            HStack(spacing: 12) {
                ProgressView()
                Text("Đang lập bài tiếp theo theo kết quả của bạn…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func kind(_ lesson: PathLesson) -> String {
        var parts = [lesson.difficultyTitle, lesson.writtenByAI ? "AI soạn" : "Soạn tự động"]
        if let score = progress.pathResult(lesson)?.score { parts.append("\(score) điểm") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ lesson: PathLesson) -> String {
        lesson.writtenByAI ? "sparkles" : "list.bullet.rectangle"
    }
}

/// Why this lesson, and who wrote it.
struct PathReasonCard: View {
    let lesson: PathLesson

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(lesson.writtenByAI ? "AI soạn bài này cho bạn" : "Soạn tự động từ kết quả của bạn (không dùng AI)",
                  systemImage: lesson.writtenByAI ? "sparkles" : "list.bullet.rectangle")
                .font(.caption.bold())
                .foregroundStyle(Theme.accent)
            Text(lesson.reasonVi)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// One personal lesson: why it was chosen, listening, words, sentences.
struct PathLessonView: View {
    let lesson: PathLesson

    enum Step: Int, CaseIterable {
        case intro, listen, words, sentences, done

        var title: String {
            switch self {
            case .intro: return "Vì sao có bài này"
            case .listen: return "Nghe phân biệt"
            case .words: return "Nói từ"
            case .sentences: return "Nói câu"
            case .done: return "Hoàn thành"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var step: Step = .intro
    @State private var questions: [ListenStep.Question] = []

    private var phoneme: Phoneme? { content.phoneme(lesson.focus) }

    private var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .listen: return phoneme != nil && !questions.isEmpty
            case .words: return !lesson.words.isEmpty
            case .sentences: return !lesson.sentences.isEmpty
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
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
        }
        .environment(\.lessonStepTitle, step.title)
        .screenBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            progress.startPathLesson(lesson)
            if questions.isEmpty { questions = makeQuestions() }
        }
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
            Text("Bài \(lesson.index)")
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
            PathIntroStep(lesson: lesson, phoneme: phoneme, contrast: content.phoneme(lesson.contrast), next: advance)
        case .listen:
            if let phoneme {
                ListenStep(phoneme: phoneme, questions: questions,
                           onAnswer: { progress.recordHearing(lesson.focus, correct: $0) }, next: advance)
            }
        case .words:
            PathSpeakStep(hint: "Nói từng từ. AI chấm riêng âm \(symbol(lesson.focus)) trong mỗi từ.",
                          items: lesson.words.map { word in
                              (item: PracticeItem(word: word.entry, focus: lesson.focus), entry: word.entry,
                               meaning: word.meaningVi)
                          },
                          focus: lesson.focus, next: advance)
        case .sentences:
            PathSpeakStep(hint: "Đọc cả câu, chú ý âm \(symbol(lesson.focus)) và chỗ nối âm.",
                          items: lesson.sentences.map { sentence in
                              (item: PracticeItem(key: "p:\(sentence.text.lowercased())", text: sentence.text, ipa: sentence.ipa,
                                                  connectedIPA: sentence.connectedIpa, links: sentence.links,
                                                  intonation: sentence.intonation, focusPhone: lesson.focus),
                               entry: nil, meaning: sentence.meaningVi)
                          },
                          focus: lesson.focus, next: advance)
        case .done:
            PathDoneStep(lesson: lesson, symbol: symbol(lesson.focus), score: progress.pathLessonScore) {
                progress.finishPathLesson(lesson)
                dismiss()
            }
        }
    }

    private func symbol(_ id: String) -> String {
        "/\(content.phoneme(id)?.symbol ?? id)/"
    }

    private func advance() {
        Haptics.tap()
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) { step = steps[index + 1] }
    }

    /// The lesson's minimal pairs, then "does this word have the sound?" with the lesson's words
    /// and words that carry the contrast sound instead.
    private func makeQuestions() -> [ListenStep.Question] {
        var result: [ListenStep.Question] = lesson.pairs.map { pair in
            .pair(play: Bool.random() ? pair.a.entry : pair.b.entry, options: [pair.a.entry, pair.b.entry])
        }
        let with = lesson.words.map(\.entry).shuffled().prefix(2)
        var without = content.words(without: lesson.focus)
        if let contrast = lesson.contrast {
            let near = without.filter { $0.phones.contains(contrast) }
            if !near.isEmpty { without = near }
        }
        result += with.map { .contains(word: $0, answer: true) }
        result += without.shuffled().prefix(with.count).map { .contains(word: $0, answer: false) }
        return Array(result.shuffled().prefix(6))
    }
}

private struct PathIntroStep: View {
    let lesson: PathLesson
    let phoneme: Phoneme?
    let contrast: Phoneme?
    let next: () -> Void

    var body: some View {
        LessonStepLayout {
            Button { if let phoneme { SpeechPlayer.shared.speak(phoneme: phoneme) } } label: {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(phoneme?.symbol ?? lesson.focus)
                            .font(.system(size: 88, weight: .bold, design: .serif))
                        if let contrast {
                            Text("và").font(.title3.weight(.semibold)).opacity(0.7)
                            Text(contrast.symbol)
                                .font(.system(size: 56, weight: .bold, design: .serif))
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    Label("Chạm để nghe", systemImage: "speaker.wave.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title).font(.title3.bold()).foregroundStyle(Theme.ink)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PathReasonCard(lesson: lesson)

            if let tip = lesson.tipVi {
                SwiftUI.Label {
                    Text(tip).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(Theme.ok)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
            }

            if let phoneme {
                ArticulationCard(phoneme: phoneme)
            }
        } actions: {
            Button("Bắt đầu", action: next).buttonStyle(PrimaryButtonStyle())
        }
    }

    private var summary: String {
        var parts = ["\(lesson.words.count) từ"]
        if !lesson.pairs.isEmpty { parts.append("\(lesson.pairs.count) cặp âm") }
        if !lesson.sentences.isEmpty { parts.append("\(lesson.sentences.count) câu") }
        parts.append("độ khó: \(lesson.difficultyTitle)")
        return parts.joined(separator: " · ")
    }
}

/// Cards to say aloud; each opens the speaking screen, which scores the lesson's sound.
private struct PathSpeakStep: View {
    let hint: String
    let items: [(item: PracticeItem, entry: WordEntry?, meaning: String?)]
    let focus: String
    let next: () -> Void

    @Environment(ProgressStore.self) private var progress
    @State private var practising: PracticeItem?

    var body: some View {
        LessonStepLayout {
            Text(hint)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(items, id: \.item.key) { entry in
                Button { practising = entry.item } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.item.text).font(.title3.bold()).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if let word = entry.entry {
                                Text(IPATokenizer.highlighted(word, phonemeID: focus))
                                    .font(.system(.body, design: .serif))
                            } else if let ipa = entry.item.connectedIPA {
                                Text("/\(ipa)/").font(.system(.subheadline, design: .serif)).foregroundStyle(Theme.primary)
                            }
                            if let meaning = entry.meaning, !meaning.isEmpty {
                                Text(meaning).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if let best = progress.bestScore(entry.item.key) {
                            ScoreRing(score: best, size: 44, lineWidth: 5)
                        } else {
                            Image(systemName: "mic.circle.fill").font(.largeTitle).foregroundStyle(Theme.primary)
                        }
                    }
                    .card()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("speak.\(entry.item.text)")
            }
        } actions: {
            Button(attempted ? "Tiếp tục" : "Bỏ qua bước này", action: next)
                .buttonStyle(PrimaryButtonStyle(color: attempted ? Theme.primary : Theme.subtle))
        }
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }

    private var attempted: Bool {
        items.contains { progress.bestScore($0.item.key) != nil }
    }
}

private struct PathDoneStep: View {
    let lesson: PathLesson
    let symbol: String
    let score: Int?
    let finish: () -> Void

    var body: some View {
        LessonStepLayout {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.ok)
            Text("Xong bài \(lesson.index)!").font(.title.bold())
            if let score {
                HStack(spacing: 14) {
                    ScoreRing(score: score, size: 64, lineWidth: 7)
                    Text("Điểm trung bình của âm \(symbol) trong bài này")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            } else {
                Text("Bài này chưa có lượt nói nào được chấm. Bài sau sẽ dựa vào phần nghe và các điểm cũ của bạn.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("+25 XP · Bài tiếp theo sẽ được lập dựa trên kết quả này.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Hoàn thành", action: finish).buttonStyle(PrimaryButtonStyle(color: Theme.good))
        }
        .onAppear { Haptics.result(success: true) }
    }
}
