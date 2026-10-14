import Foundation

extension SessionController {
  public func fileData(id: String) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    return try await serverClient.fileData(id: id)
  }

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

  public var previewCacheNamespace: String {
    "\(project.serverId):\(sessionCwdURL.standardizedFileURL.path)"
  }

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
