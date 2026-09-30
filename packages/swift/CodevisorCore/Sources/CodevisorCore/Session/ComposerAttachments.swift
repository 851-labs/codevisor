import Foundation
import Observation
import ACPKit
import UniformTypeIdentifiers
import os

/// Owns optimistic attachment identity, staged files and eager uploads.
/// The composer observes this collection directly; a session supplies only
/// its current upload destination and presentation callbacks.
@MainActor
@Observable
public final class ComposerAttachments {
  public private(set) var items: [ComposerAttachment] = [] { didSet { onChange() } }
  @ObservationIgnored private let uploads = AttachmentUploads()
  @ObservationIgnored private let files: ComposerAttachmentFileStore
  @ObservationIgnored private let client: () -> (any CodevisorServerClienting)?
  @ObservationIgnored private let uploadLimitBytes: () -> Int
  @ObservationIgnored private let onChange: () -> Void
  @ObservationIgnored private let reportFailure: (String) -> Void
  @ObservationIgnored private let rememberPreview: (Data, String) -> Void

  init(
    files: ComposerAttachmentFileStore,
    client: @escaping () -> (any CodevisorServerClienting)?,
    uploadLimitBytes: @escaping () -> Int,
    onChange: @escaping () -> Void,
    reportFailure: @escaping (String) -> Void,
    rememberPreview: @escaping (Data, String) -> Void
  ) {
    self.files = files
    self.client = client
    self.uploadLimitBytes = uploadLimitBytes
    self.onChange = onChange
    self.reportFailure = reportFailure
    self.rememberPreview = rememberPreview
  }

  /// The accepted-send boundary temporarily removes these rows; setup
  /// failure restores the same snapshot without restarting uploads.
  func clearAfterCollecting() {
    items = []
  }

  func restore(_ staged: [ComposerAttachment]) {
    items = staged
  }

  func prepareRestoredFiles() {
    reuploadAllAttachments()
    for attachment in items { prepareSentPreview(for: attachment) }
  }

  // MARK: - Attachments

  static public let maxAttachments = 10

