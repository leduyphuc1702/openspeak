import SwiftUI

/// The IPA course as a learning path: units with numbered lessons, one sound per lesson.
struct CoursePathView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @AppStorage(Prefs.name) private var name = ""
    @AppStorage(Prefs.level) private var level = "beginner"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                overview
                reviewBanner
                ForEach(Array(content.units.enumerated()), id: \.element.id) { number, unit in
                    UnitSection(unit: unit, number: number + 1, firstLesson: firstLessonNumber(of: number),
                                unlocked: progress.isUnitUnlocked(unit, in: content.units), current: currentLesson)
                }
                practiceMore
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("Học")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { StatsBar() }
        }
    }

    /// The first unfinished sound in an unlocked unit.
    private var currentLesson: String? {
        for unit in content.units where progress.isUnitUnlocked(unit, in: content.units) {
            if let id = unit.sounds.first(where: { !progress.isLessonDone($0) }) { return id }
        }
        return nil
    }

    private func firstLessonNumber(of unitIndex: Int) -> Int {
        content.units.prefix(unitIndex).reduce(1) { $0 + $1.sounds.count }
    }

    private var overview: some View {
        let done = content.phonemes.filter { progress.isLessonDone($0.id) }.count
        let levelTitle = Prefs.levels.first { $0.id == level }?.title ?? ""
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? "Lộ trình phát âm của bạn" : "Lộ trình phát âm của \(name)")
                    .font(.headline).foregroundStyle(Theme.ink)
                Text("\(content.units.count) Unit · \(levelTitle) · đã học \(done)/\(content.phonemes.count) âm")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressRing(progress: progress.courseProgress(content.phonemes), size: 46)
        }
        .padding(16)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var reviewBanner: some View {
        let due = progress.dueSounds()
        if !due.isEmpty {
            TaskLink {
                SoundReviewView(soundIDs: due)
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "arrow.triangle.2.circlepath", color: Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ôn tập \(due.count) âm").font(.headline).foregroundStyle(Theme.ink)
                        Text("Ôn đúng lúc để nhớ lâu").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    private var practiceMore: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Luyện thêm")
            PracticeLink(title: "Bảng IPA đầy đủ", subtitle: "Tra cứu và nghe mọi âm", icon: "tablecells") { IPAChartView() }
            PracticeLink(title: "Nghe và nhận diện", subtitle: "Nghe âm, chọn ký hiệu", icon: "ear", modal: true) { ListenQuizView() }
            PracticeLink(title: "Đọc phiên âm", subtitle: "Nhìn IPA, đoán từ", icon: "textformat.abc", modal: true) { ReadIPAQuizView() }
            PracticeLink(title: "Cặp âm dễ nhầm", subtitle: "ship hay sheep?", icon: "arrow.left.arrow.right") { MinimalPairsListView() }
        }
    }
}

struct PracticeLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    /// A task opens full screen over the tab bar; a place to browse is pushed.
    var modal = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        Group {
            if modal {
                TaskLink(destination: destination) { row }
            } else {
                NavigationLink(destination: destination) { row }
            }
        }
        .buttonStyle(.plain)
    }

    private var row: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !modal {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .card(padding: 14)
    }
}

private struct UnitSection: View {
    let unit: CourseUnit
    let number: Int
    let firstLesson: Int
    let unlocked: Bool
    let current: String?

    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let sounds = content.phonemes(of: unit)
        VStack(spacing: 4) {
            UnitHeader(index: number, title: unit.title,
                       done: sounds.filter { progress.isLessonDone($0.id) }.count, total: sounds.count)
                .padding(.bottom, 6)
            ForEach(Array(sounds.enumerated()), id: \.element.id) { index, phoneme in
                TaskLink {
                    SoundLessonView(phoneme: phoneme, unit: unit)
                } label: {
                    LessonRow(number: firstLesson + index, title: "Âm /\(phoneme.symbol)/ · \(phoneme.examples.first?.word ?? "")",
                              kind: kind(phoneme), icon: icon(phoneme),
                              done: progress.isLessonDone(phoneme.id), current: phoneme.id == current, locked: !unlocked)
                }
                .buttonStyle(FlatButtonStyle())
                .disabled(!unlocked)
            }
        }
    }

    private func kind(_ p: Phoneme) -> String {
        var text = "\(p.category.title) · 6 bước"
        if let skill = progress.soundSkill(p.id) { text += " · nói \(skill)" }
        return text
    }

    private func icon(_ p: Phoneme) -> String {
        switch p.category {
        case .vowel: return "a.circle"
        case .diphthong: return "arrow.triangle.swap"
        case .consonant: return p.articulation.manner == "nasal" ? "nose" : "mouth"
        }
    }
}

