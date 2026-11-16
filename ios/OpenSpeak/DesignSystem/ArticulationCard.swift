import SwiftUI

/// One instruction of a sound's guide, tied to the part of the mouth it is about.
struct ArticulationStep: Equatable, Identifiable {
    let id: Int
    let part: MouthPart?
    let glides: Bool
    let title: String
    let text: String

    /// Content steps read "Môi: …", "Hàm: …", "Lưỡi: …", "Hơi: …", "Thanh quản: …" or "Trượt: …".
    static func parse(_ steps: [String]) -> [ArticulationStep] {
        steps.enumerated().map { index, raw in
            let pieces = raw.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else {
                return ArticulationStep(id: index, part: nil, glides: false, title: "Lưu ý", text: raw)
            }
            let body = pieces[1].prefix(1).uppercased() + pieces[1].dropFirst()
            switch pieces[0] {
            case "Môi": return ArticulationStep(id: index, part: .lips, glides: false, title: "Môi", text: body)
            case "Hàm": return ArticulationStep(id: index, part: .jaw, glides: false, title: "Hàm", text: body)
            case "Lưỡi": return ArticulationStep(id: index, part: .tongue, glides: false, title: "Lưỡi", text: body)
            case "Hơi": return ArticulationStep(id: index, part: .air, glides: false, title: "Luồng hơi", text: body)
            case "Thanh quản": return ArticulationStep(id: index, part: .voice, glides: false, title: "Dây thanh", text: body)
            case "Trượt": return ArticulationStep(id: index, part: nil, glides: true, title: "Trượt sang âm sau", text: body)
            default: return ArticulationStep(id: index, part: nil, glides: false, title: pieces[0], text: body)
            }
        }
    }

    /// What the diagram shows once the learner has got as far as step `index`.
    static func diagramStep(_ steps: [ArticulationStep], at index: Int) -> MouthGuideStep {
        let shape: Set<MouthPart> = [.lips, .jaw, .tongue]
        // A part of the mouth shape that no step mentions moves with the first step.
        var applied = shape.subtracting(steps.compactMap(\.part))
        let reached = steps.prefix(index + 1)
        applied.formUnion(reached.compactMap(\.part))
        return MouthGuideStep(applied: applied, focus: steps[index].part, glides: reached.contains(where: \.glides))
    }
}

/// Diagram and instructions for one sound. The overview shows the finished mouth position; the
/// step-by-step mode builds it up from a relaxed mouth, one part at a time.
struct ArticulationCard: View {
    let phoneme: Phoneme
    @State private var stepIndex: Int?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [ArticulationStep] { ArticulationStep.parse(phoneme.steps) }
    private var cardID: String { "articulation-\(phoneme.id)" }

    var body: some View {
        ScrollViewReader { proxy in
            card
                .id(cardID)
                .onChange(of: stepIndex) { _, new in
                    // At accessibility text sizes the step text alone fills the screen; bring the diagram back into view.
                    guard new != nil, typeSize.isAccessibilitySize else { return }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeInOut) { proxy.scrollTo(cardID, anchor: .top) }
                    }
                }
        }
    }

    private var card: some View {
        let steps = steps
        let index = stepIndex.flatMap { steps.indices.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("/\(phoneme.symbol)/")
                    .font(.system(.largeTitle, design: .serif).bold())
                    .foregroundStyle(Theme.primary)
                    .accessibilityLabel("Âm \(phoneme.symbol)")
                Spacer()
                Button { SpeechPlayer.shared.speak(phoneme: phoneme) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Nghe âm mẫu")
            }
            MouthDiagramView(articulation: phoneme.articulation, annotated: index == nil,
                             step: index.map { ArticulationStep.diagramStep(steps, at: $0) })
                .accessibilityElement()
                .accessibilityLabel("Hình cắt dọc khoang miệng và hình môi nhìn từ trước")
                .accessibilityValue(index.map { steps[$0].text } ?? phoneme.tip)
            MouthLegend(articulation: phoneme.articulation)
            if let index {
                stepPanel(steps, index)
            } else {
                overview(steps)
            }
        }
        .card()
        .onChange(of: phoneme.id) { stepIndex = nil }
    }

    @ViewBuilder
    private func overview(_ steps: [ArticulationStep]) -> some View {
        if !steps.isEmpty {
            Button { stepIndex = 0 } label: {
                Label("Tập từng bước", systemImage: "list.number")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("mouth.steps.start")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(step.id + 1)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(3)
                            .frame(minWidth: 24, minHeight: 24)
                            .background(Theme.primaryDeep, in: Circle())
                        Text(SwiftUI.Text(step.title + ". ").bold() + SwiftUI.Text(step.text))
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        Text(phoneme.tip)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func stepPanel(_ steps: [ArticulationStep], _ index: Int) -> some View {
        let step = steps[index]
        let isLast = index == steps.count - 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(steps) { other in
                    Capsule()
                        .fill(other.id <= index ? Theme.primary : Theme.subtle)
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bước \(index + 1)/\(steps.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(step.title)
                    .font(.title3.bold())
                    .foregroundStyle(Theme.ink)
                Text(step.text)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if typeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        previousButton(index, compact: true).frame(width: 76)
                        nextButton(index, isLast: isLast)
                    }
                    VStack(spacing: 10) {
                        previousButton(index, compact: false)
                        nextButton(index, isLast: isLast)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    previousButton(index, compact: false)
                    nextButton(index, isLast: isLast)
                }
            }
        }
    }

    private func previousButton(_ index: Int, compact: Bool) -> some View {
        let title = index == 0 ? "Tổng quan" : "Bước trước"
        return Button { stepIndex = index == 0 ? nil : index - 1 } label: {
            if compact {
                Image(systemName: "chevron.left").accessibilityLabel(title)
            } else {
                Label(title, systemImage: "chevron.left")
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityIdentifier("mouth.steps.previous")
    }

    private func nextButton(_ index: Int, isLast: Bool) -> some View {
        Button { stepIndex = isLast ? nil : index + 1 } label: {
            Label(isLast ? "Xem toàn bộ" : "Bước sau", systemImage: isLast ? "checkmark" : "chevron.right")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("mouth.steps.next")
    }
}

/// What the colours on the diagram mean. Only the marks this sound actually shows are listed.
private struct MouthLegend: View {
    let articulation: Articulation

    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 6) {
            item(MouthDiagramColors.air, articulation.nasal ? "Hơi ra mũi" : "Luồng hơi")
            if hasContact { item(MouthDiagramColors.contact, "Điểm chạm") }
            item(articulation.voiced ? MouthDiagramColors.voice : MouthDiagramColors.voiceless,
                 articulation.voiced ? "Dây thanh rung" : "Dây thanh không rung")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
    }

    private var hasContact: Bool {
        let pose = articulation.start
        return pose.contact || pose.backContact || pose.lips == "closed" || pose.lips == "labiodental"
    }

    private func item(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
