import Foundation

public struct ServerSessionContext: Decodable, Equatable, Sendable {
  public struct Category: Decodable, Equatable, Sendable {
    public var name: String
    public var tokens: Double
    public var color: String?
    public var isDeferred: Bool?
  }

  public struct Tool: Decodable, Equatable, Sendable {
    public var name: String
    public var serverName: String
    public var tokens: Double
    public var isLoaded: Bool?
  }

  public var model: String?
  public var totalTokens: Double
  public var maxTokens: Double
  public var categories: [Category]
  public var mcpTools: [Tool]
}
