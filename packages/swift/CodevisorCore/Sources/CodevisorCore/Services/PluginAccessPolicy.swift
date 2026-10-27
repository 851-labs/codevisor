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

  public static let appAgeCeiling = 16
  private static let knownRatings: Set<Int> = [4, 9, 13, 16, 18]

  public var supportedAgeRating: Int
  public var blocks: [Block]
  public var ageRatings: [AgeRating]

  public func ageRating(pluginId: String, declared: Int?) -> Int? {
    ageRatings.first { $0.pluginId == pluginId }?.minimumAge ?? declared
  }

  public func restriction(for subject: PluginModerationSubject, blockedPublishers: [String]) -> String? {
    if isBlocked(subject) { return "This plugin is unavailable on iOS." }
    if blockedPublishers.contains(subject.publisher) { return "You blocked this publisher." }
    if subject.isCustom { return nil }

    let minimumAge = ageRating(pluginId: subject.pluginId, declared: subject.declaredAgeRating)
    guard let minimumAge, Self.knownRatings.contains(minimumAge) else {
      return "The publisher needs to add an age rating before this plugin can open on iOS."
    }
    if minimumAge > min(supportedAgeRating, Self.appAgeCeiling) {
      return "This plugin exceeds Codevisor’s iOS age rating."
    }
    return nil
  }

  private func isBlocked(_ subject: PluginModerationSubject) -> Bool {
    blocks.contains { block in
      (block.targetKind == "plugin" && block.target == subject.pluginId)
        || (block.targetKind == "publisher" && block.target == subject.publisher)
    }
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
