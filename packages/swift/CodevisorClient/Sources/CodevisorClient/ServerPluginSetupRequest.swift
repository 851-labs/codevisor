import ACPKit
import Foundation

public struct ServerPluginSetupRequest: Decodable, Equatable, Sendable {
  public struct Machine: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
  }

  public enum Auth: String, Decodable, Sendable {
    case none
    case fields
    case oauth2
    case mcpOAuth
  }

  public var plugin: String
  public var catalogId: String?
  public var serverId: String?
  public var name: String
  public var publisher: String?
  public var description: String?
  public var reason: String
  public var auth: Auth
  public var capabilities: ServerPluginCapabilities
  public var machine: Machine

  public static func decoded(from questions: [QuestionSpec]) -> ServerPluginSetupRequest? {
    guard let payload = questions.lazy.compactMap(\.pluginSetup).first else { return nil }
    guard let data = try? JSONEncoder().encode(payload) else { return nil }
    return try? JSONDecoder().decode(ServerPluginSetupRequest.self, from: data)
  }
}
