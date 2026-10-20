import CodevisorCore
import Foundation
import TranscriptKit

@MainActor
final class FileTextPreviews {
  static let shared = FileTextPreviews()

  private let memory: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    cache.countLimit = 64
    cache.totalCostLimit = 16 * 1_024 * 1_024
    return cache
  }()
  private var inFlight: [String: Task<FileTextPreview, Never>] = [:]

  func cached(_ file: PreviewFile, in store: AttachmentImageStore) -> FileTextPreview? {
    memory.object(forKey: key(for: file, in: store) as NSString)?.preview
  }

  func load(_ file: PreviewFile, from store: AttachmentImageStore) async -> FileTextPreview {
    if let cached = cached(file, in: store) { return cached }
    let key = key(for: file, in: store)
    if let task = inFlight[key] { return await task.value }

    let task = Task { await Self.fetch(file, from: store) }
    inFlight[key] = task
    let preview = await task.value
    inFlight[key] = nil
    remember(preview, for: key)
    return preview
  }

  private func remember(_ preview: FileTextPreview, for key: String) {
    guard preview != .unavailable else { return }
    memory.setObject(Box(preview), forKey: key as NSString, cost: preview.byteCost)
  }

  private func key(for file: PreviewFile, in store: AttachmentImageStore) -> String {
    "\(store.namespace):\(file.source.cacheKey)"
  }

  private static func fetch(_ file: PreviewFile, from store: AttachmentImageStore) async -> FileTextPreview {
    let isPatch = file.isPatch
    do {
      let data = try await store.dataPrefix(for: file.source, length: FileTextExcerpt.byteLimit + 1)
      return await Task.detached(priority: .userInitiated) { FileTextPreview(data: data, isPatch: isPatch) }.value
    } catch {
      return isMissingFile(error) ? .missing : .unavailable
    }
  }

  private static func isMissingFile(_ error: any Error) -> Bool {
    guard case let CodevisorServerClientError.httpStatus(status, _) = error else { return false }
    return status == notFoundStatus
  }

  private static let notFoundStatus = 404

  private final class Box {
    let preview: FileTextPreview

    init(_ preview: FileTextPreview) {
      self.preview = preview
    }
  }
}

extension FileTextPreview {
  fileprivate var byteCost: Int {
    switch self {
    case let .text(excerpt): max(1, excerpt.content.utf8.count)
    case .diff: FileTextExcerpt.byteLimit
    case .missing, .binary, .unavailable: 1
    }
  }
}
