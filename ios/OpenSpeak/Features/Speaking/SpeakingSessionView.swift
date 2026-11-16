import Observation
import SwiftUI

/// Anything the learner can say out loud: a word, an example sentence, a practice sentence.
struct PracticeItem: Hashable, Identifiable {
    let key: String
    let text: String
    var ipa: String?
    var connectedIPA: String?
    var links: [SentenceLink] = []
    var intonation: String?
    /// Sound to coach first (e.g. the sound of the current IPA lesson).
    var focusPhone: String?

    var id: String { key }

    init(key: String? = nil, text: String, ipa: String? = nil, connectedIPA: String? = nil,
         links: [SentenceLink] = [], intonation: String? = nil, focusPhone: String? = nil) {
        self.key = key ?? text.lowercased()
        self.text = text
        self.ipa = ipa
        self.connectedIPA = connectedIPA
        self.links = links
        self.intonation = intonation
        self.focusPhone = focusPhone
    }

    init(sentence: PracticeSentence) {
        self.init(key: sentence.id, text: sentence.text, ipa: sentence.ipa, connectedIPA: sentence.connectedIPA,
                  links: sentence.links, intonation: sentence.intonation)
    }

    init(word: WordEntry, focus: String? = nil) {
        self.init(key: "w:\(word.word)", text: word.word, ipa: word.ipa, focusPhone: focus)
    }
}

@MainActor
@Observable
final class SpeakingViewModel {
    enum Phase {
        case idle
        case recording
        case analyzing
        case result(Assessment)
        case failed(String)
    }

    private(set) var item: PracticeItem
    private(set) var phase: Phase = .idle
    let recorder = AudioRecorder()
    private let reference = ReferenceAudioRenderer()

    init(item: PracticeItem) {
        self.item = item
    }

    var assessment: Assessment? {
        if case .result(let assessment) = phase { return assessment }
        return nil
    }

    /// Fills in the transcription and linking marks from the backend when the item has none.
    func loadTranscriptionIfNeeded() async {
        guard item.ipa == nil || (item.connectedIPA == nil && item.text.contains(" ")),
              let client = try? APIClient.current(),
              let result = try? await client.phonemize(item.text) else { return }
        item.ipa = item.ipa ?? result.ipa
        item.connectedIPA = result.connectedIpa
        item.links = result.links.map { SentenceLink(display: $0.display, type: $0.type, hint: $0.hint) }
        item.intonation = item.intonation ?? result.intonation
    }

