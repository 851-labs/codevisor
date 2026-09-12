import Foundation

/// Index metadata deliberately excludes filesystem paths, tool schemas, and credentials.
public struct PluginConsentMetadata: Encodable, Sendable {
  public struct Pane: Encodable, Sendable { let type: String; let title: String }
  public struct Tool: Encodable, Sendable { let name: String; let description: String }
  let name: String
  let version: String
  let description: String?
  let ageRating: Int?
  let panes: [Pane]
  let tools: [Tool]

  public init(_ plugin: ServerPluginRemoteDiscovery) {
    name = plugin.name; version = plugin.version; description = plugin.description; ageRating = plugin.ageRating
    panes = plugin.panes.map { Pane(type: $0.type, title: $0.title) }
    tools = (plugin.tools ?? []).map { Tool(name: $0.name, description: $0.description) }
  }

  public init(_ plugin: ServerPluginSummary) {
    name = plugin.name; version = plugin.version; description = plugin.description; ageRating = plugin.ageRating
    panes = plugin.panes.map { Pane(type: $0.type, title: $0.title) }
    tools = (plugin.tools ?? []).map { Tool(name: $0.name, description: $0.description) }
  }
}
