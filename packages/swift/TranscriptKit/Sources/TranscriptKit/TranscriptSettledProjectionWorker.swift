import Foundation
import MarkdownCore

@MainActor
public final class TranscriptSettledProjectionWorker {
  public struct Output: Sendable {
    public let request: TranscriptProjectionRequest
    public let rows: [TranscriptPresentationRow]
  }

  struct Work: Sendable {
    let request: TranscriptProjectionRequest
    let input: TranscriptProjectionInput
  }

  typealias Projector =
    @Sendable (TranscriptProjectionRequest, TranscriptProjectionInput) async throws -> [TranscriptPresentationRow]

  private let worker: LatestValuePreparationWorker<Work, [TranscriptPresentationRow]>

  public convenience init() {
    self.init { request, input in
      try await TranscriptRowProjectionCache.shared.rows(for: request.key, input: input, options: request.options)
    }
  }

  init(projector: @escaping Projector) {
    worker = LatestValuePreparationWorker { work in
      try await projector(work.request, work.input)
    }
  }

  public func submit(
    _ request: TranscriptProjectionRequest,
    input: TranscriptProjectionInput,
    completion: @escaping @MainActor (Output) -> Void
  ) {
    worker.submit(Work(request: request, input: input)) { work, result in
      if case let .success(rows) = result { completion(Output(request: work.request, rows: rows)) }
    }
  }

  public func cancel() { worker.cancel() }
}