/// Spaced-repetition review: hear a sound, pick the symbol; see a symbol, pick a word that has it.
struct SoundReviewView: View {
    let soundIDs: [String]

    private struct Card {
        let phoneme: Phoneme
        let reverse: Bool          // true: show the symbol, choose a word
        let options: [String]      // symbols, or words
        let answer: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var cards: [Card] = []
    @State private var index = 0
    @State private var chosen: String?
    @State private var correctCount = 0

    var body: some View {
        VStack(spacing: 20) {
            if cards.isEmpty {
                ProgressView()
            } else if let card = cards[safe: index] {
                QuizHeader(index: index, total: cards.count, score: correctCount)
                Spacer()
                prompt(card)
                VStack(spacing: 12) {
                    ForEach(card.options, id: \.self) { option in
                        Button { choose(option, card: card) } label: {
                            Text(card.reverse ? option : "/\(option)/")
                                .font(card.reverse ? .title3.bold() : .system(.largeTitle, design: .serif).bold())
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(color(option, card: card), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(border(option, card: card), lineWidth: 2))
                                .answerMark(chosen == nil ? nil : option == card.answer ? .right : option == chosen ? .wrong : nil)
                        }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(chosen != nil)
                        .accessibilityIdentifier("option.\(card.options.firstIndex(of: option) ?? 0)")
                    }
                }
                Spacer()
                Button("Tiếp") {
                    chosen = nil
                    index += 1
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(chosen == nil)
                .opacity(chosen == nil ? 0.5 : 1)
            } else {
                QuizSummaryView(score: correctCount, total: cards.count, actionTitle: "Xong") { dismiss() }
            }
        }
        .padding(20)
        .scrollingWhenNeeded()
        .screenBackground()
        .inlineNavigationTitle("Ôn tập âm")
        .onAppear { if cards.isEmpty { build() } }
    }

    @ViewBuilder
    private func prompt(_ card: Card) -> some View {
        if card.reverse {
            VStack(spacing: 8) {
                Text("Từ nào có âm này?").font(.headline)
                Text("/\(card.phoneme.symbol)/")
                    .font(.system(size: 72, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.primary)
            }
        } else {
            VStack(spacing: 12) {
                Text("Âm bạn nghe là gì?").font(.headline)
                Button { SpeechPlayer.shared.speak(phoneme: card.phoneme) } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 36))
                        .frame(width: 100, height: 100)
                        .background(Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .onAppear { SpeechPlayer.shared.speak(phoneme: card.phoneme) }
        }
    }

    private func color(_ option: String, card: Card) -> Color {
        guard let chosen else { return Theme.surface }
        if option == card.answer { return Theme.good.opacity(0.25) }
        if option == chosen { return Theme.bad.opacity(0.2) }
        return Theme.surface
    }

    private func border(_ option: String, card: Card) -> Color {
        guard let chosen else { return .clear }
        if option == card.answer { return Theme.good }
        return option == chosen ? Theme.bad : .clear
    }

    private func choose(_ option: String, card: Card) {
        chosen = option
        let correct = option == card.answer
        if correct { correctCount += 1 }
        Haptics.result(success: correct)
        progress.gradeSound(card.phoneme.id, correct: correct)
        if card.reverse { SpeechPlayer.shared.speak(card.answer) }
    }

    private func build() {
        cards = soundIDs.compactMap(content.phoneme).prefix(12).enumerated().compactMap { offset, phoneme in
            let reverse = offset.isMultiple(of: 2)
            if reverse, let word = content.words(containing: phoneme.id).randomElement() {
                let others = content.words(without: phoneme.id).shuffled().prefix(2).map(\.word)
                return Card(phoneme: phoneme, reverse: true, options: ([word.word] + others).shuffled(), answer: word.word)
            }
            let others = content.phonemes(in: phoneme.category).filter { $0 != phoneme }.shuffled().prefix(3).map(\.symbol)
            return Card(phoneme: phoneme, reverse: false, options: ([phoneme.symbol] + others).shuffled(), answer: phoneme.symbol)
        }
    }
}
