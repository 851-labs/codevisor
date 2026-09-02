import Foundation
import ACPKit
import UniformTypeIdentifiers
import os

extension SessionController {
  // MARK: - Attachments

  static public let maxAttachments = 10
  /// The cloud relay accepts request bodies up to 32 MiB. File uploads use
  /// the attachment bytes as the raw body, so keep the shared staging limit
  /// aligned with that transport boundary.
  static public let maxAttachmentUploadBytes = 32 * 1024 * 1024

  public func attachFileURLs(_ urls: [URL]) {
    for url in urls {
      let id = UUID()
      let metadata = Self.attachmentMetadata(for: url)
      guard
        beginLoadingAttachment(
          id: id,
          name: metadata.name,
          mimeType: metadata.mimeType,
          kind: metadata.kind
        )
      else { continue }
      resolveLoadingAttachment(id: id, fromFileURL: url)
    }
  }

  /// Resolves a placeholder that was inserted as soon as a file URL was
  /// accepted. The bytes are read off the main thread so a large file or
  /// one on a slow network volume does not freeze the run loop.
  public func resolveLoadingAttachment(id: UUID, fromFileURL url: URL) {
    let metadata = Self.attachmentMetadata(for: url)
    guard composerAttachments.contains(where: { $0.id == id && $0.state == .loading }) else {
      return
    }
    Task { [weak self] in
      let result: (data: Data?, readError: String?) = await Task.detached(priority: .userInitiated) {
        do {
          return (try Data(contentsOf: url), nil)
        } catch {
          return (nil, String(describing: error))
        }
      }.value
      guard let self else { return }
      if let data = result.data {
        self.resolveLoadingAttachmentReportingFailure(
          id: id,
          name: metadata.name,
          mimeType: metadata.mimeType,
          kind: metadata.kind,
          data: data
        )
      } else {
        Log.attachments.error(
          "attachment read failed for \(metadata.name, privacy: .public): \(result.readError ?? "unknown", privacy: .public)"
        )
        self.failLoadingAttachment(
          id: id,
          name: metadata.name,
          mimeType: metadata.mimeType,
          kind: metadata.kind,
          message:
            "Couldn't read “\(metadata.name)”. Check that you have permission to open it, then try again."
        )
      }
    }
  }

  private static func attachmentMetadata(
    for url: URL
  ) -> (name: String, mimeType: String, kind: Attachment.Kind) {
    let type = UTType(filenameExtension: url.pathExtension)
    let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    let kind: Attachment.Kind =
      (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
      ? .image
      : .file
    return (url.lastPathComponent, mimeType, kind)
  }

  public func attachImageData(
    _ data: Data,
    suggestedName: String? = nil,
    mimeType: String = "image/png"
  ) {
    let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
    let name =
      suggestedName
      ?? "Pasted image \(Self.pastedImageFormatter.string(from: Date())).\(ext)"
    stageAttachment(name: name, mimeType: mimeType, kind: .image, data: data)
  }

  /// Adds the optimistic row synchronously, before an item provider starts
  /// resolving its bytes. Returns false when the attachment limit is full.
  @discardableResult
  public func beginLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind
  ) -> Bool {
    guard composerAttachments.count < Self.maxAttachments else { return false }
    composerAttachments.append(
      ComposerAttachment(
        id: id,
        name: name,
        mimeType: mimeType,
        kind: kind,
        localData: Data(),
        state: .loading
      )
    )
    return true
  }

