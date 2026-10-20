import Foundation

public struct ServerWorkspaceMedia: Codable, Equatable, Sendable, Identifiable {
  public enum Source: String, Codable, Sendable {
    case message
    case tool
  }

  public let attachment: ServerAttachmentRef
  public let sessionId: UUID
  public let itemId: String
  public let createdAt: String
  public let source: Source
  public let durationSeconds: Double?

  public var id: String { attachment.fileId }
  public var isVideo: Bool { attachment.mimeType.hasPrefix("video/") }

  public init(
    attachment: ServerAttachmentRef, sessionId: UUID, itemId: String, createdAt: String, source: Source,
    durationSeconds: Double? = nil
  ) {
    self.attachment = attachment
    self.sessionId = sessionId
    self.itemId = itemId
    self.createdAt = createdAt
    self.source = source
    self.durationSeconds = durationSeconds
  }
}

public struct ServerWorkspaceMediaPage: Codable, Equatable, Sendable {
  public let media: [ServerWorkspaceMedia]
  public let nextBefore: String?

  public init(media: [ServerWorkspaceMedia], nextBefore: String? = nil) {
    self.media = media
    self.nextBefore = nextBefore
  }
}

private struct ServerWorkspacePhotoPage: Decodable {
  let photos: [ServerWorkspaceMedia]
  let nextBefore: String?
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

public struct ServerWorkspaceFileChange: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case added
    case modified
    case deleted
  }

  public let path: String
  public let added: Int
  public let removed: Int
  public let status: Status?
  public let uncommitted: Bool
  public let changedAt: String?
  public let sessionId: UUID?

  public var id: String { path }

  public init(
    path: String, added: Int, removed: Int, status: Status? = nil, uncommitted: Bool,
    changedAt: String? = nil, sessionId: UUID? = nil
  ) {
    self.path = path
    self.added = added
    self.removed = removed
    self.status = status
    self.uncommitted = uncommitted
    self.changedAt = changedAt
    self.sessionId = sessionId
  }
}

public struct ServerWorkspaceFileChanges: Codable, Equatable, Sendable {
  public let files: [ServerWorkspaceFileChange]
  public let truncated: Bool

  public init(files: [ServerWorkspaceFileChange], truncated: Bool = false) {
    self.files = files
    self.truncated = truncated
  }
}

extension CodevisorServerClient {
  public func workspaceFiles(workspaceId: UUID) async throws -> ServerWorkspaceFileChanges {
    try await get("/v1/workspaces/\(workspaceId.uuidString)/files")
  }

  public func workspaceMedia(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspaceMediaPage
  {
    do {
      return try await get(try workspaceMediaPath(workspaceId, "media", before: before, limit: limit))
    } catch CodevisorServerClientError.httpStatus(404, _) {
      let page: ServerWorkspacePhotoPage = try await get(
        try workspaceMediaPath(workspaceId, "photos", before: before, limit: limit))
      return ServerWorkspaceMediaPage(media: page.photos, nextBefore: page.nextBefore)
    }
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
  public func workspaceFiles(workspaceId: UUID) async throws -> ServerWorkspaceFileChanges {
    throw CodevisorServerClientError.invalidResponse
  }

  public func workspaceMedia(
    workspaceId: UUID, before: String?, limit: Int
  ) async throws
    -> ServerWorkspaceMediaPage
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
