import Foundation

/// A catalog entry: everything the picker UI needs without loading the theme
/// JSON itself. Theme ids are namespaced by group ("system-light",
/// "pierre:pierre-dark", "shiki:dracula", "custom:my-theme").
public struct ThemeDescriptor: Identifiable, Equatable, Sendable, Codable {
    public enum Group: String, Codable, Sendable, CaseIterable {
        case system
        case pierre
        case shiki
        case custom

        /// Section title shown in the theme pickers.
        public var displayName: String {
            switch self {
            case .system: return "System"
            case .pierre: return "Pierre"
            case .shiki: return "Shiki"
            case .custom: return "Custom"
            }
        }
    }

    public enum SchemeType: String, Codable, Sendable {
        case light
        case dark
    }

    public let id: String
    public let displayName: String
    public let type: SchemeType
    public let group: Group

    public init(id: String, displayName: String, type: SchemeType, group: Group) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.group = group
    }
}
