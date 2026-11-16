import Charts
import SwiftUI

/// Skill radar, estimated level, weekly XP and totals.
struct ProgressOverviewView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.dailyGoal) private var dailyGoal = 60

    private var axes: [(title: String, value: Int?)] {
        [("Phát âm", progress.skill("pronunciation")),
         ("Trôi chảy", progress.skill("fluency")),
         ("Ngữ điệu", progress.skill("intonation")),
         ("Nối âm", progress.skill("linking")),
         ("Trọng âm", progress.skill("stress")),
         ("Từ vựng", progress.vocabularySkill)]
    }

    /// A band from one or two takes says more about the sentence than the learner.
    private static let takesForBand = 5

    /// Rough band from practice scores; this is not a CEFR test result.
    private var band: (code: String, title: String)? {
        let values = axes.compactMap(\.value)
        guard values.count >= 2, progress.scoredTakeCount >= Self.takesForBand else { return nil }
        let mean = values.reduce(0, +) / values.count
        switch mean {
        case ..<40: return ("A1", "Mới bắt đầu")
        case ..<55: return ("A2", "Sơ cấp")
        case ..<70: return ("B1", "Trung cấp")
        case ..<82: return ("B2", "Trung cấp cao")
        case ..<92: return ("C1", "Nâng cao")
        default: return ("C2", "Thành thạo")
        }
    }

    private var bandHint: String {
        let left = Self.takesForBand - progress.scoredTakeCount
        return left > 0 ? "Luyện nói thêm \(left) câu để ước lượng trình độ" : "Luyện nói vài câu để có số liệu"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                proficiency
                week
                totals
            }
            .padding(20)
        }
        .actionBar {
            NavigationLink { SpeakingListView() } label: { Text("Luyện nói để cập nhật") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .screenBackground()
        .navigationTitle("Tiến độ")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { ProfileView() } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Hồ sơ và cài đặt")
            }
        }
    }

    private var proficiency: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trình độ của bạn").font(.title3.bold()).foregroundStyle(Theme.ink)
                    Text(band.map { "Ước lượng: \($0.title)" } ?? bandHint)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let band {
                    Text(band.code)
                        .font(.headline.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink.opacity(0.8), lineWidth: 1.5))
                        .foregroundStyle(Theme.ink)
                }
            }
            RadarChart(axes: axes)
                .frame(height: 300)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            Text("Mỗi trục là trung bình 30 lần chấm gần nhất. Mức A1–C2 chỉ là ước lượng từ điểm luyện tập, không phải kết quả thi CEFR.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }

    private struct DayXP: Identifiable {
        let date: Date
        let xp: Int
        var id: Date { date }
    }

    private var lastWeek: [DayXP] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: .now).map { DayXP(date: $0, xp: progress.xpToday(now: $0)) }
        }
    }

    /// The app is Vietnamese-only, so weekdays read T2…CN whatever the device language is.
    static func weekdayVi(_ date: Date) -> String {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return weekday == 1 ? "CN" : "T\(weekday)"
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("7 ngày qua").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text("Mục tiêu \(dailyGoal) XP/ngày").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(lastWeek) { day in
                    BarMark(x: .value("Ngày", day.date, unit: .day), y: .value("XP", day.xp))
                        .foregroundStyle(day.xp >= dailyGoal ? Theme.good : Theme.primary)
                        .cornerRadius(5)
                }
                RuleMark(y: .value("Mục tiêu", dailyGoal))
                    .foregroundStyle(Theme.accent.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(Self.weekdayVi(date)) }
                    }
                }
            }
            .frame(height: 150)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .card(padding: 18)
    }

    private var totals: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            tile("flame.fill", "\(progress.streak())", "ngày liên tiếp", Theme.bad)
            tile("diamond.fill", "\(progress.totalXP)", "tổng XP", Theme.accent)
            tile("character.book.closed.fill", "\(content.phonemes.filter { progress.isLessonDone($0.id) }.count)/\(content.phonemes.count)", "âm đã học", Theme.primary)
            tile("trophy.fill", "\(progress.masteredSoundCount)", "âm thành thạo", Theme.ok)
            tile("bookmark.fill", "\(progress.savedWords.count)", "từ đã lưu", Theme.good)
            tile("bubble.left.and.bubble.right.fill", "\(progress.roleplayTurns)", "lượt hội thoại AI", Theme.glow)
        }
    }

    private func tile(_ icon: String, _ value: String, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).frame(height: 22)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(Theme.ink)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 14)
    }
}
