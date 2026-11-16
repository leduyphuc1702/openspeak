import SwiftUI

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.fill(color), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Like `.plain`, except that a disabled button is not dimmed: its label already shows the state.
struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct ScoreRing: View {
    let score: Int?
    var size: CGFloat = 96
    var lineWidth: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.subtle, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(Theme.scoreColor(score), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: score)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                if size >= 80 {
                    Text("điểm").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct ScoreBar: View {
    let title: String
    let score: Int?
    var systemImage: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                SwiftUI.Label(title, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 10) {
                    bar.frame(height: 8)
                    value
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.scoreColor(score))
                    .frame(width: 22)
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize()
                bar
                    .frame(minWidth: 30, maxWidth: 90)
                    .frame(height: 8)
                value
            }
        }
    }

    private var value: some View {
        Text(score.map(String.init) ?? "–")
            .font(.subheadline.monospacedDigit().bold())
            .frame(minWidth: 32, alignment: .trailing)
            .fixedSize()
    }

    private var bar: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.subtle)
                    Capsule()
                        .fill(Theme.scoreColor(score))
                        .frame(width: geo.size.width * CGFloat(score ?? 0) / 100)
                }
            }
    }
}

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 44
    var color: Color = Theme.primary

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
        }
        .frame(width: size, height: size)
    }
}

struct MicButton: View {
    let isRecording: Bool
    let level: Float
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill((isRecording ? Theme.bad : Theme.primary).opacity(0.18))
                    .frame(width: 128, height: 128)
                    .scaleEffect(isRecording ? (reduceMotion ? 1 : 1 + CGFloat(level) * 0.35) : 0.9)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
                Circle()
                    .fill(isRecording ? Theme.badFill : Theme.primaryFill)
                    .frame(width: 88, height: 88)
                    .shadow(color: (isRecording ? Theme.bad : Theme.primary).opacity(0.4), radius: 14, y: 6)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Dừng ghi âm" : "Bắt đầu ghi âm")
    }
}

struct IconBadge: View {
    let systemImage: String
    var color: Color = Theme.primary
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps children onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(maxWidth: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Measuring and placing share this, so a row that fit when measured still fits when placed.
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        // Half a point of slack: bounds handed back after measuring can round just below the row width.
        let limit = maxWidth + 0.5
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > limit {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (frames, CGSize(width: width, height: y + rowHeight))
    }
}
