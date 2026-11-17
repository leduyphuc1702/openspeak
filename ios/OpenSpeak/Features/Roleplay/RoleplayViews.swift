import Observation
import SwiftUI

/// Workplace roleplay scenarios, plus "make one from my topic" via the LLM.
struct RoleplayListView: View {
    @AppStorage(Prefs.level) private var level = "beginner"
    @State private var scenarios: [RoleplayScenario] = []
    @State private var error: String?
    @State private var topic = ""
    @State private var creating = false
    @State private var path: [RoleplayScenario] = []
    @FocusState private var editingTopic: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nhập vai tình huống thật ở công sở. Bạn nói, AI đáp lại và sửa từng câu.")
                    .font(.subheadline).foregroundStyle(.secondary)
                customCard
                if let error {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(Theme.bad).card()
                }
                ForEach(scenarios) { scenario in
                    NavigationLink(value: scenario) { ScenarioRow(scenario: scenario) }
                        .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("Hội thoại AI")
        .toolbar { ToolbarItem(placement: .primaryAction) { StatsBar() } }
        .navigationDestination(for: RoleplayScenario.self) { RoleplayIntroView(scenario: $0) }
        .task { await load() }
        .refreshable { await load() }
    }

    private var customCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tình huống của riêng bạn").font(.headline).foregroundStyle(Theme.ink)
            TextField("VD: báo cáo tiến độ với sếp", text: $topic, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .focused($editingTopic)
                .padding(12)
                .background(Theme.subtle.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            Button {
                editingTopic = false
                Task { await create() }
            } label: {
                if creating { ProgressView().tint(.white) } else { Text("Tạo tình huống") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            .opacity(topic.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .card(padding: 16)
    }

    private func load() async {
        do {
            scenarios = try await APIClient.current().roleplayScenarios()
            error = nil
        } catch {
            self.error = "Không tải được tình huống: \(error.localizedDescription)"
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let scenario = try await APIClient.current().roleplayStart(topic: topic, level: level)
            scenarios.insert(scenario, at: 0)
            topic = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ScenarioRow: View {
    let scenario: RoleplayScenario

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(scenario.title).font(.headline).foregroundStyle(Theme.ink)
                Text(scenario.titleVi).font(.subheadline).foregroundStyle(.secondary)
                Text("\(scenario.minutes) phút • \(scenario.level)").font(.caption).foregroundStyle(Theme.glow)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card(padding: 14)
    }
}

/// Scenario brief: title, length and level, the setting, and the three tasks.
struct RoleplayIntroView: View {
    let scenario: RoleplayScenario
    @State private var vietnamese = false
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(vietnamese ? scenario.titleVi : scenario.title)
                            .font(.title2.bold()).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        Text("\(scenario.minutes) phút • \(scenario.level)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.hero)
                        VStack(spacing: 10) {
                            Image(systemName: "person.2.wave.2.fill").font(.system(size: 54)).foregroundStyle(.white)
                            Text("AI đóng vai: \(scenario.partner)").font(.subheadline.bold()).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .frame(height: 170)
                    if !scenario.settingVi.isEmpty {
                        Text(scenario.settingVi).font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Nhiệm vụ", systemImage: "checklist").font(.title3.bold()).foregroundStyle(Theme.ink)
                        ForEach(Array(scenario.tasks.enumerated()), id: \.offset) { index, task in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)").font(.title2.bold()).foregroundStyle(.secondary).frame(width: 24)
                                Text(vietnamese ? task.vi : task.en).font(.body).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
            }
            HStack(spacing: 12) {
                Button { vietnamese.toggle() } label: {
                    Image(systemName: "character.bubble.fill")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(vietnamese ? Theme.primaryFill : Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(vietnamese ? "Hiện tiếng Anh" : "Hiện tiếng Việt")
                Button("Bắt đầu hội thoại") { started = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
        }
        .screenBackground()
        .inlineNavigationTitle("")
        .fullScreenCoverCompat(isPresented: $started) {
            NavigationStack { RoleplayChatView(scenario: scenario).closeToolbar() }
        }
    }
}

@MainActor
@Observable
final class RoleplayChatModel {
    let scenario: RoleplayScenario
    private(set) var messages: [RoleplayMessage] = []
    private(set) var tasksDone: [Bool]
    private(set) var hint: String?
    private(set) var sending = false
    private(set) var transcribing = false
    private(set) var error: String?
    let recorder = AudioRecorder()
    private let reference = ReferenceAudioRenderer()

    init(scenario: RoleplayScenario) {
        self.scenario = scenario
        tasksDone = Array(repeating: false, count: scenario.tasks.count)
        messages = [RoleplayMessage(fromAI: true, text: scenario.opening)]
    }

    var finished: Bool { !tasksDone.isEmpty && tasksDone.allSatisfy { $0 } }
    var busy: Bool { sending || transcribing }

    /// Records the turn as a WAV file; the same file gives the words (speech recognition) and the
    /// pronunciation and intonation scores (phoneme model on the backend).
    func micTapped(level: String, progress: ProgressStore) async {
        if recorder.isRecording {
            guard let audio = recorder.stop() else { return }
            await handleTake(audio, level: level, progress: progress)
            return
        }
        guard await SpeechTranscriber.authorize(), await recorder.requestPermission() else {
            error = "Cần quyền micro và nhận dạng giọng nói (Cài đặt > Quyền riêng tư)."
            return
        }
        do {
            try recorder.start()
            error = nil
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleTake(_ audio: URL, level: String, progress: ProgressStore) async {
        transcribing = true
        defer { transcribing = false }
        do {
            let text = try await SpeechTranscriber.transcribe(audio, hints: hints)
            transcribing = false
            await send(text, audio: audio, level: level, progress: progress)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Phrases the learner is likely to say next.
    private var hints: [String] {
        var phrases = scenario.tasks.map(\.en)
        if let last = messages.last(where: \.fromAI) { phrases.append(last.text) }
        phrases += messages.compactMap(\.betterVersion)
        return phrases
    }

    func send(_ text: String, audio: URL? = nil, level: String, progress: ProgressStore) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending else { return }
        let history = messages
        var turnMessage = RoleplayMessage(fromAI: false, text: message)
        turnMessage.audio = audio
        messages.append(turnMessage)
        let id = turnMessage.id
        if audio != nil {
            Task { await score(id, progress: progress) }
        }
        sending = true
        defer { sending = false }
        do {
            let turn = try await APIClient.current().roleplayTurn(scenario: scenario, history: history, message: message, level: level)
            update(id) {
                $0.corrections = turn.corrections
                $0.betterVersion = turn.betterVersion
            }
            let before = tasksDone.filter { $0 }.count
            tasksDone = zip(tasksDone, turn.tasksDone + Array(repeating: false, count: max(0, tasksDone.count - turn.tasksDone.count)))
                .map { $0 || $1 }
            hint = turn.hintVi
            messages.append(RoleplayMessage(fromAI: true, text: turn.reply))
            progress.recordRoleplayTurn(newTasksDone: tasksDone.filter { $0 }.count - before)
            SpeechPlayer.shared.speak(turn.reply)
            error = nil
        } catch {
            self.error = "AI chưa trả lời được: \(error.localizedDescription)"
        }
    }

    /// Scores the recording of a spoken turn against the words it was recognised as.
    func score(_ id: UUID, progress: ProgressStore) async {
        guard let message = messages.first(where: { $0.id == id }), let audio = message.audio else { return }
        update(id) {
            $0.scoring = true
            $0.scoreError = nil
        }
        do {
            let client = try APIClient.current()
            let referenceURL = try? await reference.render(message.text)
            let result = try await client.assess(text: message.text, audio: audio, reference: referenceURL, skipUnknown: true)
            // Conversation results count like any other speaking practice, so the personal path sees them.
            progress.record(result, key: "r:\(message.text.lowercased())")
            update(id) { $0.assessment = result }
        } catch {
            update(id) { $0.scoreError = "Chưa chấm được phát âm: \(error.localizedDescription)" }
        }
        update(id) { $0.scoring = false }
    }

    /// The recogniser heard other words than the learner meant: score the same recording against the right text.
    func correctTranscript(_ id: UUID, to text: String, progress: ProgressStore) async {
        let fixed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixed.isEmpty else { return }
        update(id) {
            $0.text = fixed
            $0.assessment = nil
        }
        await score(id, progress: progress)
    }

    private func update(_ id: UUID, _ change: (inout RoleplayMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}

/// The conversation: task progress on top, chat bubbles with corrections, mic or keyboard at the bottom.
struct RoleplayChatView: View {
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.level) private var level = "beginner"
    @State private var model: RoleplayChatModel
    @State private var draft = ""
    @State private var typing = false
    @State private var editing: RoleplayMessage?
    @State private var editText = ""

    init(scenario: RoleplayScenario) {
        _model = State(initialValue: RoleplayChatModel(scenario: scenario))
    }

    var body: some View {
        VStack(spacing: 0) {
            taskStrip
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message,
                                       edit: {
                                           editText = message.text
                                           editing = message
                                       },
                                       retryScore: { Task { await model.score(message.id, progress: progress) } })
                                .id(message.id)
                        }
                        if model.sending {
                            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.finished {
                            Label("Hoàn thành cả \(model.scenario.tasks.count) nhiệm vụ!", systemImage: "checkmark.seal.fill")
                                .font(.headline).foregroundStyle(Theme.good).card()
                        }
                    }
                    .padding(16)
                }
                // A turn's score card arrives after the AI has answered and makes that turn taller,
                // so follow every change in height, not only new messages.
                .onChange(of: layoutKey) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = model.error {
                Text(error)
                    .font(.footnote).foregroundStyle(Theme.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("roleplay.error")
            }
            inputBar
        }
        .screenBackground()
        .inlineNavigationTitle(model.scenario.title)
        .onAppear { SpeechPlayer.shared.speak(model.scenario.opening) }
        .onDisappear { if model.recorder.isRecording { model.recorder.stop() } }
        .alert("Sửa câu bạn định nói", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Câu tiếng Anh", text: $editText)
            Button("Chấm lại") {
                if let id = editing?.id {
                    let text = editText
                    Task { await model.correctTranscript(id, to: text, progress: progress) }
                }
                editing = nil
            }
            Button("Huỷ", role: .cancel) { editing = nil }
        } message: {
            Text("Máy nhận dạng có thể nghe nhầm từ. Sửa lại đúng câu bạn định nói, app sẽ chấm lại chính bản ghi đó theo câu này.")
        }
    }

    private var layoutKey: [String] {
        model.messages.map { "\($0.id)-\($0.scoring)-\($0.assessment != nil)-\($0.scoreError != nil)" } + ["\(model.sending)"]
    }

    private var taskStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.scenario.tasks.enumerated()), id: \.offset) { index, task in
                let done = model.tasksDone[safe: index] ?? false
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .foregroundStyle(done ? Theme.good : .secondary)
                    Text(task.vi).foregroundStyle(done ? Theme.ink : .secondary)
                }
            }
            if let hint = model.hint {
                Label(hint, systemImage: "lightbulb.fill").foregroundStyle(Theme.ok).padding(.top, 2)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface.opacity(0.9))
    }

    private var status: String {
        if model.recorder.isRecording { return "Đang ghi âm… Chạm ■ để gửi" }
        if model.transcribing { return "Đang nhận dạng câu bạn nói…" }
        if model.sending { return "AI đang trả lời…" }
        return "Chạm micro để nói, chạm lần nữa để gửi"
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            if typing {
                TextField("Nhập câu trả lời bằng tiếng Anh", text: $draft)
                    .padding(12)
                    .background(Theme.subtle, in: Capsule())
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Gửi")
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
            } else {
                HStack(spacing: 8) {
                    if model.busy { ProgressView() }
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(model.recorder.isRecording ? Theme.ink : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await model.micTapped(level: level, progress: progress) }
                } label: {
                    Image(systemName: model.recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                        .background(model.recorder.isRecording ? Theme.badFill : Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(color: Theme.glow.opacity(0.6), radius: 10)
                        .opacity(model.busy ? 0.5 : 1)
                }
                .disabled(model.busy)
                .accessibilityLabel(model.recorder.isRecording ? "Dừng và gửi" : "Ghi âm")
                .accessibilityIdentifier("roleplay.mic")
            }
            Button { typing.toggle() } label: {
                Image(systemName: typing ? "mic" : "keyboard").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(typing ? "Nói" : "Gõ phím")
        }
        .buttonStyle(.plain)
        .padding(16)
        .background(Theme.surface.opacity(0.9))
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await model.send(text, level: level, progress: progress) }
    }
}

private struct ChatBubble: View {
    let message: RoleplayMessage
    let edit: () -> Void
    let retryScore: () -> Void

    var body: some View {
        VStack(alignment: message.fromAI ? .leading : .trailing, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.fromAI { Spacer(minLength: 40) }
                bubbleText
                    .padding(12)
                    .background(message.fromAI || message.assessment != nil ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.primary),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        if message.assessment != nil {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.primary, lineWidth: 2)
                        }
                    }
                if message.fromAI {
                    Button { SpeechPlayer.shared.speak(message.text) } label: {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.glow)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nghe lại")
                    Spacer(minLength: 40)
                }
            }
            if message.fromAI {
                NavigationLink {
                    SpeakingSessionView(item: PracticeItem(text: message.text))
                } label: {
                    Label("Nói lại câu này (chấm phát âm)", systemImage: "waveform").font(.caption.bold())
                }
            }
            if message.audio != nil {
                TurnPronunciationCard(message: message, edit: edit, retry: retryScore)
            }
            if !message.corrections.isEmpty || message.betterVersion != nil {
                CorrectionCard(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.fromAI ? .leading : .trailing)
    }

    /// A scored spoken turn shows each word in its score colour, like the speaking screen.
    @ViewBuilder
    private var bubbleText: some View {
        if let assessment = message.assessment, !message.fromAI {
            colouredText(assessment)
                .font(.body.weight(.semibold))
                .accessibilityIdentifier("roleplay.userTurn")
        } else {
            Text(message.text)
                .font(.body)
                .foregroundStyle(message.fromAI ? Theme.ink : Theme.background)
                .accessibilityIdentifier(message.fromAI ? "roleplay.aiTurn" : "roleplay.userTurn")
        }
    }

    private func colouredText(_ assessment: Assessment) -> SwiftUI.Text {
        var scores: [String: [Int?]] = [:]
        for word in assessment.words { scores[word.word.lowercased(), default: []].append(word.score) }
        var result = SwiftUI.Text("")
        let tokens = message.text.split(separator: " ", omittingEmptySubsequences: true)
        for (index, token) in tokens.enumerated() {
            let key = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            var color = Theme.ink
            if var list = scores[key], !list.isEmpty {
                color = Theme.scoreColor(list.removeFirst())
                scores[key] = list
            }
            result = result + SwiftUI.Text((index > 0 ? " " : "") + token).foregroundColor(color)
        }
        return result
    }
}

/// Under a spoken turn: how it was pronounced (phoneme model) and how the voice moved (intonation).
private struct TurnPronunciationCard: View {
    let message: RoleplayMessage
    let edit: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let assessment = message.assessment {
                NavigationLink {
                    TurnAssessmentView(text: message.text, assessment: assessment, audio: message.audio,
                                       practice: message.betterVersion ?? message.text)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ScoreRing(score: assessment.scores.overall, size: 46, lineWidth: 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Phát âm \(score(assessment.scores.pronunciation)) · Ngữ điệu \(score(assessment.scores.intonation))")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text(intonationLine(assessment)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(issues(assessment), id: \.self) { issue in
                            SwiftUI.Label {
                                Text(issue).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.bad)
                            }
                            .font(.caption).foregroundStyle(Theme.ink)
                        }
                        if let skipped = assessment.skippedWords, !skipped.isEmpty {
                            Text("Không chấm: \(skipped.joined(separator: ", ")) (chưa có trong từ điển phát âm)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Label("Xem chi tiết và luyện lại", systemImage: "chevron.right")
                            .font(.caption.bold()).foregroundStyle(Theme.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("roleplay.pronunciation")
            } else if message.scoring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Đang chấm phát âm và ngữ điệu…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = message.scoreError {
                Text(error).font(.caption).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
                Button("Chấm lại", action: retry).font(.caption.bold())
            }
            Button(action: edit) {
                Label("Máy nghe nhầm chữ? Sửa câu", systemImage: "pencil").font(.caption2.weight(.semibold))
            }
            .disabled(message.scoring)
            .accessibilityIdentifier("roleplay.editTranscript")
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func score(_ value: Int?) -> String { value.map(String.init) ?? "–" }

    private func intonationLine(_ assessment: Assessment) -> String {
        let i = assessment.intonation
        let want = i.expected == "rising" ? "lên giọng" : "xuống giọng"
        switch i.detected {
        case i.expected?: return "Cuối câu \(want) đúng như cần."
        case "rising": return "Cuối câu cần \(want), bạn lại lên giọng."
        case "falling": return "Cuối câu cần \(want), bạn lại xuống giọng."
        case "flat": return "Cuối câu cần \(want), bạn giữ giọng đều đều."
        default: return "Chưa đo được ngữ điệu cuối câu."
        }
    }

    /// The two weakest sounds, in the words they were in.
    private func issues(_ assessment: Assessment) -> [String] {
        let weak = assessment.words.flatMap { word in word.phones.map { (word: word.word, phone: $0) } }
            .filter { $0.phone.status != .good }
            .sorted { ($0.phone.score ?? 0) < ($1.phone.score ?? 0) }
        return weak.prefix(2).map { item in
            let p = item.phone
            switch p.status {
            case .substituted: return "\(item.word): /\(p.expected)/ nghe như /\(p.heard ?? "?")/"
            case .missing: return "\(item.word): bị bỏ mất /\(p.expected)/"
            default: return "\(item.word): /\(p.expected)/ chưa rõ (\(p.score ?? 0) điểm)"
            }
        }
    }
}

/// The full result of one spoken turn, with a way to practise the sentence properly.
private struct TurnAssessmentView: View {
    let text: String
    let assessment: Assessment
    let audio: URL?
    let practice: String
    @State private var tab: AssessmentResultView.ResultTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            ResultTabBar(assessment: assessment, tab: $tab)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 16) {
                    PromptCard(item: PracticeItem(text: text), assessment: assessment)
                    AssessmentResultView(assessment: assessment,
                                         playMine: { if let audio { SpeechPlayer.shared.play(url: audio) } },
                                         tab: $tab)
                }
                .padding(20)
            }
            NavigationLink {
                SpeakingSessionView(item: PracticeItem(text: practice))
            } label: {
                Label("Luyện nói lại câu này", systemImage: "mic.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .screenBackground()
        .inlineNavigationTitle("Lượt nói của bạn")
    }
}

private struct CorrectionCard: View {
    let message: RoleplayMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.corrections, id: \.self) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.original).strikethrough().foregroundStyle(Theme.bad)
                    Text(c.better).bold().foregroundStyle(Theme.good)
                    if !c.explainVi.isEmpty {
                        Text(c.explainVi).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let better = message.betterVersion, better.lowercased() != message.text.lowercased() {
                Divider()
                Text("Cách nói tự nhiên hơn").font(.caption.bold()).foregroundStyle(.secondary)
                Text(better).foregroundStyle(Theme.ink)
                NavigationLink {
                    SpeakingSessionView(item: PracticeItem(text: better))
                } label: {
                    Label("Luyện nói câu này", systemImage: "mic.fill").font(.caption.bold())
                }
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.ok.opacity(0.4), lineWidth: 1))
    }
}
