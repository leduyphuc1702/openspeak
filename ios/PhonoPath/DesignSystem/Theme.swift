import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Dark navy-purple look: gradient backdrop, translucent cards, sky-blue actions,
/// glowing outlined chips. The app forces dark mode (see PhonoPathApp).
enum Theme {
    static let primary = Color(red: 0.24, green: 0.68, blue: 0.95)       // actions, selected chips
    static let primaryDeep = Color(red: 0.42, green: 0.27, blue: 0.86)   // purple
    static let accent = Color(red: 0.78, green: 0.60, blue: 1.0)         // badges, highlights
    static let good = Color(red: 0.25, green: 0.82, blue: 0.45)
    static let ok = Color(red: 0.98, green: 0.66, blue: 0.20)
    static let bad = Color(red: 1.0, green: 0.50, blue: 0.52)

    // Backgrounds that carry white text or icons. The colours above are tuned to be read *on* the
    // dark backdrop; white on them falls short of 4.5:1, so filled controls use these darker shades.
    static let primaryFill = Color(red: 0.10, green: 0.45, blue: 0.85)
    static let goodFill = Color(red: 0.10, green: 0.52, blue: 0.28)
    static let okFill = Color(red: 0.68, green: 0.36, blue: 0.04)
    static let badFill = Color(red: 0.80, green: 0.20, blue: 0.27)

    /// The shade of a theme colour to put behind white text.
    static func fill(_ color: Color) -> Color {
        switch color {
        case primary, glow: return primaryFill
        case good: return goodFill
        case ok: return okFill
        case bad: return badFill
        case accent: return primaryDeep
        default: return color
        }
    }

    static let ink = Color(red: 0.96, green: 0.96, blue: 1.0)
    static let background = Color(red: 0.09, green: 0.07, blue: 0.19)
    static let surface = Color(red: 0.16, green: 0.13, blue: 0.29)
    static let subtle = Color(red: 0.23, green: 0.20, blue: 0.38)
    static let glow = Color(red: 0.35, green: 0.62, blue: 1.0)

    static let hero = LinearGradient(colors: [primaryDeep, Color(red: 0.20, green: 0.36, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Full-screen backdrop: deep navy with a warm glow top-left and a violet glow bottom-right.
    static var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.30), background,
                                    Color(red: 0.07, green: 0.06, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.65, green: 0.25, blue: 0.35).opacity(0.35), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 420)
            RadialGradient(colors: [primaryDeep.opacity(0.35), .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    static let cornerRadius: CGFloat = 20

    static func scoreColor(_ score: Int?) -> Color {
        guard let score else { return .secondary }
        if score >= 80 { return good }
        if score >= 55 { return ok }
        return bad
    }
}

enum Haptics {
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func result(success: Bool) {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
        #endif
    }
}

extension View {
    /// The shared gradient backdrop behind a screen.
    func screenBackground() -> some View {
        background { Theme.backdrop }
    }

    /// For a screen without a navigation bar: content scrolling up fades out behind the status bar.
    func statusBarFade() -> some View {
        overlay(alignment: .top) {
            GeometryReader { geo in
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: geo.safeAreaInsets.top + 14)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
    }

    func inlineNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        return navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        return navigationTitle(title)
        #endif
    }
}
