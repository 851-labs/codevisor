import Foundation

public struct ServerBotMascot: Codable, Hashable, Sendable {
  public static let autoColor = "auto"

  public var color: String
  public var hat: String
  public var hatColor: String
  public var eyewear: String
  public var eyewearColor: String

  public init(
    color: String,
    hat: String,
    hatColor: String = Self.autoColor,
    eyewear: String,
    eyewearColor: String = Self.autoColor
  ) {
    self.color = color
    self.hat = hat
    self.hatColor = hatColor
    self.eyewear = eyewear
    self.eyewearColor = eyewearColor
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    color = try container.decode(String.self, forKey: .color)
    hat = try container.decode(String.self, forKey: .hat)
    hatColor = try container.decodeIfPresent(String.self, forKey: .hatColor) ?? Self.autoColor
    eyewear = try container.decode(String.self, forKey: .eyewear)
    eyewearColor = try container.decodeIfPresent(String.self, forKey: .eyewearColor) ?? Self.autoColor
  }

  public func wearing(_ item: ServerBotMascotOptions.Choice, on part: ServerBotMascotPart) -> ServerBotMascot {
    var next = self
    next[keyPath: part.item] = item.id
    if !item.offers(self[keyPath: part.color]) { next[keyPath: part.color] = Self.autoColor }
    return next
  }

  var queryItems: [URLQueryItem] {
    [
      URLQueryItem(name: "color", value: color),
      URLQueryItem(name: "hat", value: hat),
      URLQueryItem(name: "eyewear", value: eyewear),
    ] + colorQueryItem("hatColor", hatColor) + colorQueryItem("eyewearColor", eyewearColor)
  }

  private func colorQueryItem(_ name: String, _ value: String) -> [URLQueryItem] {
    value == Self.autoColor ? [] : [URLQueryItem(name: name, value: value)]
  }
}
