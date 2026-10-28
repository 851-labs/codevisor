import Foundation
import Observation
import ACPKit
import UniformTypeIdentifiers
import os

@MainActor
@Observable
public final class ComposerAttachments {
  public var items: [ComposerAttachment] { entries.filter { !sentIDs.contains($0.id) } }
  private(set) var entries: [ComposerAttachment] = [] { didSet { onChange() } }
  private var sentIDs: Set<UUID> = [] { didSet { onChange() } }
  @ObservationIgnored private let uploads = AttachmentUploads()
  @ObservationIgnored var loaders: [UUID: ComposerAttachmentLoader] = [:]
  @ObservationIgnored var loads: [UUID: Task<LoadedAttachmentFile, any Error>] = [:]
  @ObservationIgnored let files: ComposerAttachmentFileStore
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

  func clearAfterCollecting() {
    entries = sentEntries
    forgetLoaders(keeping: sentIDs)
  }

  func restore(_ staged: [ComposerAttachment]) {
    entries = sentEntries + staged
    forgetLoaders(keeping: sentIDs.union(staged.map(\.id)))
  }

  func restoreDraft(_ staged: [ComposerAttachment]) {
    entries = sentEntries + staged
    forgetLoaders(keeping: sentIDs.union(staged.map(\.id)))
    for attachment in staged where attachment.state == .uploading {
      uploads.cancel(id: attachment.id)
      startUpload(attachment)
    }
  }

  func prepareRestoredFiles() {
    reuploadAllAttachments()
    for attachment in items { prepareSentPreview(for: attachment) }
  }

  static public let maxAttachments = 10

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

  @discardableResult
  public func resolveLoadingAttachment(id: UUID, fromFileURL url: URL) -> Task<Void, Never> {
    let metadata = AttachmentFileStager.metadata(for: url)
    guard entries.contains(where: { $0.id == id && $0.state == .loading }) else {
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
      self.completeFileStaging(result, id: id, metadata: metadata, limit: limit)
    }
  }

  private func completeFileStaging(
    _ result: AttachmentFileStager.Result,
    id: UUID,
    metadata: (name: String, mimeType: String, kind: Attachment.Kind),
    limit: Int
  ) {
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
      self.reportUnreadableAttachment(id: id, metadata: metadata, readError: readError)
    }
  }

  private func reportUnreadableAttachment(
    id: UUID,
    metadata: (name: String, mimeType: String, kind: Attachment.Kind),
    readError: String
  ) {
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

  public func showLoadingPreview(_ data: Data, for id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].fileURL == nil else { return }
    entries[index].loadingPreviewData = data
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

  public func attachPhotoData(_ data: Data, mimeType: String) {
    let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg"
    attachImageData(
      data, suggestedName: "Photo \(AttachmentFileStager.pastedImageNameDate()).\(ext)", mimeType: mimeType)
  }

  @discardableResult
  public func beginLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind
  ) -> Bool {
    guard items.count < Self.maxAttachments else { return false }
    entries.append(
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

  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    data: Data
  ) -> String? {
    guard entries.contains(where: { $0.id == id && $0.state == .loading }) else {
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

  @discardableResult
  public func resolveLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    stagedFileURL: URL
  ) -> String? {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      files.remove(id: id)
      return nil
    }
    guard entries[index].state == .loading else { return nil }
    let limit = uploadLimitBytes()
    guard let size = ComposerAttachmentFileStore.byteCount(of: stagedFileURL), size <= limit else {
      files.remove(id: id)
      discardLoadingAttachment(id: id)
      return AttachmentFileStager.tooLargeMessage(name: name, limitBytes: limit)
    }
    var attachment = entries[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.fileURL = stagedFileURL
    attachment.state = .uploading
    entries[index] = attachment
    startUpload(attachment)
    prepareSentPreview(for: attachment)
    return nil
  }

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

  func resolveLoadingAttachmentReportingFailure(
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

  @discardableResult
  public func discardLoadingAttachment(id: UUID) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }),
      entries[index].state == .loading
    else { return false }
    entries.remove(at: index)
    return true
  }

  private func failLoadingAttachment(
    id: UUID,
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    message: String
  ) {
    guard let index = entries.firstIndex(where: { $0.id == id }),
      entries[index].state == .loading
    else { return }
    var attachment = entries[index]
    attachment.name = name
    attachment.mimeType = mimeType
    attachment.kind = kind
    attachment.state = .failed(message)
    entries[index] = attachment
  }

  public func removeAttachment(id: UUID) {
    uploads.cancel(id: id)
    loads.removeValue(forKey: id)?.cancel()
    loaders[id] = nil
    entries.removeAll { $0.id == id }
    files.remove(id: id)
  }

  public func retryAttachment(id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }),
      case .failed = entries[index].state
    else { return }
    if entries[index].fileURL == nil, loaders[id] != nil {
      entries[index].state = .loading
      startLoad(id: id)
      return
    }
    guard entries[index].fileURL != nil else { return }
    entries[index].state = .uploading
    startUpload(entries[index])
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

  func reuploadAllAttachments() {
    uploads.cancelAll()
    for index in entries.indices {
      guard entries[index].state != .loading,
        entries[index].fileURL != nil
      else { continue }
      entries[index].state = .uploading
      startUpload(entries[index])
    }
  }

  func setAttachmentState(_ id: UUID, _ state: ComposerAttachment.State) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].state = state
  }

  private func prepareSentPreview(for attachment: ComposerAttachment) {
    guard attachment.isImage, attachment.sentPreviewData == nil, let fileURL = attachment.fileURL
    else { return }
    let id = attachment.id
    Task { [weak self] in
      let preview = await Task.detached(priority: .utility) {
        SentAttachmentPreviews.encodePreview(of: fileURL)
      }.value
      guard let self, let preview,
        let index = self.entries.firstIndex(where: { $0.id == id && $0.fileURL == fileURL })
      else { return }
      self.entries[index].sentPreviewData = preview
    }
  }

  func releaseStagedFiles(of attachments: [ComposerAttachment]) {
    for attachment in attachments {
      files.remove(id: attachment.id)
    }
  }

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
        return nil
      case .loading:
        reportFailure("An attachment is still loading. Wait for it to finish, then send again.")
        return nil
      }
    }
    return attachments
  }
}

extension ComposerAttachments {
  func detachForSend() -> [ComposerAttachment] {
    let sent = items
    sentIDs.formUnion(sent.map(\.id))
    return sent
  }

  func sentAttachments(_ ids: [UUID]) -> [ComposerAttachment] {
    ids.compactMap { id in entries.first { $0.id == id } }
  }

  func releaseSent(_ ids: [UUID]) {
    for id in ids { removeAttachment(id: id) }
    sentIDs.subtract(ids)
  }

  func sentPreview(pendingFileID: String) async -> Data? {
    guard let attachment = entries.first(where: { $0.pendingFileID == pendingFileID }) else { return nil }
    if let preview = attachment.sentPreviewData { return preview }

    guard attachment.isImage, let fileURL = attachment.fileURL else { return nil }
    return await Task.detached(priority: .userInitiated) { SentAttachmentPreviews.encodePreview(of: fileURL) }.value
  }

  private var sentEntries: [ComposerAttachment] {
    entries.filter { sentIDs.contains($0.id) }
  }
}
