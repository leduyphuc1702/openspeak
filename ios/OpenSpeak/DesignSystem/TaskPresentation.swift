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

/// The strip along the bottom of a screen that holds its main action. Scrolling content stops
/// above it, so the action stays on screen whatever the content length or text size.
struct ActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Theme.surface.shadow(.drop(color: .black.opacity(0.25), radius: 12, y: -4)))
    }
}

extension View {
    /// Pins `actions` to the bottom edge of this view, above the home indicator or tab bar.
    func actionBar<Actions: View>(isPresented: Bool = true, @ViewBuilder _ actions: () -> Actions) -> some View {
        let bar = actions()
        return safeAreaInset(edge: .bottom, spacing: 0) {
            if isPresented { ActionBar { bar } }
        }
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
