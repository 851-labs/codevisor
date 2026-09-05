import CodevisorCore
import Foundation
import Observation
import StreamMarkdown

/// A document lives as long as its pane, independently of SwiftUI mounts.
/// Revalidation keeps the last parsed contents visible while reading the file.
@MainActor
@Observable
public final class MarkdownDocumentModel {
  struct Content: Sendable {
    let text: String
    let blocks: [MarkdownBlock]
  }

  public let path: String
  private(set) var content: Content?
  private(set) var failure: MarkdownDocumentFailure?
  private(set) var showsLoadingProgress = false
  private(set) var isLoading = false
  @ObservationIgnored private let fetch: @Sendable () async throws -> Data
  @ObservationIgnored private let waitForProgress: @Sendable () async throws -> Void
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored var progressTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  public convenience init(path: String, sessionId: UUID, client: any CodevisorServerClienting) {
    self.init(path: path, fetch: { try await client.fileData(sessionId: sessionId, path: path) })
  }

  init(
    path: String,
    fetch: @escaping @Sendable () async throws -> Data,
    waitForProgress: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(800))
    }
  ) {
    self.path = path
    self.fetch = fetch
    self.waitForProgress = waitForProgress
  }

  deinit {
    loadTask?.cancel()
    progressTask?.cancel()
  }

  /// Concurrent callers share one read. Unchanged files keep their existing
  /// parsed blocks, so switching tabs does not reset the rendered content.
  @discardableResult
  public func refresh() -> Task<Void, Never> {
    if let loadTask { return loadTask }
    generation &+= 1
    let generation = generation
    let previousText = content?.text
    let fetch = fetch
    let waitForProgress = waitForProgress
    failure = nil
    isLoading = true
    showsLoadingProgress = false
    if content == nil {
      progressTask = Task { [weak self] in
        do {
          try await waitForProgress()
          guard !Task.isCancelled, let self, self.generation == generation,
            self.isLoading, self.content == nil
          else { return }
          self.showsLoadingProgress = true
        } catch {}
      }
    }
    let task = Task { [weak self] in
      defer {
        if let self, self.generation == generation {
          self.progressTask?.cancel()
          self.progressTask = nil
          self.showsLoadingProgress = false
          self.isLoading = false
          self.loadTask = nil
        }
      }
      do {
        let data = try await fetch()
        try Task.checkCancellation()
        let updated = try await Task.detached(priority: .userInitiated) {
          guard let text = String(data: data, encoding: .utf8) else {
            throw MarkdownDocumentLoadError.unsupportedEncoding
          }
          guard text != previousText else { return nil as Content? }
          return Content(text: text, blocks: MarkdownParser().parse(text))
        }.value
        guard !Task.isCancelled, let self, self.generation == generation else { return }
        if let updated { self.content = updated }
      } catch {
        guard !Task.isCancelled, !isTaskCancellation(error), let self,
          self.generation == generation
        else { return }
        self.failure = MarkdownDocumentFailure(error: error, path: self.path)
      }
    }
    loadTask = task
    return task
  }

  /// Leaving a tab cancels unfinished work without discarding the document.
  /// The generation also rejects responses from transports that ignore cancellation.
  public func cancelLoading() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    progressTask?.cancel()
    progressTask = nil
    showsLoadingProgress = false
    isLoading = false
  }
}
