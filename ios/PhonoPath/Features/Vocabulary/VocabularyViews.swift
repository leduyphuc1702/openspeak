import Observation
import SwiftUI

struct VocabularyHomeView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.topics) private var topicsRaw = ""
    @State private var query = ""
    @State private var lookup: String?
    @FocusState private var searching: Bool

    private var chosen: [String] { Prefs.topicIDs(topicsRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchBar
                let due = progress.dueWords()
                if !due.isEmpty {
                    TaskLink { WordReviewView(words: due) } label: {
                        HStack(spacing: 14) {
                            IconBadge(systemImage: "rectangle.on.rectangle.angled", color: Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ôn \(due.count) từ đến hạn").font(.headline).foregroundStyle(Theme.ink)
                                Text("Thẻ ghi nhớ lặp lại ngắt quãng").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                }

                SectionTitle(text: "Chủ đề của bạn")
                topicGrid(content.topics.filter { chosen.isEmpty || chosen.contains($0.id) })
                let others = content.topics.filter { !chosen.isEmpty && !chosen.contains($0.id) }
                if !others.isEmpty {
                    SectionTitle(text: "Khám phá thêm")
                    topicGrid(others)
                }

                if !progress.savedWords.isEmpty {
                    NavigationLink { SavedWordsView() } label: {
                        Label("Sổ từ của tôi (\(progress.savedWords.count))", systemImage: "bookmark.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("Từ vựng")
        .navigationDestination(item: $lookup) { DictionaryView(word: $0) }
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tra từ điển Anh – Việt", text: $query)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .autocorrectionDisabled()
                .focused($searching)
                .onSubmit(search)
            if !query.isEmpty {
                Button("Tra", action: search).font(.subheadline.bold())
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func search() {
        let word = query.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        // Give up the keyboard first, or it comes back over the list on return.
        searching = false
        lookup = word
    }

    private func topicGrid(_ topics: [Topic]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(topics) { topic in
                NavigationLink { VocabLessonView(topic: topic) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        IconBadge(systemImage: topic.icon, color: .white, size: 44)
                            .background(Theme.primary.opacity(0.9), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        // Two lines are reserved so tiles in a row match, without a line limit that would stop the title from balancing.
                        SwiftUI.Text("\n").hidden().accessibilityHidden(true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .topLeading) {
                                Text(topic.title)
                                    .foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.headline)
                    }
                    .card(padding: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
@Observable
final class VocabLessonModel {
    enum Phase {
        case loading
        case cards(VocabLesson)
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    func load(topic: Topic, level: String, known: [String]) async {
        phase = .loading
        do {
            let lesson = try await APIClient.current().vocabLesson(topic: topic.id, level: level, known: known)
            phase = lesson.words.isEmpty ? .failed("Chưa có từ mới cho chủ đề này.") : .cards(lesson)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// New words for a topic, one card at a time: meaning, sound, example, then say it.
struct VocabLessonView: View {
    let topic: Topic

    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.level) private var level = "beginner"
    @State private var model = VocabLessonModel()
    @State private var index = 0
    @State private var practising: PracticeItem?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("AI đang chọn từ mới cho bạn…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 14) {
                    Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(Theme.bad)
                    Button("Thử lại") { Task { await load() } }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .cards(let lesson):
                cards(lesson)
            }
        }
        .screenBackground()
        .inlineNavigationTitle(topic.title)
        .task { if case .loading = model.phase { await load() } }
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }

    private func load() async {
        index = 0
        await model.load(topic: topic, level: level, known: progress.knownWordList)
    }

    @ViewBuilder
    private func cards(_ lesson: VocabLesson) -> some View {
        if let word = lesson.words[safe: index] {
            VStack(spacing: 16) {
                HStack {
                    Text("\(index + 1)/\(lesson.words.count)").font(.subheadline.bold())
                    ProgressView(value: Double(index + 1), total: Double(lesson.words.count)).tint(Theme.primary)
                    if lesson.source == "seed" {
                        Text("Gói có sẵn").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    WordCard(word: word, saved: progress.isSaved(word),
                             toggleSave: { progress.save(word) },
                             speak: { practising = $0 })
                }
                HStack(spacing: 12) {
                    Button("Đã biết") {
                        progress.gradeWord(word, remembered: true)
                        withAnimation { index += 1 }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Học từ này") {
                        progress.gradeWord(word, remembered: false)
                        withAnimation { index += 1 }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 80)).foregroundStyle(Theme.good)
                Text("Xong \(lesson.words.count) từ chủ đề \(lesson.title)").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Các từ đã vào sổ từ và sẽ được nhắc ôn.").foregroundStyle(.secondary)
                Button("Học thêm từ mới") { Task { await load() } }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Front of the card: word, transcription, meaning, example. Tap to hear or practise.
struct WordCard: View {
    let word: VocabWord
    let saved: Bool
    let toggleSave: () -> Void
    let speak: (PracticeItem) -> Void
    @State private var showMouth = false
    @State private var credit: WordAudioCredit?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.word).font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                    HStack(spacing: 8) {
                        Text("/\(word.ipa)/").font(.system(.title3, design: .serif)).foregroundStyle(Theme.primary)
                        Text(word.pos).font(.caption.italic()).foregroundStyle(.secondary)
                    }
                    Text("\(word.syllables) âm tiết").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: toggleSave) {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark").font(.title2)
                }
            }
            HStack {
                CircleToolButton(systemImage: "speaker.wave.2.fill", title: "Nghe") {
                    SpeechPlayer.shared.speak(word.word)
                }
                Spacer()
                CircleToolButton(systemImage: "tortoise.fill", title: "Nghe chậm") {
                    SpeechPlayer.shared.speak(word.word, slow: true)
                }
                Spacer()
                CircleToolButton(systemImage: "mic.fill", title: "Nói") {
                    speak(PracticeItem(key: "w:\(word.id)", text: word.word, ipa: word.ipa))
                }
                Spacer()
                CircleToolButton(systemImage: "mouth.fill", title: "Khẩu hình") { showMouth = true }
            }
            .padding(.horizontal, 6)
            .sheet(isPresented: $showMouth) {
                MouthGuideSheet(phoneIDs: [], item: PracticeItem(key: "w:\(word.id)", text: word.word, ipa: word.ipa))
            }
            if let credit {
                Link(destination: URL(string: credit.source) ?? URL(string: "https://commons.wikimedia.org")!) {
                    Label(credit.line, systemImage: "person.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Divider()
            Text(word.meaningVi).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text(word.exampleEn).font(.body.italic())
                Text(word.exampleVi).font(.subheadline).foregroundStyle(.secondary)
                Button { speak(PracticeItem(key: "e:\(word.id)", text: word.exampleEn)) } label: {
                    Label("Luyện nói câu ví dụ (nối âm + ngữ điệu)", systemImage: "waveform")
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let tip = word.tipVi, !tip.isEmpty {
                Label(tip, systemImage: "lightbulb.fill").font(.subheadline).foregroundStyle(Theme.ok)
            }
            Link(destination: cambridgeURL) {
                Label("Xem thêm trên Cambridge Dictionary", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }
        }
        .card(padding: 20)
        .task(id: word.word) { await loadRecording() }
    }

    /// Prefetches the human recording so "Nghe" plays it instantly, and shows who recorded it.
    private func loadRecording() async {
        credit = WordAudioCache.credit(for: word.word)
        guard credit == nil, let key = WordAudioCache.key(word.word), !WordAudioCache.isMissing(key) else { return }
        if await WordAudioCache.fetch(key) { credit = WordAudioCache.credit(for: word.word) }
    }

    private var cambridgeURL: URL {
        DictionaryView.cambridgeURL(word.word)
    }
}

/// Flashcards for words that are due: recall the meaning, flip, grade yourself.
struct WordReviewView: View {
    let words: [VocabWord]

    @Environment(\.dismiss) private var dismiss
    @Environment(ProgressStore.self) private var progress
    @State private var index = 0
    @State private var flipped = false
    @State private var remembered = 0

    var body: some View {
        VStack(spacing: 20) {
            if let word = words[safe: index] {
                QuizHeader(index: index, total: words.count, score: remembered)
                Spacer()
                Button {
                    withAnimation(.spring) { flipped.toggle() }
                    if !flipped { SpeechPlayer.shared.speak(word.word) }
                } label: {
                    VStack(spacing: 12) {
                        Text(word.word).font(.largeTitle.bold()).foregroundStyle(Theme.ink)
                        Text("/\(word.ipa)/").font(.system(.title3, design: .serif)).foregroundStyle(Theme.primary)
                        if flipped {
                            Divider()
                            Text(word.meaningVi).font(.title3.weight(.semibold))
                            Text(word.exampleEn).font(.subheadline.italic()).foregroundStyle(.secondary)
                        } else {
                            Text("Chạm để xem nghĩa").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .card(padding: 24)
                }
                .buttonStyle(.plain)
                .onAppear { SpeechPlayer.shared.speak(word.word) }
                Spacer()
                if flipped {
                    HStack(spacing: 12) {
                        Button("Quên rồi") { grade(word, false) }.buttonStyle(PrimaryButtonStyle(color: Theme.bad))
                        Button("Nhớ") { grade(word, true) }.buttonStyle(PrimaryButtonStyle(color: Theme.good))
                    }
                }
            } else {
                QuizSummaryView(score: remembered, total: words.count, actionTitle: "Xong") { dismiss() }
            }
        }
        .padding(20)
        .screenBackground()
        .inlineNavigationTitle("Ôn từ vựng")
    }

    private func grade(_ word: VocabWord, _ ok: Bool) {
        progress.gradeWord(word, remembered: ok)
        if ok { remembered += 1 }
        flipped = false
        index += 1
    }
}

struct SavedWordsView: View {
    @Environment(ProgressStore.self) private var progress
    @State private var practising: PracticeItem?

    var body: some View {
        List(progress.savedWords) { word in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(word.word).font(.headline)
                    Text("/\(word.ipa)/ · \(word.meaningVi)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { SpeechPlayer.shared.speak(word.word) } label: { Image(systemName: "speaker.wave.2.fill") }
                    .buttonStyle(.borderless)
                Button { practising = PracticeItem(key: "w:\(word.id)", text: word.word, ipa: word.ipa) } label: {
                    Image(systemName: "mic.fill")
                }
                .buttonStyle(.borderless)
            }
            .listRowBackground(Theme.surface.opacity(0.78))
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .inlineNavigationTitle("Sổ từ")
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }
}

/// Open-data lookup (CMUdict pronunciation + Wiktionary/LLM meaning) with a link to Cambridge.
struct DictionaryView: View {
    let word: String

    @Environment(ProgressStore.self) private var progress
    @State private var result: DictionaryResult?
    @State private var error: String?
    @State private var practising: PracticeItem?

    static func cambridgeURL(_ word: String) -> URL {
        let slug = word.lowercased().replacingOccurrences(of: " ", with: "-")
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "https://dictionary.cambridge.org/dictionary/english-vietnamese/\(encoded)")!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result {
                    content(result)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad).card()
                    Link("Tra trên Cambridge Dictionary", destination: Self.cambridgeURL(word))
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
        }
        .screenBackground()
        .inlineNavigationTitle(word)
        .task {
            do { result = try await APIClient.current().define(word) } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $practising) { item in
            NavigationStack { SpeakingSessionView(item: item).closeToolbar() }
        }
    }

    @ViewBuilder
    private func content(_ result: DictionaryResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.word).font(.largeTitle.bold())
            if let ipa = result.ipa {
                Text("/\(ipa)/  US").font(.system(.title3, design: .serif)).foregroundStyle(Theme.primary)
            }
            HStack(spacing: 10) {
                Button { SpeechPlayer.shared.speak(result.word) } label: { Label("Nghe", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(PillButtonStyle())
                Button { practising = PracticeItem(key: "w:\(result.word.lowercased())", text: result.word, ipa: result.ipa) } label: {
                    Label("Luyện nói", systemImage: "mic.fill")
                }
                .buttonStyle(PillButtonStyle())
                Button { progress.save(vocabWord(result)) } label: {
                    Label("Lưu", systemImage: "bookmark")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .card()

        ForEach(Array(result.entries.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let pos = entry.pos { Text(pos).font(.headline.italic()) }
                    if let uk = entry.ipaUk { Text("UK /\(uk)/").font(.system(.subheadline, design: .serif)).foregroundStyle(.secondary) }
                }
                ForEach(Array(entry.senses.enumerated()), id: \.offset) { number, sense in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(number + 1). \(sense.vi.joined(separator: ", "))").font(.body.weight(.semibold))
                        if !sense.gloss.isEmpty {
                            Text(sense.gloss).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card()
        }
        if result.entries.isEmpty {
            Label("Chưa có nghĩa tiếng Việt cho từ này. Bạn vẫn nghe và luyện nói được; nghĩa đầy đủ có trên Cambridge Dictionary.",
                  systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(.secondary).card()
        }
        if let source = result.source {
            Text("Nguồn: \(source)").font(.caption).foregroundStyle(.secondary)
        }
        Link(destination: URL(string: result.cambridgeUrl) ?? Self.cambridgeURL(result.word)) {
            Label("Xem trên Cambridge Dictionary", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private func vocabWord(_ result: DictionaryResult) -> VocabWord {
        let entry = result.entries.first
        let sense = entry?.senses.first
        return VocabWord(word: result.word, pos: entry?.pos ?? "", meaningVi: sense?.vi.joined(separator: ", ") ?? "",
                         exampleEn: "", exampleVi: "", tipVi: nil, ipa: result.ipa ?? "", connectedIpa: nil,
                         phones: result.phones, syllables: max(1, result.phones.filter { content.isVowel($0) }.count))
    }

    @Environment(ContentStore.self) private var content
}

extension ContentStore {
    func isVowel(_ id: String) -> Bool {
        guard let phoneme = phoneme(id) else { return false }
        return phoneme.category != .consonant
    }
}
