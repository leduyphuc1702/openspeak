import SwiftUI

struct MinimalPairsListView: View {
    @Environment(ContentStore.self) private var content

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Nghe máy đọc một trong hai từ và chọn từ bạn nghe được. Đây là cách nhanh nhất để tai phân biệt được những âm mà tiếng Việt không có.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(content.minimalPairs) { pair in
                    TaskLink {
                        PairDrillView(pair: pair)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(pair.a.word)  ·  \(pair.b.word)").font(.headline).foregroundStyle(Theme.ink)
                                Text("/\(pair.a.ipa)/  ·  /\(pair.b.ipa)/").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(contrastLabel(pair))
                                .font(.system(.subheadline, design: .serif).bold())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.primary.opacity(0.12), in: Capsule())
                                .foregroundStyle(Theme.primary)
                        }
                        .card(padding: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .screenBackground()
        .inlineNavigationTitle("Cặp âm dễ nhầm")
    }

    private func contrastLabel(_ pair: MinimalPair) -> String {
        let symbols = pair.contrast.compactMap { content.phoneme($0)?.symbol }
        return symbols.count == 2 ? "/\(symbols[0])/ – /\(symbols[1])/" : "/\(symbols.first ?? "")/ cuối"
    }
}

struct PairDrillView: View {
    let pair: MinimalPair

    @State private var round = 0
    @State private var score = 0
    @State private var target = 0
    @State private var state: AnswerState = .unanswered

    private let rounds = 8
    private var words: [WordEntry] { [pair.a, pair.b] }

    var body: some View {
        Group {
            if round >= rounds {
                QuizSummaryView(score: score, total: rounds, restart: restart)
            } else {
                drill
                    .scrollingWhenNeeded()
                    .actionBar { actions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .inlineNavigationTitle("\(pair.a.word) · \(pair.b.word)")
        .onAppear { if round == 0 && !state.isAnswered { next() } }
    }

    private var drill: some View {
        VStack(spacing: 22) {
            QuizHeader(index: round, total: rounds, score: score)
            Spacer()
            Button {
                SpeechPlayer.shared.speak(words[target].word)
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 110)
                    .background(Theme.hero, in: Circle())
            }
            .buttonStyle(.plain)
            Text("Bạn nghe thấy từ nào?").font(.title3.bold())
            if let note = pair.note {
                Label(note, systemImage: "lightbulb.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .opacity(state.isAnswered ? 1 : 0)
                    .accessibilityHidden(!state.isAnswered)
            }
            Spacer()
            HStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { i in
                    OptionButton(index: i, state: state, action: { answer(i) }) {
                        VStack(spacing: 4) {
                            Text(words[i].word).font(.title2.bold()).foregroundStyle(Theme.ink)
                            // Shown only after answering: before, the learner should listen rather than read.
                            Text("/\(words[i].ipa)/").font(.subheadline).foregroundStyle(.secondary)
                                .opacity(state.isAnswered ? 1 : 0)
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .padding(20)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Nghe cả hai") { playBoth() }.buttonStyle(SecondaryButtonStyle())
            Button("Tiếp tục") {
                round += 1
                if round < rounds { next() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .disabled(!state.isAnswered)
        .opacity(state.isAnswered ? 1 : 0.5)
    }

    private func next() {
        state = .unanswered
        target = Int.random(in: 0...1)
        let word = words[target].word
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            SpeechPlayer.shared.speak(word)
        }
    }

    private func answer(_ i: Int) {
        state = .answered(choice: i, correct: target)
        if i == target { score += 1 }
        Haptics.result(success: i == target)
    }

    private func playBoth() {
        let a = pair.a.word, b = pair.b.word
        Task {
            SpeechPlayer.shared.speak(a, slow: true)
            try? await Task.sleep(for: .milliseconds(1300))
            SpeechPlayer.shared.speak(b, slow: true)
        }
    }

    private func restart() {
        round = 0
        score = 0
        next()
    }
}
