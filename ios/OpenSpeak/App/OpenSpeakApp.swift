import SwiftUI

@main
struct OpenSpeakApp: App {
    @State private var content: ContentStore
    @State private var progress: ProgressStore

    init() {
        let content = ContentStore()
        let store = ProgressStore()
        _content = State(initialValue: content)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        // UI tests start from a fresh install state; launch arguments would pin the value instead.
        if environment["OPENSPEAK_RESET_PREFS"] != nil {
            for key in [Prefs.onboarded, Prefs.level, Prefs.dailyGoal, Prefs.topics, Prefs.purposes, Prefs.learnSegment] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if environment["OPENSPEAK_RESET_SEGMENT"] != nil {
            UserDefaults.standard.removeObject(forKey: Prefs.learnSegment)
        }
        if environment["OPENSPEAK_RESET_LLM"] != nil {
            UserLLM.reset()
        }
        if let seed = environment["OPENSPEAK_SEED_PATH"] {
            store.seedForUITests(finishedSounds: seed == "graduated" ? content.phonemes.map(\.id) : [])
            if seed == "exam" { store.seedFinishedLessons(["R", "IH", "TH", "L"]) { content.phoneme($0)?.symbol ?? $0 } }
        }
        #endif
        _progress = State(initialValue: store)
        AudioSessionConfigurator.configure()
        #if os(iOS)
        UITextField.appearance().clearButtonMode = .whileEditing
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(content)
                .environment(progress)
                .tint(Theme.primary)
                .preferredColorScheme(.dark)
        }
    }
}

/// Learner choices made during onboarding, editable later in Profile.
enum Prefs {
    static let onboarded = "prefs.onboarded"
    static let level = "prefs.level"
    static let dailyGoal = "prefs.dailyGoal"
    static let topics = "prefs.topics"          // comma-separated topic ids
    static let name = "prefs.name"
    static let purposes = "prefs.purposes"      // comma-separated purpose ids
    static let learnSegment = "prefs.learnSegment"

    /// Why the learner studies English, and the vocabulary topics each reason suggests.
    static let purposeOptions: [(id: String, title: String, topics: [String])] = [
        ("work", "Giao tiếp công việc", ["work", "meetings", "email", "smalltalk", "project"]),
        ("meetings", "Họp, thuyết trình", ["meetings", "presentation", "opinions"]),
        ("interview", "Phỏng vấn xin việc", ["interview", "feelings", "opinions"]),
        ("clients", "Làm việc với khách nước ngoài", ["customer", "calls", "negotiation", "email"]),
        ("travel", "Du lịch", ["travel", "food", "transport", "emergency"]),
        ("daily", "Đời sống hằng ngày", ["daily", "shopping", "housing", "health", "finance"]),
        ("exam", "IELTS / TOEIC", ["education", "opinions", "technology"]),
        ("social", "Kết bạn, xem phim", ["social", "feelings", "smalltalk"]),
    ]

    static let levels: [(id: String, title: String, detail: String)] = [
        ("beginner", "Mới bắt đầu", "Chưa đọc được phiên âm"),
        ("elementary", "Sơ cấp", "Biết vài âm, nói còn ngập ngừng"),
        ("intermediate", "Trung cấp", "Giao tiếp được, muốn nói tự nhiên hơn"),
        ("advanced", "Nâng cao", "Muốn nói giống người bản xứ"),
    ]

    static let goals: [(xp: Int, title: String, detail: String)] = [
        (30, "Nhẹ nhàng", "5 phút mỗi ngày"),
        (60, "Đều đặn", "10 phút mỗi ngày"),
        (100, "Nghiêm túc", "15 phút mỗi ngày"),
        (150, "Tăng tốc", "20+ phút mỗi ngày"),
    ]

    static func topicIDs(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }
}

struct RootView: View {
    @AppStorage(Prefs.onboarded) private var onboarded = false

    var body: some View {
        if onboarded {
            MainTabView()
        } else {
            OnboardingView { onboarded = true }
        }
    }
}

/// Coach · Học · Hội thoại · Khám phá · Tiến độ.
struct MainTabView: View {
    enum Tab: Hashable { case coach, learn, chats, discover, progress }

    @State private var tab: Tab = .coach

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView(switchTab: { tab = $0 }) }
                .tabItem { SwiftUI.Label("Coach", systemImage: "face.smiling.inverse") }
                .tag(Tab.coach)
            NavigationStack { CoursePathView() }
                .tabItem { SwiftUI.Label("Học", systemImage: "book.closed.fill") }
                .tag(Tab.learn)
            NavigationStack { RoleplayListView() }
                .tabItem { SwiftUI.Label("Hội thoại", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.chats)
            NavigationStack { VocabularyHomeView() }
                .tabItem { SwiftUI.Label("Khám phá", systemImage: "safari.fill") }
                .tag(Tab.discover)
            NavigationStack { ProgressOverviewView() }
                .tabItem { SwiftUI.Label("Tiến độ", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(Tab.progress)
        }
    }
}
