import Foundation

public struct PluginAccessPolicy: Decodable, Sendable {
  public struct Block: Decodable, Sendable {
    public var targetKind: String
    public var target: String
    public var reason: String
  }

  public struct AgeRating: Decodable, Sendable {
    public var pluginId: String
    public var minimumAge: Int
  }

  public var supportedAgeRating: Int
  public var blocks: [Block]
  public var ageRatings: [AgeRating]

  public func ageRating(pluginId: String, declared: Int?) -> Int? {
    ageRatings.first { $0.pluginId == pluginId }?.minimumAge ?? declared
  }

  public func restriction(pluginId: String, ageRating: Int?, blockedPublishers: [String]) -> String? {
    let publisher = String(pluginId.split(separator: ".").first ?? "")
    if blocks.contains(where: {
      ($0.targetKind == "plugin" && $0.target == pluginId)
        || ($0.targetKind == "publisher" && $0.target == publisher)
    }) {
      return "This plugin is unavailable on iOS."
    }
    if blockedPublishers.contains(publisher) { return "You blocked this publisher." }
    let minimumAge = self.ageRating(pluginId: pluginId, declared: ageRating)
    guard let minimumAge, [4, 9, 13, 16, 18].contains(minimumAge) else {
      return "The publisher needs to add an age rating before this plugin can open on iOS."
    }
    if minimumAge > min(supportedAgeRating, 16) { return "This plugin exceeds Codevisor’s iOS age rating." }
    return nil
  }
}

public struct PluginPreferences: Decodable, Sendable {
  public var blockedPublishers: [String]
}

public struct PluginAccessError: LocalizedError {
  public var errorDescription: String? { message }
  public let message: String
  public init(_ message: String) { self.message = message }
}
