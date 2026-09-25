import Foundation
import ACPKit
import ImageIO
import UniformTypeIdentifiers
import os

extension SessionController {
  // MARK: - Attachments

  static public let maxAttachments = 10

  /// The largest attachment the session's machine accepts: what it
  /// advertised on its last status probe, or the limit of servers from
  /// before the field existed.
  public var attachmentUploadLimitBytes: Int {
    machines?.statusByMachineId[project.serverId]?.uploadLimitBytes
      ?? MachineStatus.legacyUploadLimitBytes
  }

  /// Keeps the "is too large to upload" wording: the iOS paste notice
  /// matches on it to show the message verbatim.
  static func attachmentTooLargeMessage(name: String, limitBytes: Int) -> String {
    "“\(name)” is too large to upload. Choose a file smaller than \(formattedUploadLimit(limitBytes))."
  }

  /// Whole binary megabytes, rounded down so "smaller than" stays true.
  /// Deliberately locale-independent, like the rest of this message.
  static func formattedUploadLimit(_ bytes: Int) -> String {
    let mebibyte = 1024 * 1024
    if bytes >= mebibyte { return "\(bytes / mebibyte) MB" }
    return "\(max(1, bytes / 1024)) KB"
  }

  /// Stages each URL as its own attachment. The returned task finishes once
  /// every file has been copied in, so callers holding a security-scoped
  /// URL can release the scope afterwards.
  @discardableResult
  public func attachFileURLs(_ urls: [URL]) -> Task<Void, Never> {
    var resolutions: [Task<Void, Never>] = []
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
      resolutions.append(resolveLoadingAttachment(id: id, fromFileURL: url))
    }
    return Task {
      for resolution in resolutions { await resolution.value }
    }
  }

  private enum FileStagingResult: Sendable {
    case staged(URL)
    case tooLarge
    case unreadable(String)
  }

  /// Resolves a placeholder that was inserted as soon as a file URL was
  /// accepted. The file is copied into the attachment folder off the main
  /// thread, so a large file or one on a slow network volume does not
  /// freeze the run loop. The returned task finishes once the copy has.
  @discardableResult
  public func resolveLoadingAttachment(id: UUID, fromFileURL url: URL) -> Task<Void, Never> {
    let metadata = Self.attachmentMetadata(for: url)
    guard composerAttachments.contains(where: { $0.id == id && $0.state == .loading }) else {
      return Task {}
    }
    let files = attachmentFiles
    let limit = attachmentUploadLimitBytes
    return Task { [weak self] in
      let result: FileStagingResult = await Task.detached(priority: .userInitiated) {
        // Check the size first: a dropped multi-GB video the machine
        // would refuse must not be copied at all.
        if let size = ComposerAttachmentFileStore.byteCount(of: url), size > limit {
          return .tooLarge
        }
        do {
          return .staged(try files.stageCopy(of: url, id: id, name: metadata.name))
        } catch {
          return .unreadable(String(describing: error))
        }
      }.value
      guard let self else {
        files.remove(id: id)
        return
      }
      switch result {
      case let .staged(stagedURL):
        self.resolveLoadingAttachmentReportingFailure(
          id: id,
          name: metadata.name,
          mimeType: metadata.mimeType,
          kind: metadata.kind,
          stagedFileURL: stagedURL
        )
      case .tooLarge:
        guard self.discardLoadingAttachment(id: id) else { return }
        self.status = .failed(Self.attachmentTooLargeMessage(name: metadata.name, limitBytes: limit))
      case let .unreadable(readError):
        Log.attachments.error(
          "attachment read failed for \(metadata.name, privacy: .public): \(readError, privacy: .public)"
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
    let id = UUID()
    guard beginLoadingAttachment(id: id, name: name, mimeType: mimeType, kind: .image) else {
      status = .failed("A message can carry at most \(Self.maxAttachments) attachments.")
      return
    }
    resolveLoadingAttachmentReportingFailure(
      id: id, name: name, mimeType: mimeType, kind: .image, data: data)
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
        state: .loading
      )
    )
    return true
  }

  /// Resolves a placeholder with in-memory bytes (a pasted image): the size
  /// is validated immediately, then the bytes are written into the
  /// attachment folder off the main thread and the eager upload begins.
  /// Returns the failure message when the bytes are too large.
  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    data: Data
  ) -> String? {
    guard composerAttachments.contains(where: { $0.id == id && $0.state == .loading }) else {
      return nil
    }
    let limit = attachmentUploadLimitBytes
    guard data.count <= limit else {
      discardLoadingAttachment(id: id)
      return Self.attachmentTooLargeMessage(name: name, limitBytes: limit)
    }
    let files = attachmentFiles
    Task { [weak self] in
      let stagedURL = await Task.detached(priority: .userInitiated) {
        try? files.stage(data: data, id: id, name: name)
      }.value
      guard let self else {
        files.remove(id: id)
        return
      }
      guard let stagedURL else {
        self.failLoadingAttachment(
          id: id,
          name: name,
          mimeType: mimeType,
          kind: kind,
          message: "Couldn't save “\(name)”. Check that your disk has free space, then try again."
        )
        return
      }
      self.resolveLoadingAttachmentReportingFailure(
        id: id, name: name, mimeType: mimeType, kind: kind, stagedFileURL: stagedURL)
    }
    return nil
  }

  /// Resolves a placeholder with a file already staged in `attachmentFiles`
  /// (the controller takes ownership of it), then begins the eager upload.
  /// Returns the failure message when the file is too large.
  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    stagedFileURL: URL
  ) -> String? {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else {
      // The placeholder was removed while its bytes were arriving.
      attachmentFiles.remove(id: id)
      return nil
    }
    guard composerAttachments[index].state == .loading else { return nil }
    let limit = attachmentUploadLimitBytes
    guard let size = ComposerAttachmentFileStore.byteCount(of: stagedFileURL), size <= limit else {
      attachmentFiles.remove(id: id)
      discardLoadingAttachment(id: id)
      return Self.attachmentTooLargeMessage(name: name, limitBytes: limit)
    }
    var attachment = composerAttachments[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.fileURL = stagedFileURL
    attachment.state = .uploading
    composerAttachments[index] = attachment
    startUpload(attachment)
    prepareSentPreview(for: attachment)
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

  private func resolveLoadingAttachmentReportingFailure(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    stagedFileURL: URL
  ) {
    if let message = resolveLoadingAttachment(
      id: id,
      name: name,
      mimeType: mimeType,
      kind: kind,
      stagedFileURL: stagedFileURL
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
    attachmentFiles.remove(id: id)
  }

  public func retryAttachment(id: UUID) {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }),
      case .failed = composerAttachments[index].state,
      composerAttachments[index].fileURL != nil
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

  func startUpload(_ attachment: ComposerAttachment) {
    guard let serverClient else {
      setAttachmentState(attachment.id, .failed("Server unavailable"))
      return
    }
    guard let fileURL = attachment.fileURL else {
      setAttachmentState(
        attachment.id, .failed("“\(attachment.name)” is no longer available. Remove it and attach it again."))
      return
    }
    // A retarget can move the draft to a machine with a smaller limit;
    // say so before spending the upload on a certain rejection.
    let limit = attachmentUploadLimitBytes
    if let size = ComposerAttachmentFileStore.byteCount(of: fileURL), size > limit {
      setAttachmentState(
        attachment.id, .failed(Self.attachmentTooLargeMessage(name: attachment.name, limitBytes: limit)))
      return
    }
    uploadTasks[attachment.id] = Task { [weak self] in
      do {
        let metadata = try await serverClient.uploadFile(
          name: attachment.name,
          mimeType: attachment.mimeType,
          fileURL: fileURL
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

  /// Discards every server file ref and re-uploads from the staged files the
  /// composer still holds. Server file ids are minted per machine, so this
  /// is required whenever `serverClient` moves to a different machine
  /// (`retarget`); restored drafts also go through here because their refs
  /// are not assumed to survive a relaunch. Placeholders still waiting on
  /// their drop/paste provider are skipped: they upload through whatever
  /// client is current once their bytes resolve. So are placeholders whose
  /// bytes never arrived: there is nothing to upload.
  func reuploadAllAttachments() {
    for task in uploadTasks.values { task.cancel() }
    uploadTasks.removeAll()
    for index in composerAttachments.indices {
      guard composerAttachments[index].state != .loading,
        composerAttachments[index].fileURL != nil
      else { continue }
      composerAttachments[index].state = .uploading
      startUpload(composerAttachments[index])
    }
  }

  private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
    guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
    composerAttachments[index].state = state
  }

  /// Encodes the small preview a sent image shows locally, while the staged
  /// file still exists. The result is dropped if the attachment went away.
  func prepareSentPreview(for attachment: ComposerAttachment) {
    guard attachment.isImage, attachment.sentPreviewData == nil, let fileURL = attachment.fileURL
    else { return }
    let id = attachment.id
    Task { [weak self] in
      let preview = await Task.detached(priority: .utility) {
        SentAttachmentPreviews.encodePreview(of: fileURL)
      }.value
      guard let self, let preview,
        let index = self.composerAttachments.firstIndex(where: { $0.id == id && $0.fileURL == fileURL })
      else { return }
      self.composerAttachments[index].sentPreviewData = preview
    }
  }

  /// Deletes the staged files of attachments whose message went out.
  func releaseStagedFiles(of attachments: [ComposerAttachment]) {
    for attachment in attachments {
      attachmentFiles.remove(id: attachment.id)
    }
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
        if staged.isImage, let preview = staged.sentPreviewData {
          sentAttachmentPreviews.remember(preview, for: ref.fileId)
        }
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

/// Recently sent images, kept on the device that sent them. Attachments are
/// immutable, so a local preview is exactly what the server would return.
@MainActor
final class SentAttachmentPreviews {
  private static let capacity = 8
  /// The preview size the transcript's image store accepts and decodes.
  nonisolated private static let maxPixelSize = 960
  private var entries: [(fileId: String, data: Data)] = []

  func remember(_ preview: Data, for fileId: String) {
    entries.removeAll { $0.fileId == fileId }
    entries.append((fileId, preview))
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
  }

  /// The encoded preview of a sent image, or nil for files this device did
  /// not send.
  func preview(for fileId: String) -> Data? {
    entries.last { $0.fileId == fileId }?.data
  }

  /// A JPEG no larger than the preview size, decoded straight from the
  /// staged file by ImageIO so the full image never has to be in memory.
  nonisolated static func encodePreview(of fileURL: URL) -> Data? {
    guard
      let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
