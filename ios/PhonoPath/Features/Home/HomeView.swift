import SwiftUI

struct HomeView: View {
    let switchTab: (MainTabView.Tab) -> Void

    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.dailyGoal) private var dailyGoal = 60
    @AppStorage(Prefs.topics) private var topicsRaw = ""
    @AppStorage(Prefs.name) private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                coachCards
                goalCard
                nextLessonCard
                reviewRow
                topicCard
                sentenceCard
                weakSoundsCard
            }
            .padding(20)
        }
        .screenBackground()
        .statusBarFade()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var dayIndex: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    private var statsButton: some View {
        Button { switchTab(.progress) } label: { StatsBar() }
            .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Coach").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    statsButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coach").font(.headline).foregroundStyle(.secondary)
                    statsButton
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Coach của bạn" : "Coach của \(name)")
                    .font(.title.bold())
                    .foregroundStyle(Theme.ink)
                Text("\(greeting)! Hôm nay bạn muốn luyện gì?").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var coachCards: some View {
        VStack(spacing: 12) {
            CoachCard(title: "Phân tích giọng nói", subtitle: "Đọc một câu, AI chấm từng âm, ngữ điệu, nối âm.",
                      icon: "mic.fill", tint: Theme.primary) { SpeakingListView() }
            CoachCard(title: "Huấn luyện phát âm", subtitle: "Học từng âm IPA từ đầu, xem khẩu hình cả từ.",
                      icon: "mouth.fill", tint: Theme.accent) { CoursePathView() }
            CoachCard(title: "Huấn luyện hội thoại", subtitle: "Nhập vai tình huống công sở, AI sửa từng câu.",
                      icon: "bubble.left.and.bubble.right.fill", tint: Theme.good) { RoleplayListView() }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: return "Chào buổi sáng"
        case 11..<18: return "Chào buổi chiều"
        default: return "Chào buổi tối"
        }
    }

    private var goalCard: some View {
        let xp = progress.xpToday()
        let fraction = min(Double(xp) / Double(max(dailyGoal, 1)), 1)
        return VStack(alignment: .leading, spacing: 10) {
            let title = Text("Mục tiêu hôm nay").font(.headline)
            let amount = Text("\(xp)/\(dailyGoal) XP").font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(fraction >= 1 ? Theme.good : Theme.primary)
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer()
                    amount
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    amount
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.subtle)
                    Capsule().fill(fraction >= 1 ? AnyShapeStyle(Theme.good) : AnyShapeStyle(Theme.hero))
                        .frame(width: max(geo.size.width * fraction, 12))
                }
            }
            .frame(height: 12)
            Text(fraction >= 1 ? "Hoàn thành mục tiêu! Chuỗi ngày học được giữ." : "Học thêm một chút để giữ chuỗi ngày học.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    /// First unfinished sound in the first unlocked unit that is not complete.
    private var nextLesson: (phoneme: Phoneme, unit: CourseUnit)? {
        for unit in content.units where progress.isUnitUnlocked(unit, in: content.units) {
            if let phoneme = content.phonemes(of: unit).first(where: { !progress.isLessonDone($0.id) }) {
                return (phoneme, unit)
            }
        }
        return nil
    }

    @ViewBuilder
    private var nextLessonCard: some View {
        if let next = nextLesson {
            TaskLink {
                SoundLessonView(phoneme: next.phoneme, unit: next.unit)
            } label: {
                HStack(spacing: 16) {
                    Text(next.phoneme.symbol)
                        .font(.system(size: 44, weight: .bold, design: .serif))
                        .foregroundStyle(Theme.primary)
                        .frame(width: 84, height: 84)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BÀI HỌC TIẾP THEO").font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
                        Text("Âm /\(next.phoneme.symbol)/").font(.title2.bold()).foregroundStyle(.white)
                        Text(next.unit.title).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white)
                }
                .padding(18)
                .background(Theme.hero, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            Label("Bạn đã học hết các âm! Hãy ôn tập và luyện câu.", systemImage: "trophy.fill")
                .font(.headline)
                .foregroundStyle(Theme.good)
                .card()
        }
    }

    private var reviewRow: some View {
        let sounds = progress.dueSounds()
        let words = progress.dueWords()
        return HStack(spacing: 12) {
            TaskLink {
                SoundReviewView(soundIDs: sounds)
            } label: {
                ReviewTile(count: sounds.count, title: "Âm cần ôn", icon: "character.book.closed.fill")
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(sounds.isEmpty)
            TaskLink {
                WordReviewView(words: words)
            } label: {
                ReviewTile(count: words.count, title: "Từ cần ôn", icon: "square.stack.3d.up.fill")
            }
            .buttonStyle(FlatButtonStyle())
            .disabled(words.isEmpty)
        }
    }

    @ViewBuilder
    private var topicCard: some View {
        let chosen = Prefs.topicIDs(topicsRaw)
        let pool = content.topics.filter { chosen.isEmpty || chosen.contains($0.id) }
        if let topic = pool[safe: dayIndex % max(pool.count, 1)] {
            NavigationLink {
                VocabLessonView(topic: topic)
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemImage: topic.icon, color: Theme.accent, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Từ vựng hôm nay").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(topic.title).font(.headline).foregroundStyle(Theme.ink)
                        Text("AI chọn từ mới theo trình độ của bạn").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var sentenceCard: some View {
        if let sentence = content.sentences[safe: dayIndex % max(content.sentences.count, 1)] {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Nói như người bản xứ").font(.headline)
                    Spacer()
                    NavigationLink("Xem tất cả") { SpeakingListView() }.font(.subheadline)
                }
                TaskLink {
                    SpeakingSessionView(item: PracticeItem(sentence: sentence))
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sentence.text).font(.title3.bold()).foregroundStyle(Theme.ink)
                        Text("/\(sentence.connectedIPA)/")
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(Theme.primary)
                        if let link = sentence.links.first {
                            Label("Nối âm: \(link.display)", systemImage: "link")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.subtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .card()
        }
    }

    @ViewBuilder
    private var weakSoundsCard: some View {
        let weak = content.phonemes
            .compactMap { phoneme in progress.soundSkill(phoneme.id).map { (phoneme: phoneme, score: $0) } }
            .filter { $0.score < 80 }
            .sorted { $0.score < $1.score }
            .prefix(5)
        if !weak.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Âm cần luyện thêm").font(.headline)
                ForEach(Array(weak), id: \.phoneme.id) { entry in
                    NavigationLink {
                        PhonemeDetailView(phoneme: entry.phoneme)
                    } label: {
                        ScoreBar(title: "/\(entry.phoneme.symbol)/  \(entry.phoneme.examples.first?.word ?? "")",
                                 score: entry.score, systemImage: "waveform")
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
        }
    }
}

private struct ReviewTile: View {
    let count: Int
    let title: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(count > 0 ? Theme.accent : .secondary).frame(height: 22)
            Text("\(count)").font(.title.bold().monospacedDigit()).foregroundStyle(count > 0 ? Theme.ink : .secondary)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .card()
    }
}
