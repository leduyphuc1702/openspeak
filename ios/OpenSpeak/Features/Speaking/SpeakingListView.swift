import SwiftUI

struct SpeakingListView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var customText = ""

    private var levels: [Int] { Array(Set(content.sentences.map(\.level))).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tự nhập câu muốn luyện").font(.headline)
                    TextField("Ví dụ: I would like a cup of coffee.", text: $customText, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(12)
                        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    TaskLink {
                        SpeakingSessionView(item: PracticeItem(text: customText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } label: {
                        Label("Luyện câu này", systemImage: "mic.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }
                .card()

                ForEach(levels, id: \.self) { level in
                    let items = content.sentences.filter { $0.level == level }
                    SectionTitle(text: items.first?.levelTitle ?? "")
                    VStack(spacing: 10) {
                        ForEach(items) { sentence in
                            TaskLink {
                                SpeakingSessionView(item: PracticeItem(sentence: sentence))
                            } label: {
                                SentenceRow(sentence: sentence, best: progress.bestScore(sentence.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("Nói như người bản xứ")
    }
}

private struct SentenceRow: View {
    let sentence: PracticeSentence
    let best: Int?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sentence.text).font(.headline).foregroundStyle(Theme.ink)
                Text("/\(sentence.connectedIPA)/").font(.system(.footnote, design: .serif)).foregroundStyle(.secondary).lineLimit(1)
                Label(sentence.intonation == "rising" ? "Lên giọng cuối câu" : "Xuống giọng cuối câu",
                      systemImage: sentence.intonation == "rising" ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(Theme.primary)
            }
            Spacer(minLength: 0)
            if let best {
                ScoreRing(score: best, size: 44, lineWidth: 5)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .card(padding: 14)
    }
}