  /// Replaces an optimistic placeholder in place, preserving its stable id,
  /// then begins the normal eager upload.
  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    data: Data
  ) -> String? {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
      composerAttachments[index].state == .loading
    else { return nil }
    guard data.count <= Self.maxAttachmentUploadBytes else {
      let message = "“\(name)” is too large to upload. Choose a file smaller than 32 MB."
      discardLoadingAttachment(id: id)
      return message
    }
    var attachment = composerAttachments[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.localData = data
    attachment.state = .uploading
    composerAttachments[index] = attachment
    startUpload(attachment)
    return nil
  }

  /// Resolves a placeholder and surfaces validation failures through the
  /// session status. Native drop targets use this path because they do not
  /// own a separate inline error presentation like the iOS picker does.
  public func resolveLoadingAttachmentReportingFailure(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    data: Data
  ) {
    if let message = resolveLoadingAttachment(
      id: id,
      name: name,
      mimeType: mimeType,
      kind: kind,
      data: data
    ) {
      status = .failed(message)
    }
  }

  /// Provider failures cannot be retried without another paste operation,
  /// so remove the empty placeholder. The platform composer that owns the
  /// paste interaction presents the failure beside that composer instead
  /// of turning it into a session-level connection failure.
  @discardableResult
  public func discardLoadingAttachment(id: UUID) -> Bool {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
      composerAttachments[index].state == .loading
    else { return false }
    composerAttachments.remove(at: index)
    return true
  }

  private func failLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    message: String
  ) {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
      composerAttachments[index].state == .loading
    else { return }
    var attachment = composerAttachments[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.state = .failed(message)
    composerAttachments[index] = attachment
  }

  public func removeAttachment(id: UUID) {
    uploadTasks[id]?.cancel()
    uploadTasks[id] = nil
    composerAttachments.removeAll { $0.id == id }
  }

  public func retryAttachment(id: UUID) {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
      case .failed = composerAttachments[index].state
    else { return }
    composerAttachments[index].state = .uploading
    startUpload(composerAttachments[index])
  }

  /// Fetches stored attachment bytes through this session's server client —
  /// History thumbnails and Quick Look load through here so auth carries
  /// over for remote servers.
  public func fileData(id: String) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    return try await serverClient.fileData(id: id)
  }

  /// Fetches either immutable attachment bytes or a live path from the
  /// machine that owns this session.
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

  private func stageAttachment(
    name: String, mimeType: String, kind: Attachment.Kind, data: Data
  ) {
    guard composerAttachments.count < Self.maxAttachments else {
      status = .failed("A message can carry at most \(Self.maxAttachments) attachments.")
      return
    }
    guard data.count <= Self.maxAttachmentUploadBytes else {
      status = .failed("“\(name)” is too large to upload. Choose a file smaller than 32 MB.")
      return
    }
    let attachment = ComposerAttachment(
      id: UUID(),
      name: name,
      mimeType: mimeType,
      kind: kind,
      localData: data,
      state: .uploading
    )
    composerAttachments.append(attachment)
    startUpload(attachment)
  }

  func startUpload(_ attachment: ComposerAttachment) {
    guard let serverClient else {
      setAttachmentState(attachment.id, .failed("Server unavailable"))
      return
    }
    uploadTasks[attachment.id] = Task { [weak self] in
      do {
        let metadata = try await serverClient.uploadFile(
          name: attachment.name,
          mimeType: attachment.mimeType,
          data: attachment.localData
        )
        guard !Task.isCancelled else { return }
        self?.setAttachmentState(attachment.id, .uploaded(metadata.attachmentRef))
      } catch {
        guard !Task.isCancelled else { return }
        Log.attachments.error(
          "attachment upload failed for \(attachment.name, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        self?.setAttachmentState(attachment.id, .failed(serverErrorMessage(error)))
      }
      self?.uploadTasks[attachment.id] = nil
    }
  }

  private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
    composerAttachments[index].state = state
  }

  /// Waits for in-flight uploads, then returns the attachments to send —
  /// nil (with a surfaced status) if any upload failed.
  func collectAttachmentsForSend() async -> [Attachment]? {
    for task in uploadTasks.values {
      await task.value
    }
    var attachments: [Attachment] = []
    for staged in composerAttachments {
      switch staged.state {
      case let .uploaded(ref):
        attachments.append(ref.attachment)
      case .failed:
        status = .failed("An attachment failed to upload. Retry or remove it, then send again.")
        return nil
      case .uploading:
        // Unreachable: awaiting the tasks above settles every state.
        return nil
      case .loading:
        status = .failed("An attachment is still loading. Wait for it to finish, then send again.")
        return nil
      }
    }
    return attachments
  }

  private static let pastedImageFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()
}
