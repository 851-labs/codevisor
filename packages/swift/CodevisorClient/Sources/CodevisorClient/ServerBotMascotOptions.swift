import Foundation

public struct ServerBotMascotOptions: Decodable, Equatable, Sendable {
  public struct Swatch: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var hex: String

    public init(id: String, title: String, hex: String) {
      self.id = id
      self.title = title
      self.hex = hex
    }
  }

  public struct Choice: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var swatches: [Swatch]
    public var hasAuto: Bool

    public init(id: String, title: String, swatches: [Swatch] = [], hasAuto: Bool = false) {
      self.id = id
      self.title = title
      self.swatches = swatches
      self.hasAuto = hasAuto
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      title = try container.decode(String.self, forKey: .title)
      swatches = try container.decodeIfPresent([Swatch].self, forKey: .swatches) ?? []
      hasAuto = try container.decodeIfPresent(Bool.self, forKey: .hasAuto) ?? false
    }

    public func offers(_ color: String) -> Bool {
      color == ServerBotMascot.autoColor || swatches.contains { $0.id == color }
    }

    public func shownSwatch(for color: String) -> String {
      guard color == ServerBotMascot.autoColor, !hasAuto else { return color }
      return swatches.first?.id ?? color
    }

    private enum CodingKeys: String, CodingKey {
      case id, title, swatches, hasAuto
    }
  }

  public struct ColorChoice: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var gradient: [String]
    public var accent: String?

    public init(id: String, title: String, gradient: [String], accent: String? = nil) {
      self.id = id
      self.title = title
      self.gradient = gradient
      self.accent = accent
    }
  }

  public var colors: [ColorChoice]
  public var hats: [Choice]
  public var eyewear: [Choice]
  public var nextBotMascot: ServerBotMascot

  public init(colors: [ColorChoice], hats: [Choice], eyewear: [Choice], nextBotMascot: ServerBotMascot) {
    self.colors = colors
    self.hats = hats
    self.eyewear = eyewear
    self.nextBotMascot = nextBotMascot
  }

  public func items(for part: ServerBotMascotPart) -> [Choice] {
    switch part {
    case .hat: hats
    case .eyewear: eyewear
    }
  }

  public func accent(for color: String) -> String? {
    colors.first { $0.id == color }?.accent
  }
}
