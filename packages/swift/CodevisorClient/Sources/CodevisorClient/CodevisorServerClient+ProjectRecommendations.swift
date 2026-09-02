import Foundation

public struct ServerProjectRecommendation: Decodable, Equatable, Sendable {
  public var path: String
  public var name: String
  public var sessionCount: Int
  public var lastActivity: String?

  public init(path: String, name: String, sessionCount: Int, lastActivity: String? = nil) {
    self.path = path
    self.name = name
    self.sessionCount = sessionCount
    self.lastActivity = lastActivity
  }
}

extension CodevisorServerClient {
  public func projectRecommendations(limit: Int) async throws -> [ServerProjectRecommendation] {
    var components = URLComponents()
    components.path = "/v1/projects/recommendations"
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    guard let requestPath = components.string else {
      throw CodevisorServerClientError.invalidURL("projects/recommendations")
    }
    return try await get(requestPath)
  }
}

public extension CodevisorServerClienting {
  func projectRecommendations(limit _: Int) async throws -> [ServerProjectRecommendation] {
    throw CodevisorServerClientError.invalidResponse
  }
}
