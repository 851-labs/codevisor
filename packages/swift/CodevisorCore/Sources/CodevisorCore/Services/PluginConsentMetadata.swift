import Foundation

public struct PluginConsentMetadata: Encodable, Sendable {
  public struct Capabilities: Encodable, Sendable {
    let tools: Int
    let events: Int
    let skills: Int
    let panes: Int
    let ingress: Int
  }

  let name: String
  let version: String
  let publisher: String
  let description: String?
  let ageRating: Int?
  let capabilities: Capabilities?

  public init(_ entry: ServerPluginCatalogEntry, ageRating: Int?) {
    name = entry.name
    version = entry.version
    publisher = PluginModerationSubject.publisher(ofCatalogId: entry.id)
    description = entry.description
    self.ageRating = ageRating
    let listed = entry.capabilities
    capabilities = Capabilities(
      tools: listed.tools.count, events: listed.events.count, skills: listed.skills.count,
      panes: listed.panes.count, ingress: listed.ingress.count)
  }

  public init(custom subject: PluginModerationSubject) {
    name = subject.name
    version = Self.customVersion
    publisher = subject.publisher
    description = nil
    ageRating = nil
    capabilities = nil
  }

  static let customVersion = "custom"
}
