import Foundation

extension SessionController {
  /// Fetches stored attachment bytes through this session's server client —
  /// History thumbnails and Quick Look load through here so auth carries
  /// over for remote servers.
  public func fileData(id: String) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    return try await serverClient.fileData(id: id)
  }

  /// Fetches either immutable attachment bytes or a live path from the
  /// machine that owns this session.
  public func filePreview(for source: PreviewFile.Source) async throws -> Data {
    if case let .attachment(fileId) = source, let local = sentAttachmentPreviews.preview(for: fileId) {
      return local
    }
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    switch source {
    case let .attachment(fileId): return try await serverClient.filePreview(id: fileId)
    case let .serverPath(path): return try await serverClient.filePreview(path: path, sessionId: serverSession?.id)
    }
  }

  public func fileData(for source: PreviewFile.Source) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    switch source {
    case let .attachment(fileId):
      return try await serverClient.fileData(id: fileId)
    case let .serverPath(path):
      guard let sessionId = serverSession?.id else {
        throw SessionControllerError.serverUnavailable
      }
      return try await serverClient.fileData(sessionId: sessionId, path: path)
    }
  }

  /// Namespaces device-local preview caches by both the machine and the
  /// authoritative cwd. A relative path in two worktrees must never collide.
  public var previewCacheNamespace: String {
    "\(project.serverId):\(sessionCwdURL.standardizedFileURL.path)"
  }

  /// Immutable attachments are versioned by id. Live paths use the server's
  /// HEAD validator so a same-named file can replace an older thumbnail.
  public func fileVersion(for source: PreviewFile.Source) async throws -> String? {
    switch source {
    case let .attachment(fileId):
      return "attachment:\(fileId)"
    case let .serverPath(path):
      guard let serverClient, let sessionId = serverSession?.id else {
        throw SessionControllerError.serverUnavailable
      }
      return try await serverClient.fileVersion(sessionId: sessionId, path: path)
    }
  }

}
