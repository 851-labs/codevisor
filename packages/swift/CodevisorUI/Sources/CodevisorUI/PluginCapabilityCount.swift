import CodevisorCore
import Foundation

public struct PluginCapabilityCount: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let systemImage: String

  public static func counts(in capabilities: ServerPluginCapabilities) -> [PluginCapabilityCount] {
    [
      count("tool", capabilities.tools.count, systemImage: "wrench.and.screwdriver"),
      count("event", capabilities.events.count, systemImage: "bolt"),
      count("skill", capabilities.skills.count, systemImage: "book.closed"),
      count("pane", capabilities.panes.count, systemImage: "macwindow"),
    ].compactMap { $0 }
  }

  private static func count(_ noun: String, _ value: Int, systemImage: String) -> PluginCapabilityCount? {
    guard value > 0 else { return nil }
    let title = "\(value) \(noun)\(value == 1 ? "" : "s")"
    return PluginCapabilityCount(id: noun, title: title, systemImage: systemImage)
  }
}
