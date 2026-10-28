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
    if case let .attachment(fileId) = source, let pending = await attachments.sentPreview(pendingFileID: fileId) {
      return pending
    }
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    switch source {
    case let .attachment(fileId): return try await serverClient.filePreview(id: fileId)
    case let .serverPath(path): return try await serverClient.filePreview(path: path, sessionId: serverSession?.id)
    case .pendingCapture: throw SessionControllerError.fileNotCapturedYet
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
    case .pendingCapture:
      throw SessionControllerError.fileNotCapturedYet
    }
  }

  public func filePrefix(for source: PreviewFile.Source, length: Int) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    switch source {
    case let .attachment(fileId):
      return try await serverClient.filePrefix(id: fileId, length: length)
    case let .serverPath(path):
      guard let sessionId = serverSession?.id else {
        throw SessionControllerError.serverUnavailable
      }
      return try await serverClient.filePrefix(sessionId: sessionId, path: path, length: length)
    case .pendingCapture:
      throw SessionControllerError.fileNotCapturedYet
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
    case .pendingCapture:
      throw SessionControllerError.fileNotCapturedYet
    }
  }

}
