import Foundation

public struct ServerPluginAccount: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var plugin: String
  public var label: String?
  public var identity: String?
  public var method: String
  public var values: [String: ServerConfigFieldValue]
  public var secretsSet: [String]
  public var status: String
  public var createdAt: String

  public init(
    id: String,
    plugin: String,
    label: String? = nil,
    identity: String? = nil,
    method: String,
    values: [String: ServerConfigFieldValue] = [:],
    secretsSet: [String] = [],
    status: String = "ok",
    createdAt: String = ""
  ) {
    self.id = id
    self.plugin = plugin
    self.label = label
    self.identity = identity
    self.method = method
    self.values = values
    self.secretsSet = secretsSet
    self.status = status
    self.createdAt = createdAt
  }

  public var needsReauthorization: Bool { status == "reauthorize" }

  public var isOAuth: Bool { method == "oauth2" }
}
