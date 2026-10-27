import Foundation

public struct UserMessageAttribution: Codable, Equatable, Hashable, Sendable {
  public var kind: String
  public var viewId: String?
  public var plugin: String

  public init(kind: String, viewId: String?, plugin: String) {
    self.kind = kind
    self.viewId = viewId
    self.plugin = plugin
  }

  public static func app(viewId: String, plugin: String) -> UserMessageAttribution {
    UserMessageAttribution(kind: "app", viewId: viewId, plugin: plugin)
  }

  public var displayName: String? {
    let name = plugin.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}
