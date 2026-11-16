import SwiftUI

/// Re-breaks wrapped text so the last line never holds a lone word.
///
/// The content is laid out a little narrower, by just enough for about half a line of text to
/// flow down into the last line, and never by so much that a line is added. For two lines that
/// means evenly balanced; a long paragraph barely changes. The narrower width is what the layout
/// reports as its size, so the container aligns the text exactly as it would any other view.
struct BalancedLayout: Layout {
    struct Cache {
        struct Key: Hashable {
            let width: CGFloat?
            let height: CGFloat?
        }
        var sizes: [Key: CGSize] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let key = Cache.Key(width: proposal.width, height: proposal.height)
        if let size = cache.sizes[key] { return size }
        let natural = content.sizeThatFits(proposal)
        let width = balancedWidth(of: content, in: natural)
        let size = width < natural.width ? CGSize(width: width, height: natural.height) : natural
        cache.sizes[key] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    private func balancedWidth(of content: LayoutSubview, in size: CGSize) -> CGFloat {
        func fits(_ width: CGFloat) -> Bool {
            content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height <= size.height + 0.5
        }
        let lineHeight = content.sizeThatFits(.unspecified).height
        // A single line has nothing to balance; text its container already cut short must not be squeezed further.
        guard lineHeight > 0, lineHeight < size.height - 0.5, fits(size.width) else { return size.width }

        let lines = max(2, (size.height / lineHeight).rounded())
        var low = (size.width * (1 - 0.5 / (lines - 1))).rounded(.down)
        var high = size.width.rounded(.up)
        while high - low > 1 {
            let middle = ((low + high) / 2).rounded()
            if fits(middle) { high = middle } else { low = middle }
        }
        return high
    }
}

private struct Balanced: ViewModifier {
    @Environment(\.lineLimit) private var lineLimit

    func body(content: Content) -> some View {
        // With a line limit the text may be truncated, and narrowing it would only hide more of it.
        if lineLimit == nil {
            BalancedLayout { content }
        } else {
            content
        }
    }
}

/// The app's `Text`. It shadows SwiftUI's so that every piece of text is balanced without each
/// call site having to ask. Where SwiftUI needs to read the text itself (picker options, tab
/// items, `Canvas` drawing) write `SwiftUI.Text` instead.
struct Text: View {
    private let text: SwiftUI.Text

    init(_ key: LocalizedStringKey) { text = SwiftUI.Text(key) }
    @_disfavoredOverload init<S: StringProtocol>(_ content: S) { text = SwiftUI.Text(content) }
    @_disfavoredOverload init(_ attributed: AttributedString) { text = SwiftUI.Text(attributed) }
    init(verbatim content: String) { text = SwiftUI.Text(verbatim: content) }
    init(_ styled: SwiftUI.Text) { text = styled }

    var body: some View { text.modifier(Balanced()) }
}

/// The app's `Label`, balanced like `Text`. Tab items need `SwiftUI.Label`.
struct Label: View {
    private let label: SwiftUI.Label<SwiftUI.Text, Image>

    init(_ title: LocalizedStringKey, systemImage: String) { label = SwiftUI.Label(title, systemImage: systemImage) }
    @_disfavoredOverload init<S: StringProtocol>(_ title: S, systemImage: String) {
        label = SwiftUI.Label(title, systemImage: systemImage)
    }

    var body: some View { label.modifier(Balanced()) }
}
