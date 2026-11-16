import SwiftUI

/// Welcome, reasons for learning, level, daily goal and topics, one question per page.
struct OnboardingView: View {
    let finish: () -> Void

    @Environment(ContentStore.self) private var content
    @AppStorage(Prefs.level) private var level = "beginner"
    @AppStorage(Prefs.dailyGoal) private var dailyGoal = 60
    @AppStorage(Prefs.topics) private var topicsRaw = ""
    @AppStorage(Prefs.purposes) private var purposesRaw = ""
    @State private var page = 0
    @State private var topics: Set<String> = []
    @State private var purposes: Set<String> = []

    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            if page > 0 {
                HStack(spacing: 12) {
                    Button { withAnimation { page -= 1 } } label: {
                        Image(systemName: "chevron.left").font(.headline)
                    }
                    ProgressView(value: Double(page), total: Double(pageCount - 1))
                        .tint(Theme.primary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Group {
                switch page {
                case 0: welcome
                case 1: purposePage
                case 2: levelPage
                case 3: goalPage
                default: topicPage
                }
            }
            .frame(maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))

            Button(page == pageCount - 1 ? "Bắt đầu học" : "Tiếp tục") { next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.5)
                .padding(20)
        }
        .screenBackground()
    }

    private var canContinue: Bool {
        switch page {
        case 1: return !purposes.isEmpty
        case pageCount - 1: return !topics.isEmpty
        default: return true
        }
    }

    private func next() {
        Haptics.tap()
        if page < pageCount - 1 {
            if page == 1 {
                purposesRaw = Prefs.purposeOptions.map(\.id).filter(purposes.contains).joined(separator: ",")
                if topics.isEmpty {
                    topics = Set(Prefs.purposeOptions.filter { purposes.contains($0.id) }.flatMap(\.topics))
                }
            }
            withAnimation(.easeInOut) { page += 1 }
        } else {
            topicsRaw = content.topics.map(\.id).filter(topics.contains).joined(separator: ",")
            finish()
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Theme.hero).frame(width: 180, height: 180)
                Text("/ə/")
                    .font(.system(size: 72, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
            }
            Text("Nói tiếng Anh tự tin")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.ink)
            Text("Học đọc phiên âm từ từng ký hiệu, luyện khẩu hình miệng, nối âm và ngữ điệu với AI chấm điểm theo âm thanh thật của bạn.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var purposePage: some View {
        QuestionPage(title: "Bạn học tiếng Anh để làm gì?") {
            Text("Chọn bao nhiêu cũng được. Lộ trình từ vựng và hội thoại sẽ theo lựa chọn này.")
                .font(.subheadline).foregroundStyle(.secondary)
            ChipFlow(spacing: 12) {
                ForEach(Prefs.purposeOptions, id: \.id) { option in
                    GlowChip(title: option.title, selected: purposes.contains(option.id)) {
                        Haptics.tap()
                        if purposes.contains(option.id) { purposes.remove(option.id) } else { purposes.insert(option.id) }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var levelPage: some View {
        QuestionPage(title: "Trình độ phát âm của bạn?") {
            ForEach(Prefs.levels, id: \.id) { item in
                ChoiceRow(title: item.title, detail: item.detail, selected: level == item.id) {
                    level = item.id
                }
            }
        }
    }

    private var goalPage: some View {
        QuestionPage(title: "Mục tiêu mỗi ngày") {
            ForEach(Prefs.goals, id: \.xp) { goal in
                ChoiceRow(title: goal.title, detail: "\(goal.detail) · \(goal.xp) XP", selected: dailyGoal == goal.xp) {
                    dailyGoal = goal.xp
                }
            }
        }
    }

    private var topicPage: some View {
        QuestionPage(title: "Bạn muốn học từ vựng chủ đề nào?") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(content.topics) { topic in
                    let selected = topics.contains(topic.id)
                    Button {
                        Haptics.tap()
                        if selected { topics.remove(topic.id) } else { topics.insert(topic.id) }
                    } label: {
                        VStack(spacing: 10) {
                            IconBadge(systemImage: topic.icon, color: selected ? .white : Theme.primary, size: 44)
                            Text(topic.title)
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(selected ? .white : Theme.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 116)
                        .background(selected ? AnyShapeStyle(Theme.hero) : AnyShapeStyle(Theme.surface),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Chọn ít nhất một chủ đề. AI sẽ giao từ mới theo các chủ đề này.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuestionPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title.bold())
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 8)
                content()
            }
            .padding(20)
            .padding(.top, 12)
        }
    }
}

struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Theme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Theme.primary : Theme.subtle)
            }
            .padding(18)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Theme.primary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Wraps chips onto as many lines as needed.
struct ChipFlow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
