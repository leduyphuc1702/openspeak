import SwiftUI

struct ProfileView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(APIClient.storageKey) private var backendURL = APIClient.defaultBaseURL
    @AppStorage(Prefs.name) private var name = ""
    @AppStorage(Prefs.level) private var level = "beginner"
    @AppStorage(Prefs.dailyGoal) private var dailyGoal = 60
    @AppStorage(Prefs.onboarded) private var onboarded = true
    @State private var status: String?
    @State private var accessKey = ServerAccess.key
    @State private var savedAccessKey = ServerAccess.key
    @State private var confirmReset = false

    var body: some View {
        Form {
            Group {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Theme.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Tên của bạn", text: $name).font(.title3.bold())
                            Text(Prefs.levels.first { $0.id == level }?.title ?? "").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Stat(value: "\(progress.streak())", title: "Ngày liên tiếp", icon: "flame.fill", color: Theme.accent)
                        Stat(value: "\(progress.totalXP)", title: "Tổng XP", icon: "star.fill", color: Theme.ok)
                        Stat(value: "\(content.phonemes.filter { progress.isLessonDone($0.id) }.count)", title: "Âm đã học",
                             icon: "character.book.closed.fill", color: Theme.primary)
                        Stat(value: "\(progress.savedWords.count)", title: "Từ đã lưu", icon: "bookmark.fill", color: Theme.good)
                    }
                }

                Section("Học tập") {
                    Picker("Trình độ", selection: $level) {
                        ForEach(Prefs.levels, id: \.id) { SwiftUI.Text($0.title).tag($0.id) }
                    }
                    Picker("Mục tiêu mỗi ngày", selection: $dailyGoal) {
                        ForEach(Prefs.goals, id: \.xp) { SwiftUI.Text("\($0.title) · \($0.xp) XP").tag($0.xp) }
                    }
                    Button("Chọn lại chủ đề và mục tiêu") { onboarded = false }
                }

                Section {
                    TextField("http://192.168.1.10:8000", text: $backendURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .accessibilityIdentifier("server.url")
                    SecureField("Khoá truy cập (nếu máy chủ yêu cầu)", text: $accessKey)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("server.key")
                    HStack {
                        Button("Lưu khoá") { saveAccessKey() }
                            .disabled(accessKey == savedAccessKey)
                            .accessibilityIdentifier("server.save")
                        Spacer()
                        Button("Kiểm tra kết nối") { Task { await checkServer() } }
                            .accessibilityIdentifier("server.check")
                    }
                    .buttonStyle(.borderless)
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("server.status")
                    }
                } header: {
                    Text("Máy chủ AI")
                } footer: {
                    Text("Bản phát hành trên GitHub không kèm máy chủ nào. Chạy backend của bạn rồi nhập địa chỉ tại đây: http://192.168.1.10:8000 nếu cùng mạng Wi‑Fi, http://localhost:8000 trên Simulator. Nếu máy chủ đặt khoá truy cập (OPENSPEAK_API_KEYS), nhập khoá đó; khoá lưu trong Keychain của máy. Backend mở ra Internet cần HTTPS.")
                }

                UserLLMSection()

                Section("Tiến độ") {
                    Button("Xoá tiến độ học", role: .destructive) { confirmReset = true }
                }

                Section("Nguồn mở và giấy phép") {
                    Text("Biểu tượng: SF Symbols (Apple). Sơ đồ khẩu hình: vẽ bằng code từ bảng mô tả cấu âm. Phiên âm: CMU Pronouncing Dictionary. Nghĩa từ: Wiktionary (CC BY‑SA) hoặc LLM bạn cấu hình; nút Cambridge chỉ mở trang gốc. Mô hình âm vị: wav2vec2 XLSR-53 tinh chỉnh trên L2-ARCTIC (mrrubino), hiệu chỉnh trên speechocean762; chỉ dùng phi thương mại. Giọng đọc từ người thật: Wikimedia Commons. Cao độ: Praat qua parselmouth. Âm mẫu: giọng đọc có sẵn của iOS.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.surface.opacity(0.78))
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Hồ sơ & cài đặt")
        .confirmationDialog("Xoá toàn bộ tiến độ?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { progress.reset() }
        }
    }

    private func saveAccessKey() {
        do {
            try ServerAccess.save(accessKey)
            savedAccessKey = ServerAccess.key
            status = accessKey.isEmpty ? "Đã xoá khoá truy cập." : "Đã lưu khoá truy cập."
        } catch {
            status = error.localizedDescription
        }
    }

    private func checkServer() async {
        var client = try? APIClient(baseURL: backendURL)
        client?.session = APIClient.session(accessKey: accessKey)
        let ok = await (client?.health() ?? false)
        status = ok ? "Đã kết nối máy chủ chấm điểm." : "Không kết nối được. Kiểm tra địa chỉ, mạng và khoá truy cập."
    }
}

/// The learner's own LLM account: format, address, model and key. Off means the server's LLM (if any) is used.
private struct UserLLMSection: View {
    @State private var llm = UserLLM.load()
    @State private var saved = UserLLM.load()
    @State private var status: (text: String, ok: Bool)?
    @State private var checking = false

    var body: some View {
        Section {
            Toggle("Dùng LLM riêng", isOn: $llm.enabled)
                .accessibilityIdentifier("llm.enabled")
            if llm.enabled {
                Picker("Định dạng API", selection: $llm.format) {
                    ForEach(UserLLM.Format.allCases) { SwiftUI.Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("llm.format")
                field("Địa chỉ API", llm.format.exampleBaseURL, $llm.baseURL, id: "llm.baseURL", url: true)
                field("Model", llm.format == .anthropic ? "claude-sonnet-4-5" : "gpt-4o-mini", $llm.model, id: "llm.model")
                field("Model đọc ảnh", "tuỳ chọn", $llm.visionModel, id: "llm.visionModel")
                LabeledContent("Khoá API") {
                    SecureField("Khoá API", text: $llm.key, prompt: SwiftUI.Text("sk-…"))
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("llm.key")
                }
            }
            HStack {
                Button("Lưu") { save() }
                    .disabled(llm == saved)
                    .accessibilityIdentifier("llm.save")
                Spacer()
                Button {
                    Task { await check() }
                } label: {
                    if checking { ProgressView() } else { Text("Kiểm tra LLM") }
                }
                .disabled(checking || (llm.enabled && !llm.isComplete))
                .accessibilityIdentifier("llm.check")
            }
            .buttonStyle(.borderless)
            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(status.ok ? Theme.good : Theme.bad)
                    .accessibilityIdentifier("llm.status")
            }
        } header: {
            Text("LLM của bạn")
        } footer: {
            Text("Hỗ trợ 3 định dạng: OpenAI Chat Completions, OpenAI Responses và Anthropic Messages. Khoá API lưu trong Keychain của máy này. Khi bật, mỗi yêu cầu gửi kèm khoá tới máy chủ OpenSpeak; máy chủ chỉ dùng nó cho đúng yêu cầu đó và không lưu lại, nên chỉ bật khi máy chủ là của bạn và dùng HTTPS. Tắt đi thì máy chủ dùng LLM của nó, hoặc soạn bài theo quy tắc nếu không có LLM.")
        }
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>, id: String, url: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: SwiftUI.Text(prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
                #endif
                .accessibilityIdentifier(id)
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try llm.save()
            saved = llm
            status = (llm.enabled ? "Đã lưu. Các bài mới sẽ dùng LLM của bạn." : "Đã lưu. Đang dùng LLM của máy chủ.", true)
            return true
        } catch {
            status = (error.localizedDescription, false)
            return false
        }
    }

    private func check() async {
        guard llm == saved || save() else { return }
        status = nil
        checking = true
        defer { checking = false }
        do {
            let result = try await APIClient.current().checkLLM(llm)
            let whose = result.source == "client" ? "LLM của bạn" : "LLM của máy chủ"
            status = ("\(whose) trả lời sau \(result.ms) ms (\(result.model)): \(result.reply)", true)
        } catch {
            status = (error.localizedDescription, false)
        }
    }
}

private struct Stat: View {
    let value: String
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
