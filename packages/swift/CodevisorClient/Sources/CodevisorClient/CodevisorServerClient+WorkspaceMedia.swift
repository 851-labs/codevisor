import Foundation

public struct ServerWorkspacePhoto: Codable, Equatable, Sendable, Identifiable {
  public enum Source: String, Codable, Sendable {
    case message
    case tool
  }

  public let attachment: ServerAttachmentRef
  public let sessionId: UUID
  public let itemId: String
  public let createdAt: String
  public let source: Source

  public var id: String { attachment.fileId }

  public init(
    attachment: ServerAttachmentRef, sessionId: UUID, itemId: String, createdAt: String, source: Source
  ) {
    self.attachment = attachment
    self.sessionId = sessionId
    self.itemId = itemId
    self.createdAt = createdAt
    self.source = source
  }
}

public struct ServerWorkspacePhotoPage: Codable, Equatable, Sendable {
  public let photos: [ServerWorkspacePhoto]
  public let nextBefore: String?

  public init(photos: [ServerWorkspacePhoto], nextBefore: String? = nil) {
    self.photos = photos
    self.nextBefore = nextBefore
  }
}

public struct ServerWorkspaceLink: Codable, Equatable, Sendable, Identifiable {
  public let url: URL
  public let title: String?
  public let sessionId: UUID
  public let itemId: String
  public let createdAt: String

  public var id: URL { url }

  public init(url: URL, title: String? = nil, sessionId: UUID, itemId: String, createdAt: String) {
    self.url = url
    self.title = title
    self.sessionId = sessionId
    self.itemId = itemId
    self.createdAt = createdAt
  }
}

public struct ServerWorkspaceLinkPage: Codable, Equatable, Sendable {
  public let links: [ServerWorkspaceLink]
  public let nextBefore: String?

  public init(links: [ServerWorkspaceLink], nextBefore: String? = nil) {
    self.links = links
    self.nextBefore = nextBefore
  }
}

extension CodevisorServerClient {
  public func workspacePhotos(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspacePhotoPage
  {
    try await get(try workspaceMediaPath(workspaceId, "photos", before: before, limit: limit))
  }

  public func workspaceLinks(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspaceLinkPage
  {
    try await get(try workspaceMediaPath(workspaceId, "links", before: before, limit: limit))
  }

  private func workspaceMediaPath(
    _ workspaceId: UUID, _ kind: String, before: String?, limit: Int
  ) throws
    -> String
  {
    let endpoint = "/v1/workspaces/\(workspaceId.uuidString)/\(kind)"
    var components = URLComponents()
    components.path = endpoint
    components.queryItems =
      [URLQueryItem(name: "limit", value: String(limit))]
      + (before.map { [URLQueryItem(name: "before", value: $0)] } ?? [])
    guard let value = components.string else { throw CodevisorServerClientError.invalidURL(endpoint) }
    return value
  }
}

extension CodevisorServerClienting {
  public func workspacePhotos(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspacePhotoPage
  {
    throw CodevisorServerClientError.invalidResponse
  }

  public func workspaceLinks(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspaceLinkPage
  {
    throw CodevisorServerClientError.invalidResponse
  }
}