  /// Stages each URL as its own attachment. The returned task finishes once
  /// every file has been copied in, so callers holding a security-scoped
  /// URL can release the scope afterwards.
  @discardableResult
  public func attachFileURLs(_ urls: [URL]) -> Task<Void, Never> {
    var resolutions: [Task<Void, Never>] = []
    for url in urls {
      let id = UUID()
      let metadata = AttachmentFileStager.metadata(for: url)
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

  /// Resolves a placeholder that was inserted as soon as a file URL was
  /// accepted. The file is copied into the attachment folder off the main
  /// thread, so a large file or one on a slow network volume does not
  /// freeze the run loop. The returned task finishes once the copy has.
  @discardableResult
  public func resolveLoadingAttachment(id: UUID, fromFileURL url: URL) -> Task<Void, Never> {
    let metadata = AttachmentFileStager.metadata(for: url)
    guard items.contains(where: { $0.id == id && $0.state == .loading }) else {
      return Task {}
    }
    let files = files
    let limit = uploadLimitBytes()
    return Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        AttachmentFileStager.stageCopy(of: url, id: id, name: metadata.name, files: files, limitBytes: limit)
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
        self.reportFailure(AttachmentFileStager.tooLargeMessage(name: metadata.name, limitBytes: limit))
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

  public func attachImageData(
    _ data: Data,
    suggestedName: String? = nil,
    mimeType: String = "image/png"
  ) {
    let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
    let name =
      suggestedName
      ?? "Pasted image \(AttachmentFileStager.pastedImageNameDate()).\(ext)"
    let id = UUID()
    guard beginLoadingAttachment(id: id, name: name, mimeType: mimeType, kind: .image) else {
      reportFailure("A message can carry at most \(Self.maxAttachments) attachments.")
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
    guard items.count < Self.maxAttachments else { return false }
    items.append(
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
    guard items.contains(where: { $0.id == id && $0.state == .loading }) else {
      return nil
    }
    let limit = uploadLimitBytes()
    guard data.count <= limit else {
      discardLoadingAttachment(id: id)
      return AttachmentFileStager.tooLargeMessage(name: name, limitBytes: limit)
    }
    let files = files
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

  /// Resolves a placeholder with a file already staged in `files`
  /// (the collection takes ownership of it), then begins the eager upload.
  /// Returns the failure message when the file is too large.
  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    stagedFileURL: URL
  ) -> String? {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      // The placeholder was removed while its bytes were arriving.
      files.remove(id: id)
      return nil
    }
    guard items[index].state == .loading else { return nil }
    let limit = uploadLimitBytes()
    guard let size = ComposerAttachmentFileStore.byteCount(of: stagedFileURL), size <= limit else {
      files.remove(id: id)
      discardLoadingAttachment(id: id)
      return AttachmentFileStager.tooLargeMessage(name: name, limitBytes: limit)
    }
    var attachment = items[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.fileURL = stagedFileURL
    attachment.state = .uploading
    items[index] = attachment
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
      reportFailure(message)
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
      reportFailure(message)
    }
  }

  /// Provider failures cannot be retried without another paste operation,
  /// so remove the empty placeholder. The platform composer that owns the
  /// paste interaction presents the failure beside that composer instead
  /// of turning it into a session-level connection failure.
  @discardableResult
  public func discardLoadingAttachment(id: UUID) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }),
      items[index].state == .loading
    else { return false }
    items.remove(at: index)
    return true
  }

  private func failLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    message: String
  ) {
    guard let index = items.firstIndex(where: { $0.id == id }),
      items[index].state == .loading
    else { return }
    var attachment = items[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.state = .failed(message)
    items[index] = attachment
  }

  public func removeAttachment(id: UUID) {
    uploads.cancel(id: id)
    items.removeAll { $0.id == id }
    files.remove(id: id)
  }

  public func retryAttachment(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }),
      case .failed = items[index].state,
      items[index].fileURL != nil
    else { return }
    items[index].state = .uploading
    startUpload(items[index])
  }

  private func startUpload(_ attachment: ComposerAttachment) {
    guard let serverClient = client() else {
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
    let limit = uploadLimitBytes()
    if let size = ComposerAttachmentFileStore.byteCount(of: fileURL), size > limit {
      setAttachmentState(
        attachment.id, .failed(AttachmentFileStager.tooLargeMessage(name: attachment.name, limitBytes: limit)))
      return
    }
    uploads.start(attachment, client: serverClient, fileURL: fileURL) { [weak self] state in
      self?.setAttachmentState(attachment.id, state)
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
    uploads.cancelAll()
    for index in items.indices {
      guard items[index].state != .loading,
        items[index].fileURL != nil
      else { continue }
      items[index].state = .uploading
      startUpload(items[index])
    }
  }

  private func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].state = state
  }

  /// Encodes the small preview a sent image shows locally, while the staged
  /// file still exists. The result is dropped if the attachment went away.
  private func prepareSentPreview(for attachment: ComposerAttachment) {
    guard attachment.isImage, attachment.sentPreviewData == nil, let fileURL = attachment.fileURL
    else { return }
    let id = attachment.id
    Task { [weak self] in
      let preview = await Task.detached(priority: .utility) {
        SentAttachmentPreviews.encodePreview(of: fileURL)
      }.value
      guard let self, let preview,
        let index = self.items.firstIndex(where: { $0.id == id && $0.fileURL == fileURL })
      else { return }
      self.items[index].sentPreviewData = preview
    }
  }

  /// Deletes the staged files of attachments whose message went out.
  func releaseStagedFiles(of attachments: [ComposerAttachment]) {
    for attachment in attachments {
      files.remove(id: attachment.id)
    }
  }

  /// Waits for in-flight uploads, then returns the attachments to send —
  /// nil (with a surfaced status) if any upload failed.
  func collectAttachmentsForSend() async -> [Attachment]? {
    await uploads.waitForCurrentUploads()
    var attachments: [Attachment] = []
    for staged in items {
      switch staged.state {
      case let .uploaded(ref):
        attachments.append(ref.attachment)
        if staged.isImage, let preview = staged.sentPreviewData {
          rememberPreview(preview, ref.fileId)
        }
      case .failed:
        reportFailure("An attachment failed to upload. Retry or remove it, then send again.")
        return nil
      case .uploading:
        // Unreachable: awaiting the tasks above settles every state.
        return nil
      case .loading:
        reportFailure("An attachment is still loading. Wait for it to finish, then send again.")
        return nil
      }
    }
    return attachments
  }
}
