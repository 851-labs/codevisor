import Foundation

public struct PluginConsentMetadata: Encodable, Sendable {
  public struct Pane: Encodable, Sendable { let type: String; let title: String }
  public struct Tool: Encodable, Sendable { let name: String; let description: String }
  let name: String
  let version: String
  let publisher: String
  let description: String?
  let ageRating: Int?
  let panes: [Pane]
  let tools: [Tool]

  public init(_ entry: ServerPluginCatalogEntry, ageRating: Int?) {
    name = entry.name
    version = entry.version
    publisher = PluginModerationSubject.publisher(ofCatalogId: entry.id)
    description = entry.description
    self.ageRating = ageRating
    panes = entry.capabilities.panes.map { Pane(type: $0.type, title: $0.title) }
    tools = entry.capabilities.tools.map { Tool(name: $0.name, description: $0.description ?? "") }
  }

  public init(custom subject: PluginModerationSubject) {
    name = subject.name
    version = Self.customVersion
    publisher = subject.publisher
    description = nil
    ageRating = nil
    panes = []
    tools = []
  }

  static let customVersion = "custom"
}
