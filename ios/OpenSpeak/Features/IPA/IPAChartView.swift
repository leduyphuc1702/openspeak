import SwiftUI

struct IPAChartView: View {
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var category: Phoneme.Category = .vowel

    @ScaledMetric(relativeTo: .title) private var tileWidth: CGFloat = 78
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: tileWidth), spacing: 12)] }

    private var groups: [(String, [Phoneme])] {
        let items = content.phonemes(in: category)
        var order: [String] = []
        var map: [String: [Phoneme]] = [:]
        for p in items {
            if map[p.group] == nil { order.append(p.group) }
            map[p.group, default: []].append(p)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Nhóm âm", selection: $category) {
                    ForEach(Phoneme.Category.allCases) { SwiftUI.Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                ForEach(groups, id: \.0) { group, items in
                    if category == .consonant {
                        Text(group).font(.subheadline.bold()).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { phoneme in
                            NavigationLink {
                                PhonemeDetailView(phoneme: phoneme)
                            } label: {
                                PhonemeTile(phoneme: phoneme, mastered: progress.isLessonDone(phoneme.id))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("phoneme.\(phoneme.id)")
                        }
                    }
                }
            }
            .padding(20)
        }
        .screenBackground()
        .navigationTitle("Bảng IPA")
    }
}

struct PhonemeTile: View {
    let phoneme: Phoneme
    let mastered: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(phoneme.symbol)
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
            Text(phoneme.examples.first?.word ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(mastered ? Theme.good : .clear, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if mastered {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.good)
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}
