import SwiftUI

/// The system Close button for the navigation bar of a modal view.
struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .close) { dismiss() }
        } else {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Đóng")
        }
    }
}

extension View {
    /// Gives a modal view an obvious way out, next to swiping it away.
    func closeToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton() }
        }
    }
}

/// A screen laid out to fill the display with spacers, which scrolls instead of squeezing its
/// text once large Dynamic Type sizes make the content taller than the screen.
struct ScrollingWhenNeeded<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content.frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension View {
    func scrollingWhenNeeded() -> some View {
        ScrollingWhenNeeded { self }
    }
}

/// Opens a self-contained task (a lesson, a quiz, a speaking session, a chat) full screen.
///
/// A task has its own controls along the bottom, so it covers the tab bar as a modal view
/// instead of being pushed onto the tab's navigation stack with the tab bar hidden.
struct TaskLink<Destination: View, Content: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Content
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { label() }
            .fullScreenCoverCompat(isPresented: $presented) {
                NavigationStack { destination().closeToolbar() }
            }
    }
}
