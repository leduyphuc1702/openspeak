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
                    Button("Kiểm tra kết nối") {
                        Task {
                            let ok = await ((try? APIClient(baseURL: backendURL))?.health() ?? false)
                            status = ok ? "Đã kết nối máy chủ chấm điểm." : "Không kết nối được."
                        }
                    }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Máy chủ AI")
                } footer: {
                    Text("Bản cài lên iPhone đã điền sẵn máy chủ lúc build. Muốn dùng máy khác, nhập địa chỉ của nó, ví dụ http://192.168.1.10:8000 nếu cùng mạng Wi‑Fi. Trên Simulator dùng http://localhost:8000. Khoá API của LLM đặt ở backend, không lưu trong app.")
                }

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
