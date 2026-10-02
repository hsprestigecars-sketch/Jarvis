import SwiftUI
import JarvisCore

enum Theme {
    static let background = Color(red: 0.02, green: 0.05, blue: 0.09)
    static let panel = Color(red: 0.05, green: 0.10, blue: 0.16)
    static let panelBorder = Color(red: 0.25, green: 0.82, blue: 1.0).opacity(0.25)
    static let cyan = Color(red: 0.25, green: 0.82, blue: 1.0)
    static let amber = Color(red: 0.96, green: 0.72, blue: 0.24)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let protected = Color(red: 0.62, green: 0.48, blue: 1.0)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)

    static func color(for status: JarvisStatus) -> Color {
        switch status {
        case .ready: cyan
        case .listening: Color(red: 0.3, green: 1.0, blue: 0.75)
        case .thinking, .working: amber
        case .speaking: cyan
        case .waitingForConfirmation: amber
        case .protected: protected
        case .error: danger
        }
    }
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.panelBorder, lineWidth: 1))
    }
}

extension View {
    func jarvisPanel() -> some View { modifier(PanelBackground()) }
}
