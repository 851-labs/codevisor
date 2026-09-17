import ACPKit
import Foundation
import Observation

/// Owns one mounted text range. Live revisions coalesce behind its current
/// request, and immutable storage blocks are reused instead of fetched again.
@MainActor @Observable
public final class TranscriptInlineTextModel {
  public private(set) var content: TranscriptInlineTextContent?
  public private(set) var errorMessage: String?
  private var requested: TranscriptInlineTextPage?
  private var task: Task<Void, Never>?
  private var requestID = UUID()
  private var cacheKey = ""
  private var blocks: [Int: ServerTranscriptBodyPage] = [:]

  public init() {}

  public func load(_ page: TranscriptInlineTextPage, using controller: SessionController) {
    load(page) { resource, position in
      try await controller.transcriptBodyPage(resource: resource, field: "text", position: position)
    }
  }

  func load(
    _ page: TranscriptInlineTextPage,
    fetch: @escaping @MainActor (ToolDetailResource, Int) async throws -> ServerTranscriptBodyPage
  ) {
    requested = page
    guard task == nil else { return }
    let request = UUID()
    requestID = request
    task = Task {
      defer { if requestID == request { task = nil } }
      while let target = requested, requestID == request, !Task.isCancelled {
        errorMessage = nil
        let key = "\(target.resource.itemId):\(target.resource.entryKey):\(target.position):\(target.generation)"
        if key != cacheKey {
          cacheKey = key
          blocks.removeAll()
          content = nil
        }
        do {
          let result = try await TranscriptInlineTextContent.load(target) { position in
            if let cached = self.blocks[position], cached.nextPosition != nil { return cached }
            let block = try await fetch(target.resource, position)
            try Task.checkCancellation()
            guard self.requestID == request else { throw CancellationError() }
            self.blocks[position] = block
            return block
          }
          guard requestID == request else { return }
          // A replacement is a new document. Never present an old generation
          // that finished while its replacement was being requested.
          if requested?.generation == target.generation { content = result }
        } catch {
          if isTaskCancellation(error) || requestID != request { return }
          if requested == target { errorMessage = serverErrorMessage(error) }
        }
        if requested == target { break }
      }
    }
  }

  public func cancel() {
    requestID = UUID()
    task?.cancel()
    task = nil
    requested = nil
    blocks.removeAll()
    content = nil
  }
}
