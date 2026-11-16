import Charts
import SwiftUI

/// The tabs of a result. They sit above the scrolling result so they are always within reach.
struct ResultTabBar: View {
    let assessment: Assessment
    @Binding var tab: AssessmentResultView.ResultTab

    private var tabs: [AssessmentResultView.ResultTab] {
        AssessmentResultView.ResultTab.allCases.filter { $0 != .linking || !assessment.linking.links.isEmpty }
    }

    var body: some View {
        SegmentBar(titles: tabs.map(\.rawValue),
                   selection: Binding(get: { tab.rawValue },
                                      set: { tab = AssessmentResultView.ResultTab(rawValue: $0) ?? .overview }))
    }
}

/// Result of one take, split into tabs: overview, sounds, fluency, intonation, linking.
struct AssessmentResultView: View {
    let assessment: Assessment
    let playMine: () -> Void
    @Binding var tab: ResultTab
    @Environment(ContentStore.self) private var content
    @State private var selectedWord: Assessment.Word?

    enum ResultTab: String, CaseIterable, Identifiable {
        case overview = "Tổng quan", pronunciation = "Phát âm", fluency = "Trôi chảy",
             intonation = "Ngữ điệu", linking = "Nối âm"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 16) {
            switch tab {
            case .overview:
                scoreCard
                wordsCard
                feedbackCard
            case .pronunciation:
                wordsCard
                PhoneSummaryCard(words: assessment.words) { selectedWord = $0 }
            case .fluency:
                FluencyCard(assessment: assessment)
            case .intonation:
                IntonationCard(assessment: assessment)
            case .linking:
                LinkingResultCard(linking: assessment.linking)
            }
        }
        .sheet(item: $selectedWord) { word in
            WordDetailSheet(word: word)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var scoreCard: some View {
        HStack(spacing: 18) {
            ScoreRing(score: assessment.scores.overall, size: 104)
            VStack(spacing: 10) {
                tabBar("Phát âm", assessment.scores.pronunciation, "waveform", .pronunciation)
                tabBar("Ngữ điệu", assessment.scores.intonation, "music.note", .intonation)
                ScoreBar(title: "Trọng âm", score: assessment.scores.stress, systemImage: "textformat.size")
                tabBar("Trôi chảy", assessment.scores.fluency, "wind", .fluency)
                if assessment.scores.linking != nil {
                    tabBar("Nối âm", assessment.scores.linking, "link", .linking)
                }
            }
        }
        .card()
    }

    private func tabBar(_ title: String, _ score: Int?, _ icon: String, _ target: ResultTab) -> some View {
        Button { tab = target } label: { ScoreBar(title: title, score: score, systemImage: icon) }
            .buttonStyle(.plain)
    }

    private var wordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Từng từ").font(.headline)
                Spacer()
                Button(action: playMine) {
                    Label("Nghe lại giọng tôi", systemImage: "play.circle.fill").font(.subheadline)
                }
            }
            FlowLayout(spacing: 10, lineSpacing: 12) {
                ForEach(assessment.words) { word in
                    Button { selectedWord = word } label: { WordChip(word: word) }
                        .buttonStyle(.plain)
                }
            }
            Button(action: compare) {
                Label("So sánh cách nói: tôi rồi giọng mẫu", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            GradeLegend()
            Text("Chạm vào một từ để xem chi tiết từng âm.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    @ViewBuilder
    private var feedbackCard: some View {
        if let feedback = assessment.feedback, !feedback.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Nhận xét của AI", systemImage: "sparkles").font(.headline)
                Text(feedback).foregroundStyle(Theme.ink)
            }
            .card()
        } else if let tip = localTip {
            VStack(alignment: .leading, spacing: 8) {
                Label("Gợi ý", systemImage: "lightbulb.fill").font(.headline)
                Text(tip).foregroundStyle(Theme.ink)
            }
            .card()
        }
    }

    /// Plays the learner's take, then the model voice once the take has finished.
    private func compare() {
        playMine()
        let length = (assessment.words.last?.end ?? 2) + 0.6
        let text = assessment.text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(length))
            SpeechPlayer.shared.speak(text)
        }
    }

    /// Without an LLM configured, fall back to the lesson tip for the weakest sound.
    private var localTip: String? {
        let worst = assessment.words.compactMap(\.worstPhone).min { ($0.score ?? 0) < ($1.score ?? 0) }
        guard let worst, let phoneme = content.phoneme(worst.id) else { return nil }
        return "Âm cần luyện nhất: /\(phoneme.symbol)/. \(phoneme.tip)"
    }
}

