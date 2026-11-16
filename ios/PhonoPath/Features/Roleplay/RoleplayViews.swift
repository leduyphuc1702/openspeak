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
    private(set) var error: String?
    let transcriber = SpeechTranscriber()

    init(scenario: RoleplayScenario) {
        self.scenario = scenario
        tasksDone = Array(repeating: false, count: scenario.tasks.count)
        messages = [RoleplayMessage(fromAI: true, text: scenario.opening)]
    }

    var finished: Bool { !tasksDone.isEmpty && tasksDone.allSatisfy { $0 } }

    func micTapped(level: String, progress: ProgressStore) async {
        if transcriber.isRunning {
            let text = await transcriber.stop()
            if !text.isEmpty { await send(text, level: level, progress: progress) }
            return
        }
        guard await transcriber.authorize() else {
            error = "Cần quyền micro và nhận dạng giọng nói (Cài đặt > Quyền riêng tư)."
            return
        }
        do {
            try transcriber.start()
            error = nil
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ text: String, level: String, progress: ProgressStore) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending else { return }
        let history = messages
        messages.append(RoleplayMessage(fromAI: false, text: message))
        let userIndex = messages.count - 1
        sending = true
        defer { sending = false }
        do {
            let turn = try await APIClient.current().roleplayTurn(scenario: scenario, history: history, message: message, level: level)
            messages[userIndex].corrections = turn.corrections
            messages[userIndex].betterVersion = turn.betterVersion
            let before = tasksDone.filter { $0 }.count
            tasksDone = zip(tasksDone, turn.tasksDone + Array(repeating: false, count: max(0, tasksDone.count - turn.tasksDone.count)))
                .map { $0 || $1 }
            hint = turn.hintVi
            messages.append(RoleplayMessage(fromAI: true, text: turn.reply))
            progress.recordRoleplayTurn(newTasksDone: tasksDone.filter { $0 }.count - before)
            SpeechPlayer.shared.speak(turn.reply)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The conversation: task progress on top, chat bubbles with corrections, mic or keyboard at the bottom.
struct RoleplayChatView: View {
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.level) private var level = "beginner"
    @State private var model: RoleplayChatModel
    @State private var draft = ""
    @State private var typing = false

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
                            ChatBubble(message: message).id(message.id)
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
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.bad).padding(.horizontal, 16)
            }
            inputBar
        }
        .screenBackground()
        .inlineNavigationTitle(model.scenario.title)
        .onAppear { SpeechPlayer.shared.speak(model.scenario.opening) }
        .onDisappear { Task { _ = await model.transcriber.stop() } }
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
                Text(model.transcriber.isRunning ? (model.transcriber.text.isEmpty ? "Đang nghe…" : model.transcriber.text)
                                                  : "Chạm micro để nói, chạm lần nữa để gửi")
                    .font(.subheadline)
                    .foregroundStyle(model.transcriber.isRunning ? Theme.ink : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await model.micTapped(level: level, progress: progress) }
                } label: {
                    Image(systemName: model.transcriber.isRunning ? "stop.fill" : "mic.fill")
                        .font(.title2)
                        .frame(width: 60, height: 60)
                        .background(model.transcriber.isRunning ? Theme.badFill : Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(color: Theme.glow.opacity(0.6), radius: 10)
                }
                .disabled(model.sending)
            }
            Button { typing.toggle() } label: {
                Image(systemName: typing ? "mic" : "keyboard").font(.title3).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: message.fromAI ? .leading : .trailing, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if !message.fromAI { Spacer(minLength: 40) }
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.fromAI ? Theme.ink : Theme.background)
                    .padding(12)
                    .background(message.fromAI ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(Theme.primary),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            if !message.corrections.isEmpty || message.betterVersion != nil {
                CorrectionCard(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.fromAI ? .leading : .trailing)
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