    func micTapped(progress: ProgressStore) async {
        if recorder.isRecording {
            guard let audio = recorder.stop() else { return }
            await analyze(audio: audio, progress: progress)
            return
        }
        guard await recorder.requestPermission() else {
            phase = .failed("Ứng dụng cần quyền dùng micro. Bật trong Cài đặt > Quyền riêng tư > Micro.")
            return
        }
        do {
            try recorder.start()
            phase = .recording
            Haptics.tap()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func analyze(audio: URL, progress: ProgressStore) async {
        phase = .analyzing
        do {
            let client = try APIClient.current()
            let referenceURL = try? await reference.render(item.text)
            let result = try await client.assess(text: item.text, audio: audio, reference: referenceURL)
            progress.record(result, key: item.key)
            Haptics.result(success: (result.scores.overall ?? 0) >= 80)
            phase = .result(result)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func playMyRecording() {
        if let url = recorder.lastRecording { SpeechPlayer.shared.play(url: url) }
    }
}

/// The core speaking screen: target text on top, big mic at the bottom, results in between.
struct SpeakingSessionView: View {
    @Environment(ProgressStore.self) private var progress
    @Environment(ContentStore.self) private var content
    @State private var model: SpeakingViewModel
    @State private var showMouthGuide = false
    @State private var showCamera = false
    @State private var resultTab: AssessmentResultView.ResultTab = .overview
    var onFinished: ((Assessment) -> Void)?

    init(item: PracticeItem, onFinished: ((Assessment) -> Void)? = nil) {
        _model = State(initialValue: SpeakingViewModel(item: item))
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(spacing: 0) {
            if let assessment = model.assessment {
                ResultTabBar(assessment: assessment, tab: $resultTab)
                    .padding(.horizontal, 20)
                    .padding(.top, 6).padding(.bottom, 10)
            }
            ScrollView {
                VStack(spacing: 16) {
                    PromptCard(item: model.item, assessment: model.assessment)
                    switch model.phase {
                    case .result(let assessment):
                        AssessmentResultView(assessment: assessment, playMine: model.playMyRecording, tab: $resultTab)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.bad)
                            .card()
                    default:
                        if !model.item.links.isEmpty {
                            LinkGuideCard(links: model.item.links)
                        }
                    }
                }
                .padding(20)
            }
            controls
        }
        .screenBackground()
        .inlineNavigationTitle("Luyện nói")
        .task { await model.loadTranscriptionIfNeeded() }
        .onDisappear { if model.recorder.isRecording { model.recorder.stop() } }
        .onChange(of: model.assessment?.scores.overall) { _, _ in
            if let assessment = model.assessment { onFinished?(assessment) }
        }
        .onChange(of: model.assessment == nil) { _, cleared in
            if cleared { resultTab = .overview }
        }
        .sheet(isPresented: $showMouthGuide) {
            MouthGuideSheet(phoneIDs: guidePhones, item: model.item)
        }
        .fullScreenCoverCompat(isPresented: $showCamera) {
            MouthCoachView(item: model.item)
        }
    }

    /// The lesson sound first, then the weakest sounds from the last attempt.
    private var guidePhones: [String] {
        var ids: [String] = []
        if let focus = model.item.focusPhone { ids.append(focus) }
        if let assessment = model.assessment {
            let weak = assessment.words.flatMap(\.phones)
                .filter { $0.status != .good }
                .sorted { ($0.score ?? 0) < ($1.score ?? 0) }
                .compactMap(\.id)
            ids += weak
        }
        if ids.isEmpty, let word = content.readingWords.first(where: { $0.word.lowercased() == model.item.text.lowercased() }) {
            ids = word.phones
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private var controls: some View {
        HStack(alignment: .center) {
            CircleToolButton(systemImage: "mouth.fill", title: "Khẩu hình") { showMouthGuide = true }
                .disabled(guidePhones.isEmpty && model.item.ipa == nil)
            Spacer()
            if case .analyzing = model.phase {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large)
                    Text("AI đang nghe…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 128, height: 128)
            } else {
                MicButton(isRecording: model.recorder.isRecording, level: model.recorder.level) {
                    Task { await model.micTapped(progress: progress) }
                }
            }
            Spacer()
            CircleToolButton(systemImage: "video.fill", title: "Quay miệng") { showCamera = true }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Theme.surface.shadow(.drop(color: .black.opacity(0.06), radius: 10, y: -4)))
    }
}

struct CircleToolButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 52, height: 52)
                    .background(Theme.primary.opacity(0.12), in: Circle())
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.primary)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// The target text, coloured word by word once scored, with the transcription underneath.
struct PromptCard: View {
    let item: PracticeItem
    let assessment: Assessment?

    var body: some View {
        VStack(spacing: 10) {
            if let assessment {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    ForEach(assessment.words) { word in
                        Text(word.word)
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.scoreColor(word.score))
                    }
                }
            } else {
                Text(item.text)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink)
            }
            if let ipa = transcription {
                Text("/\(ipa)/")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.center)
            }
            if let intonation = item.intonation, item.text.contains(" ") {
                Label(intonation == "rising" ? "Lên giọng ở cuối câu" : "Xuống giọng ở cuối câu",
                      systemImage: intonation == "rising" ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { SpeechPlayer.shared.speak(item.text) } label: {
                    Label("Nghe mẫu", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(PillButtonStyle())
                Button { SpeechPlayer.shared.speak(item.text, slow: true) } label: {
                    Label("Chậm", systemImage: "tortoise.fill")
                }
                .buttonStyle(PillButtonStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }

    /// Linked transcription (with ‿) when available, since that is how natives say it.
    private var transcription: String? {
        if let connected = item.connectedIPA, connected.contains("‿") { return connected }
        return item.ipa
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.primary.opacity(configuration.isPressed ? 0.2 : 0.1), in: Capsule())
    }
}

/// Explains each place where words run together, before the learner speaks.
struct LinkGuideCard: View {
    let links: [SentenceLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nối âm như người bản xứ", systemImage: "link").font(.headline)
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                HStack(alignment: .top, spacing: 10) {
                    Text(link.display)
                        .font(.system(.body, design: .serif).weight(.semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    Text(link.hint).font(.subheadline).foregroundStyle(Theme.ink)
                }
            }
        }
        .card()
    }
}

/// Mouth diagrams and step-by-step instructions for a list of sounds.
struct MouthGuideSheet: View {
    let phoneIDs: [String]
    var item: PracticeItem? = nil
    @Environment(ContentStore.self) private var content
    @State private var selected: String?
    @State private var wholeItem = true

    var body: some View {
        NavigationStack {
            Group {
                if let item, let ipa = item.connectedIPA ?? item.ipa, wholeItem {
                    WordMouthPlayer(text: item.text, ipa: ipa, intonation: item.intonation, content: content) {
                        modePicker(item)
                        Text(item.text).font(.title2.bold()).foregroundStyle(Theme.ink)
                    }
                    .id(item.key)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let item, item.connectedIPA ?? item.ipa != nil {
                                modePicker(item)
                            }
                            phoneList
                        }
                        .padding(20)
                    }
                }
            }
            .screenBackground()
            .inlineNavigationTitle("Hướng dẫn khẩu hình")
            .closeToolbar()
        }
    }

    private func modePicker(_ item: PracticeItem) -> some View {
        Picker("Chế độ", selection: $wholeItem) {
            SwiftUI.Text(item.text.contains(" ") ? "Cả câu" : "Cả từ").tag(true)
            SwiftUI.Text("Từng âm").tag(false)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var phoneList: some View {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(phonemes) { phoneme in
                                Button { selected = phoneme.id } label: {
                                    Text("/\(phoneme.symbol)/")
                                        .font(.system(.title3, design: .serif).bold())
                                        .padding(.horizontal, 14)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .background(current?.id == phoneme.id ? Theme.primaryFill : Theme.surface, in: Capsule())
                                        .foregroundStyle(current?.id == phoneme.id ? .white : Theme.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let phoneme = current {
                        ArticulationCard(phoneme: phoneme)
                    }
    }

    private var phonemes: [Phoneme] { phoneIDs.compactMap(content.phoneme) }
    private var current: Phoneme? { content.phoneme(selected) ?? phonemes.first }
}

extension View {
    /// Full-screen cover on iOS; a sheet where full-screen covers do not exist.
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
