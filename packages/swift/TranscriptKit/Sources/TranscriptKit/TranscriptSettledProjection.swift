import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptSettledProjection {
  public private(set) var rows: [TranscriptPresentationRow] = []
  public private(set) var rowsVersion: UInt64 = 0
  public private(set) var publication = TranscriptProjectionPublicationState()

  @ObservationIgnored private var sessionID: UUID?
  @ObservationIgnored private let worker: TranscriptSettledProjectionWorker

  public convenience init() {
    self.init(worker: TranscriptSettledProjectionWorker())
  }

  init(worker: TranscriptSettledProjectionWorker) {
    self.worker = worker
  }

  public func isPending(currentRequest: TranscriptProjectionRequest) -> Bool {
    publication.isPending(currentRequest: currentRequest)
  }

  public func submit(_ request: TranscriptProjectionRequest, input: TranscriptProjectionInput) {
    if sessionID != request.key.sessionID {
      clear(for: request.key.sessionID)
    } else if publication.publishedRequest == request {
      worker.cancel()
      return
    }
    worker.submit(request, input: input) { [weak self] output in
      self?.publish(output)
    }
  }

  private func clear(for sessionID: UUID) {
    self.sessionID = sessionID
    guard publication.publishedRequest != nil else { return }

    rows = []
    rowsVersion &+= 1
    publication.reset()
  }

  private func publish(_ output: TranscriptSettledProjectionWorker.Output) {
    guard output.request.key.sessionID == sessionID else { return }

    rows = output.rows
    rowsVersion &+= 1
    publication.publish(output.request)
  }
}
