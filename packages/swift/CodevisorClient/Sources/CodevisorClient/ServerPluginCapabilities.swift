import Foundation

public struct ServerPluginCapabilities: Codable, Equatable, Sendable {
  public var tools: [ServerPluginToolDigest]
  public var events: [ServerPluginEventDigest]
  public var skills: [ServerPluginSkillDigest]
  public var panes: [ServerPluginPane]
  public var ingress: [ServerPluginIngress]

  public init(
    tools: [ServerPluginToolDigest] = [],
    events: [ServerPluginEventDigest] = [],
    skills: [ServerPluginSkillDigest] = [],
    panes: [ServerPluginPane] = [],
    ingress: [ServerPluginIngress] = []
  ) {
    self.tools = tools
    self.events = events
    self.skills = skills
    self.panes = panes
    self.ingress = ingress
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tools = try container.decodeIfPresent([ServerPluginToolDigest].self, forKey: .tools) ?? []
    events = try container.decodeIfPresent([ServerPluginEventDigest].self, forKey: .events) ?? []
    skills = try container.decodeIfPresent([ServerPluginSkillDigest].self, forKey: .skills) ?? []
    panes = try container.decodeIfPresent([ServerPluginPane].self, forKey: .panes) ?? []
    ingress = try container.decodeIfPresent([ServerPluginIngress].self, forKey: .ingress) ?? []
  }

  public var isEmpty: Bool {
    tools.isEmpty && events.isEmpty && skills.isEmpty && panes.isEmpty
  }
}

public struct ServerPluginToolDigest: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var description: String?
  public var effects: String?
  public var app: Bool?

  public var id: String { name }

  public init(name: String, description: String? = nil, effects: String? = nil, app: Bool? = nil) {
    self.name = name
    self.description = description
    self.effects = effects
    self.app = app
  }
}

public struct ServerPluginEventDigest: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var description: String?

  public var id: String { name }

  public init(name: String, description: String? = nil) {
    self.name = name
    self.description = description
  }
}

public struct ServerPluginSkillDigest: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var description: String?

  public var id: String { name }

  public init(name: String, description: String? = nil) {
    self.name = name
    self.description = description
  }
}

public struct ServerPluginPane: Codable, Hashable, Identifiable, Sendable {
  public var type: String
  public var title: String
  public var resourceUri: String

  public var id: String { type }

  public init(type: String, title: String, resourceUri: String) {
    self.type = type
    self.title = title
    self.resourceUri = resourceUri
  }
}

public struct ServerPluginIngress: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var title: String?

  public var id: String { name }

  public init(name: String, title: String? = nil) {
    self.name = name
    self.title = title
  }
}
