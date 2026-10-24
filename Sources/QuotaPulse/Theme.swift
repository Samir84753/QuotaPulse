import SwiftUI

/// Overall appearance of the popover/settings window. "System" follows macOS appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Accent tint applied to progress bars, gauges and buttons.
enum AppAccent: String, CaseIterable, Identifiable {
    case blue, purple, green, orange, pink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        }
    }
}
