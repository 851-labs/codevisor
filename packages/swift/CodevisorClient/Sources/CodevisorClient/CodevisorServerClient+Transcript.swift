import Foundation

extension CodevisorServerClient {
  public func transcriptPage(id: UUID, before: String?, limit: Int = 32) async throws -> ServerTranscriptPage {
    var components = URLComponents()
    components.path = "/v1/sessions/\(id.uuidString)/transcript"
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    if let before {
      components.queryItems?.append(URLQueryItem(name: "before", value: before))
    }
    guard let path = components.string else { throw CodevisorServerClientError.invalidURL("transcript") }
    return try await get(path)
  }

  public func transcriptItemDetails(
    id: UUID,
    itemId: String,
    after: String?
  ) async throws -> ServerTranscriptItemDetails {
    let encoded = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
    let suffix = after.map { "?after=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
    return try await get("/v1/sessions/\(id.uuidString)/transcript/\(encoded)/details\(suffix)")
  }

  public func transcriptBodyPage(
    id: UUID, itemId: String, key: String, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    var components = URLComponents()
    components.path = "/v1/sessions/\(id.uuidString)/transcript/\(itemId)/body"
    components.queryItems = [
      URLQueryItem(name: "key", value: key), URLQueryItem(name: "field", value: field),
      URLQueryItem(name: "position", value: String(position)),
    ]
    guard let path = components.string else { throw CodevisorServerClientError.invalidResponse }
    return try await get(path)
  }
}
