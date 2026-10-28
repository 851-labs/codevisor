import ACPKit
import Foundation
import os

public struct LoadedAttachmentFile: Sendable, Equatable {
  public var fileURL: URL
  public var name: String
  public var mimeType: String
  public var kind: Attachment.Kind

  public init(fileURL: URL, name: String, mimeType: String, kind: Attachment.Kind) {
    self.fileURL = fileURL
    self.name = name
    self.mimeType = mimeType
    self.kind = kind
  }
}

public typealias ComposerAttachmentLoader =
  @Sendable (UUID, ComposerAttachmentFileStore) async throws -> LoadedAttachmentFile

extension ComposerAttachments {
  @discardableResult
  public func attachLoading(
    name: String,
    mimeType: String,
    kind: Attachment.Kind,
    load: @escaping ComposerAttachmentLoader
  ) -> UUID? {
    let id = UUID()
    guard beginLoadingAttachment(id: id, name: name, mimeType: mimeType, kind: kind) else {
      return nil
    }
    loaders[id] = load
    startLoad(id: id)
    return id
  }

  func startLoad(id: UUID) {
    guard let load = loaders[id] else { return }
    let files = files
    let work = Task.detached(priority: .userInitiated) { try await load(id, files) }
    loads[id] = work
    Task { [weak self] in
      let result = await work.result
      guard let self else {
        files.remove(id: id)
        return
      }
      guard self.loads[id] == work else {
        if !self.entries.contains(where: { $0.id == id }) { files.remove(id: id) }
        return
      }
      self.loads[id] = nil
      self.completeLoad(result, id: id)
    }
  }

  private func completeLoad(_ result: Result<LoadedAttachmentFile, any Error>, id: UUID) {
    switch result {
    case let .success(loaded):
      guard entries.contains(where: { $0.id == id && $0.state == .loading }) else {
        files.remove(id: id)
        loaders[id] = nil
        return
      }
      loaders[id] = nil
      resolveLoadingAttachmentReportingFailure(
        id: id,
        name: loaded.name,
        mimeType: loaded.mimeType,
        kind: loaded.kind,
        stagedFileURL: loaded.fileURL
      )
    case let .failure(error):
      files.remove(id: id)
      guard let attachment = entries.first(where: { $0.id == id && $0.state == .loading }) else {
        loaders[id] = nil
        return
      }
      Log.attachments.error(
        "attachment load failed for \(attachment.name, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      setAttachmentState(
        id, .failed("Couldn't load “\(attachment.name)”. Retry, or remove it and attach it again."))
    }
  }

  func forgetLoaders(keeping ids: Set<UUID>) {
    for id in Set(loaders.keys).union(loads.keys) where !ids.contains(id) {
      loads.removeValue(forKey: id)?.cancel()
      loaders[id] = nil
    }
  }
}