/// Three grades per sound: right, nearly right, wrong (substituted or dropped).
enum PhoneGrade: CaseIterable {
    case correct, almost, wrong

    init(_ status: Assessment.Phone.Status) {
        switch status {
        case .good: self = .correct
        case .weak: self = .almost
        case .substituted, .missing: self = .wrong
        }
    }

    var title: String {
        switch self {
        case .correct: return "Đúng"
        case .almost: return "Gần đúng"
        case .wrong: return "Sai"
        }
    }

    var color: Color {
        switch self {
        case .correct: return Theme.good
        case .almost: return Theme.ok
        case .wrong: return Theme.bad
        }
    }
}

private struct GradeLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(PhoneGrade.allCases, id: \.self) { grade in
                HStack(spacing: 5) {
                    Circle().fill(grade.color).frame(width: 8, height: 8)
                    Text(grade.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Every sound that was not right, worst first, with what it sounded like.
private struct PhoneSummaryCard: View {
    let words: [Assessment.Word]
    let open: (Assessment.Word) -> Void

    private var problems: [(word: Assessment.Word, phone: Assessment.Phone)] {
        words.flatMap { word in word.phones.map { (word: word, phone: $0) } }
            .filter { PhoneGrade($0.phone.status) != .correct }
            .sorted { ($0.phone.score ?? 0) < ($1.phone.score ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let counts = Dictionary(grouping: words.flatMap(\.phones), by: { PhoneGrade($0.status) }).mapValues(\.count)
            HStack(spacing: 10) {
                ForEach(PhoneGrade.allCases, id: \.self) { grade in
                    VStack(spacing: 2) {
                        Text("\(counts[grade] ?? 0)").font(.title2.bold().monospacedDigit()).foregroundStyle(grade.color)
                        Text(grade.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(grade.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if problems.isEmpty {
                Label("Tất cả các âm đều đúng.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
            }
            ForEach(Array(problems.prefix(8).enumerated()), id: \.offset) { _, item in
                Button { open(item.word) } label: {
                    HStack(spacing: 12) {
                        Text("/\(item.phone.expected)/")
                            .font(.system(.title2, design: .serif).weight(.semibold))
                            .foregroundStyle(PhoneGrade(item.phone.status).color)
                            .frame(width: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.word.word).font(.headline).foregroundStyle(Theme.ink)
                            Text(detail(item.phone)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.phone.score.map(String.init) ?? "–").font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(PhoneGrade(item.phone.status).color)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private func detail(_ phone: Assessment.Phone) -> String {
        switch phone.status {
        case .missing: return "Bị bỏ mất"
        case .substituted: return "Nghe như /\(phone.heard ?? "?")/"
        default: return "Gần đúng, chưa rõ"
        }
    }
}

/// Speaking pace on a slow–natural–fast scale, plus where the long pauses fell.
private struct FluencyCard: View {
    let assessment: Assessment

    /// Natural read-aloud pace for this scale, in syllables per second (matches the backend's full-score band).
    private static let natural = 2.5...5.5
    private static let scale = 1.0...7.5

    private var rate: Double { assessment.fluency.syllablesPerSecond }

    private var band: (title: String, color: Color, advice: String) {
        if rate < Self.natural.lowerBound {
            return ("Chậm", Theme.ok, "Hơi chậm. Đọc liền các cụm từ, đừng dừng sau từng từ.")
        }
        if rate > Self.natural.upperBound {
            return ("Nhanh", Theme.ok, "Hơi nhanh. Chậm lại ở từ quan trọng để người nghe theo kịp.")
        }
        return ("Tự nhiên", Theme.good, "Tốc độ tự nhiên.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tốc độ nói", systemImage: "speedometer").font(.headline)
                Spacer()
                ScoreRing(score: assessment.scores.fluency, size: 48, lineWidth: 5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", rate)).font(.largeTitle.bold().monospacedDigit()).foregroundStyle(Theme.ink)
                Text("âm tiết/giây").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(band.title).font(.headline).foregroundStyle(band.color)
            }
            PaceGauge(value: rate, scale: Self.scale, natural: Self.natural)
            Text(band.advice).font(.subheadline).foregroundStyle(Theme.ink)
            Divider()
            Label("Chỗ ngắt", systemImage: "pause.circle").font(.headline)
            PausedTranscript(words: assessment.words, pauses: assessment.fluency.pauses)
            Text(assessment.fluency.pauses.isEmpty
                 ? "Không có chỗ ngắt dài. Tốt!"
                 : "Có \(assessment.fluency.pauses.count) chỗ ngắt dài (dấu ⏸). Trong một câu ngắn nên đọc liền một hơi.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

private struct PaceGauge: View {
    let value: Double
    let scale: ClosedRange<Double>
    let natural: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (v: Double) in CGFloat((min(max(v, scale.lowerBound), scale.upperBound) - scale.lowerBound)
                                             / (scale.upperBound - scale.lowerBound)) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ok.opacity(0.35)).frame(height: 10)
                Capsule().fill(Theme.good).frame(width: x(natural.upperBound) - x(natural.lowerBound), height: 10)
                    .offset(x: x(natural.lowerBound))
                Circle().fill(.white).frame(width: 20, height: 20)
                    .shadow(color: Theme.glow.opacity(0.8), radius: 6)
                    .offset(x: x(value) - 10)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 22)
        .overlay(alignment: .bottom) {
            HStack {
                Text("Chậm"); Spacer(); Text("Tự nhiên"); Spacer(); Text("Nhanh")
            }
            .font(.caption2).foregroundStyle(.secondary).offset(y: 18)
        }
        .padding(.bottom, 16)
        .accessibilityElement()
        .accessibilityLabel("Tốc độ \(String(format: "%.1f", value)) âm tiết mỗi giây")
    }
}

/// The sentence with a pause mark wherever the learner stopped for long between two words.
private struct PausedTranscript: View {
    let words: [Assessment.Word]
    let pauses: [Assessment.Pause]

    private var text: AttributedString {
        var out = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word.word)
            piece.foregroundColor = Theme.ink
            out += piece
            guard index < words.count - 1 else { break }
            let next = words[index + 1]
            let paused = pauses.contains { $0.start < next.start && $0.end > word.end - 0.05 }
            if paused {
                var mark = AttributedString("  ⏸  ")
                mark.foregroundColor = Theme.bad
                out += mark
            } else {
                out += AttributedString(" ")
            }
        }
        return out
    }

    var body: some View {
        Text(text).font(.title3).fixedSize(horizontal: false, vertical: true)
    }
}

private struct WordChip: View {
    let word: Assessment.Word

    var body: some View {
        VStack(spacing: 2) {
            Text(word.word)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.scoreColor(word.score))
                .underline((word.score ?? 100) < 55, pattern: .dot)
            Text(phoneLine)
                .font(.system(.caption, design: .serif))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.scoreColor(word.score).opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var phoneLine: AttributedString {
        var line = AttributedString()
        for phone in word.phones {
            var piece = AttributedString(phone.expected)
            piece.foregroundColor = Theme.scoreColor(phone.score)
            if phone.status == .missing { piece.strikethroughStyle = .single }
            line += piece
        }
        return line
    }
}

struct WordDetailSheet: View {
    let word: Assessment.Word
    @Environment(ContentStore.self) private var content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(word.word).font(.largeTitle.bold())
                        Text("/\(word.ipa)/").font(.system(.title3, design: .serif)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScoreRing(score: word.score, size: 64, lineWidth: 7)
                }
                Button {
                    SpeechPlayer.shared.speak(word.word, slow: true)
                } label: {
                    Label("Nghe phát âm chuẩn", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(SecondaryButtonStyle())

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                    ForEach(Array(word.phones.enumerated()), id: \.offset) { _, phone in
                        PhoneCell(phone: phone)
                    }
                }

                if let stress = word.stress {
                    Label(stress.correct
                          ? "Trọng âm đúng ở âm tiết \(stress.expected + 1)."
                          : "Cần nhấn âm tiết \(stress.expected + 1), bạn đang nhấn âm tiết \(stress.detected + 1).",
                          systemImage: stress.correct ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(stress.correct ? Theme.good : Theme.ok)
                }

                if let worst = word.worstPhone, let phoneme = content.phoneme(worst.id) {
                    Text("Cách sửa /\(phoneme.symbol)/").font(.headline)
                    ArticulationCard(phoneme: phoneme)
                }
            }
            .padding(20)
        }
        .screenBackground()
    }
}

private struct PhoneCell: View {
    let phone: Assessment.Phone

    private var caption: String {
        switch phone.status {
        case .good: return "Đúng"
        case .weak: return "Gần đúng"
        case .missing: return "Bị bỏ"
        case .substituted: return "Nghe như /\(phone.heard ?? "?")/"
        }
    }

    var body: some View {
        let color = PhoneGrade(phone.status).color
        VStack(spacing: 4) {
            Text("/\(phone.expected)/").font(.system(.title2, design: .serif).weight(.semibold))
            Text(caption).font(.caption2).multilineTextAlignment(.center)
            Text(phone.score.map(String.init) ?? "–").font(.caption.bold().monospacedDigit())
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Which word boundaries the learner joined smoothly and which they broke apart.
private struct LinkingResultCard: View {
    let linking: Assessment.Linking

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nối âm", systemImage: "link").font(.headline)
            Text("/\(linking.connectedIpa)/")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(Theme.primary)
            ForEach(linking.links, id: \.index) { link in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: link.linked ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(link.linked ? Theme.good : Theme.bad)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.display)
                            .font(.system(.body, design: .serif).weight(.semibold))
                        Text(link.linked ? "Nối tốt." : message(for: link))
                            .font(.subheadline)
                            .foregroundStyle(link.linked ? .secondary : Theme.ink)
                        if !link.linked {
                            Text(link.hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .card()
    }

    private func message(for link: Assessment.Link) -> String {
        switch link.problem {
        case "glottal_stop": return "Bạn chặn hơi giữa hai từ (ngắt cứng), nên đọc liền."
        case "pause": return "Có khoảng ngắt \(Int(link.gap * 1000)) ms giữa hai từ."
        default: return "Hai từ còn tách rời."
        }
    }
}

private struct IntonationCard: View {
    let assessment: Assessment

    private struct Point: Identifiable {
        let id = UUID()
        let time: Double
        let semitone: Double
        let series: String
    }

    private var points: [Point] {
        let user = assessment.pitchContour.user.compactMap { p in
            p.count == 2 ? Point(time: p[0], semitone: p[1], series: "Bạn") : nil
        }
        let reference = (assessment.pitchContour.reference ?? []).compactMap { p in
            p.count == 2 ? Point(time: p[0], semitone: p[1], series: "Giọng mẫu") : nil
        }
        return reference + user
    }

    private var summary: String {
        let i = assessment.intonation
        let want = i.expected == "rising" ? "lên giọng" : "xuống giọng"
        let got: String
        switch i.detected {
        case "rising": got = "lên giọng"
        case "falling": got = "xuống giọng"
        case "flat": got = "giữ giọng đều"
        default: got = "chưa đo được"
        }
        var text = "Câu này cần \(want) ở cuối; bạn \(got)."
        if let range = i.pitchRange, range < 3 {
            text += " Giọng hơi đều đều, hãy thay đổi cao độ nhiều hơn ở từ quan trọng."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ngữ điệu", systemImage: "music.note").font(.headline)
            if points.isEmpty {
                Text("Không đo được cao độ, hãy nói to và rõ hơn.").foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Thời gian (s)", point.time),
                        y: .value("Cao độ (nửa cung)", point.semitone),
                        series: .value("Nguồn", point.series)
                    )
                    .foregroundStyle(by: .value("Nguồn", point.series))
                    .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale(["Bạn": Theme.primary, "Giọng mẫu": Color.gray.opacity(0.5)])
                .frame(height: 150)
            }
            Text(summary).font(.subheadline).foregroundStyle(Theme.ink)
            if let similarity = assessment.intonation.referenceSimilarity {
                Text("Giống giọng mẫu: \(similarity)%").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}
