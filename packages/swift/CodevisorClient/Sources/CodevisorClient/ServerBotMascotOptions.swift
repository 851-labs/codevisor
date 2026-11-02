import Foundation

public struct ServerBotMascotOptions: Decodable, Equatable, Sendable {
  public struct Choice: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }

  public struct ColorChoice: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var gradient: [String]

    public init(id: String, title: String, gradient: [String]) {
      self.id = id
      self.title = title
      self.gradient = gradient
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
}
