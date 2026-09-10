import Foundation
import MarkdownCore

/// Serializes live-row projection with the same bounded preparation queue
/// used by native content layout. New input replaces only waiting work, so
/// continuous streaming cannot starve presentation.
@MainActor
public final class TranscriptActiveProjectionWorker {
  public struct Request: Equatable, Sendable {
    public let revision: UInt64
    public let projectedID: UUID
    public let item: ConversationItem
    public let waitingOnBackgroundTask: String?

    public init(
      revision: UInt64,
      projectedID: UUID,
      item: ConversationItem,
      waitingOnBackgroundTask: String?
    ) {
      self.revision = revision
      self.projectedID = projectedID
      self.item = item
      self.waitingOnBackgroundTask = waitingOnBackgroundTask
    }
  }

  public struct Output: Sendable {
    public let request: Request
    public let rows: [TranscriptPresentationRow]
  }

  typealias Projector = @Sendable (ConversationItem, String?) -> [TranscriptPresentationRow]

  private let worker: LatestValuePreparationWorker<Request, [TranscriptPresentationRow]>

  public convenience init() {
    self.init { item, waiting in
      TranscriptActiveRowProjection.rows(for: item, waitingOnBackgroundTask: waiting)
    }
  }

  init(projector: @escaping Projector) {
    worker = LatestValuePreparationWorker { request in
      projector(request.item, request.waitingOnBackgroundTask)
    }
  }

  public func submit(_ request: Request, completion: @escaping @MainActor (Output) -> Void) {
    worker.submit(request) { request, result in
      if case let .success(rows) = result { completion(Output(request: request, rows: rows)) }
    }
  }

  public func cancel() { worker.cancel() }
}
