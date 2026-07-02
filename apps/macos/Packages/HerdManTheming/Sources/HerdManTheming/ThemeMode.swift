import Foundation

/// How the app picks between the light and dark theme slots: force one, or
/// follow the OS appearance.
public enum ThemeMode: String, Codable, Sendable, CaseIterable {
    case light
    case dark
    case system
}
