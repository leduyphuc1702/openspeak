import SwiftUI

/// Streak, XP and mastered-sound counters shown at the top of the main screens.
struct StatsBar: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        HStack(spacing: 12) {
            item("flame.fill", "\(progress.streak())", progress.streak() > 0 ? Theme.bad : .secondary, "Chuỗi ngày học")
            item("diamond.fill", "\(progress.totalXP)", Theme.accent, "Tổng XP")
            item("trophy.fill", "\(progress.masteredSoundCount)", Theme.ok, "Âm đã thành thạo")
        }
        .font(.subheadline.bold().monospacedDigit())
    }

    private func item(_ icon: String, _ value: String, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Outlined capsule that glows; filled sky blue when selected.
struct GlowChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(selected ? Theme.background : Theme.ink)
                .background(selected ? Theme.primary : Theme.surface.opacity(0.6), in: Capsule())
                .overlay(Capsule().stroke(Theme.glow.opacity(selected ? 0 : 0.8), lineWidth: 1.2))
                .shadow(color: Theme.glow.opacity(0.55), radius: selected ? 10 : 5)
        }
        .buttonStyle(.plain)
    }
}

/// Tabs in one glowing track, sized so that all of them stay on screen.
struct SegmentBar: View {
    let titles: [String]
    @Binding var selection: String

    var body: some View {
        // Every tab shares one size: the first row that fits the width wins.
        ViewThatFits(in: .horizontal) {
            row(.subheadline, padding: 12)
            row(.footnote, padding: 9)
            row(.footnote, padding: 6)
            row(.caption, padding: 5)
        }
        .padding(4)
        .background(Theme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(Theme.glow.opacity(0.7), lineWidth: 1.2))
        .shadow(color: Theme.glow.opacity(0.35), radius: 6)
    }

    private func row(_ font: Font, padding: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.element) { index, title in
                let selected = selection == title
                if index > 0 { Spacer(minLength: 0) }
                Button { selection = title } label: {
                    Text(title)
                        .font(font.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, padding).padding(.vertical, 9)
                        .foregroundStyle(selected ? Theme.background : Theme.ink)
                        .background(selected ? Theme.primary : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.\(title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A coach entry on the home screen: title, one line, a "Luyện tập" pill and an illustration.
struct CoachCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title3.bold()).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Luyện tập")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Theme.subtle, in: Capsule())
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().fill(tint.opacity(0.25)).frame(width: 84, height: 84).blur(radius: 14)
                    Image(systemName: icon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                        .shadow(color: tint.opacity(0.7), radius: 10)
                }
                .frame(width: 92, height: 92)
            }
            .card(padding: 18)
        }
        .buttonStyle(.plain)
    }
}

/// One lesson in a unit, listed vertically like a syllabus.
struct LessonRow: View {
    let number: Int
    let title: String
    let kind: String
    let icon: String
    let done: Bool
    let current: Bool
    let locked: Bool
    /// Replaces "Bài N" above the title (e.g. for an exam).
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: locked ? "lock.fill" : icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(current ? Theme.primary : (locked ? Color.secondary : Theme.glow))
            VStack(alignment: .leading, spacing: 3) {
                Text(caption ?? "Bài \(number)").font(.caption).foregroundStyle(current ? Theme.background.opacity(0.7) : .secondary)
                Text(title).font(.headline).foregroundStyle(current ? Theme.background : Theme.ink)
                Text(kind).font(.caption).foregroundStyle(current ? Theme.background.opacity(0.6) : .secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.good)
            } else if current {
                ZStack {
                    Circle().fill(Theme.good.opacity(0.25)).frame(width: 34, height: 34)
                    Circle().fill(Theme.good).frame(width: 14, height: 14)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(current ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(locked ? 0.55 : 1)
    }
}

/// "Unit 2 · 0/5 bài" badge row above a unit's lessons.
struct UnitHeader: View {
    let index: Int
    let title: String
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Unit \(index)")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.primaryDeep, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                Text("\(done)/\(total) bài").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(title).font(.title3.bold()).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Pentagon-style radar for skill percentages (nil = not measured yet).
struct RadarChart: View {
    let axes: [(title: String, value: Int?)]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size * 0.30
            ZStack {
                Canvas { context, _ in
                    let n = axes.count
                    func point(_ i: Int, _ r: Double) -> CGPoint {
                        let angle = -Double.pi / 2 + Double(i) * 2 * .pi / Double(n)
                        return CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                    }
                    for level in [1.0, 0.75, 0.5, 0.25] {
                        var ring = Path()
                        for i in 0..<n {
                            let p = point(i, Double(radius) * level)
                            i == 0 ? ring.move(to: p) : ring.addLine(to: p)
                        }
                        ring.closeSubpath()
                        context.fill(ring, with: .color(Theme.subtle.opacity(0.25 + 0.15 * (1 - level))))
                        context.stroke(ring, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    }
                    var shape = Path()
                    for i in 0..<n {
                        let v = Double(axes[i].value ?? 0) / 100
                        let p = point(i, Double(radius) * max(v, 0.04))
                        i == 0 ? shape.move(to: p) : shape.addLine(to: p)
                    }
                    shape.closeSubpath()
                    context.fill(shape, with: .linearGradient(Gradient(colors: [Theme.primary.opacity(0.55), Theme.primaryDeep.opacity(0.55)]),
                                                              startPoint: CGPoint(x: center.x, y: center.y - radius),
                                                              endPoint: CGPoint(x: center.x, y: center.y + radius)))
                    context.stroke(shape, with: .color(Theme.primary), lineWidth: 2)
                }
                ForEach(Array(axes.enumerated()), id: \.offset) { i, axis in
                    let angle = -Double.pi / 2 + Double(i) * 2 * .pi / Double(axes.count)
                    let r = Double(radius) + 42
                    VStack(spacing: 2) {
                        Text(axis.title).font(.caption).foregroundStyle(Theme.ink)
                        Text(axis.value.map { "\($0)%" } ?? "–")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Theme.scoreColor(axis.value))
                    }
                    .position(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axes.map { "\($0.title) \($0.value.map { "\($0) phần trăm" } ?? "chưa có")" }.joined(separator: ", "))
    }
}
