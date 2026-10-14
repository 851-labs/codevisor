import Foundation

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

  public var hasColorData: Bool {
    if let colors, !colors.isEmpty { return true }
    return bg != nil || fg != nil
  }

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

  public static func decode(from data: Data) throws -> VSCodeTheme {
    try JSONDecoder().decode(VSCodeTheme.self, from: data)
  }
}
