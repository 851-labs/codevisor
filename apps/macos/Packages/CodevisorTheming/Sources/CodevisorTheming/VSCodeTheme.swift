import Foundation

/// The structural subset of a VSCode/Shiki theme JSON the theming pipeline
/// reads. `JSONDecoder` ignores unknown keys, so full VSCode themes (with
/// `tokenColors`, `semanticHighlighting`, …) and Shiki themes (with top-level
/// `fg`/`bg`) both decode through this one type. Keep the original bytes
/// alongside when the full document matters (custom-theme storage, the syntax
/// highlighter).
public struct VSCodeTheme: Codable, Equatable, Sendable {
    public var name: String?
    public var displayName: String?
    public var type: String?
    public var colors: [String: String]?
    public var fg: String?
    public var bg: String?

    public init(
        name: String? = nil,
        displayName: String? = nil,
        type: String? = nil,
        colors: [String: String]? = nil,
        fg: String? = nil,
        bg: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.type = type
        self.colors = colors
        self.fg = fg
        self.bg = bg
    }

    /// True when the document carries any color data at all — the minimum bar
    /// for treating a JSON file as a theme on import.
    public var hasColorData: Bool {
        if let colors, !colors.isEmpty { return true }
        return bg != nil || fg != nil
    }

    /// Whether the theme is dark: the explicit `type` when present, otherwise
    /// inferred from the background luminance (< 0.4 → dark). Defaults to
    /// light when nothing is measurable.
    public var resolvedIsDark: Bool {
        switch type?.lowercased() {
        case "dark": return true
        case "light": return false
        default: break
        }
        let background = colors?["editor.background"] ?? bg
        if let luminance = ColorMath.relativeLuminance(background) {
            return luminance < 0.4
        }
        return false
    }

    /// Decodes theme JSON bytes into a `VSCodeTheme`.
    public static func decode(from data: Data) throws -> VSCodeTheme {
        try JSONDecoder().decode(VSCodeTheme.self, from: data)
    }
}
