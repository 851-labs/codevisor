import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingViewerAttempt {
  enum Outcome { case lost, ended(String), cancelled }

  let viewerId: UUID
  let began: ContinuousClock.Instant
  var times: ScreenSharingConnectTimes
  var endpoint: ScreenSharingViewerEndpoint?
  var session: (any ScreenSharingViewingSession)?
  var body: Task<Outcome, Never>?
  var deadline: Task<Void, Never>?
  var notice: String?
  var ready = false
  var started = false
  var outcome: Outcome?
  var transportEnded = false
  private var reportsProgress = false
  private let emit: @Sendable (ScreenSharingViewerEvent) -> Void
  private var settle: ((Outcome) -> Void)?

  init(viewerId: UUID, began: ContinuousClock.Instant, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) {
    self.viewerId = viewerId
    self.began = began
    times = ScreenSharingConnectTimes(at: began)
    self.emit = emit
  }

  var stage: ScreenSharingConnectStage { times.stage }

  func enter(_ stage: ScreenSharingConnectStage, at now: ContinuousClock.Instant) {
    guard stage != times.stage else { return }
    times.enter(stage, at: now)
    if reportsProgress, !ready { emit(.progress(stage)) }
  }

  func reportProgress() {
    reportsProgress = true
    emit(.progress(stage))
  }

  func settle(with continuation: CheckedContinuation<Outcome, Never>) {
    settle = { continuation.resume(returning: $0) }
  }

  func finish(_ outcome: Outcome) {
    let settle = settle
    self.settle = nil
    settle?(outcome)
  }

  func abort(_ outcome: Outcome) {
    if self.outcome == nil { self.outcome = outcome }
    body?.cancel()
    close()
    finish(self.outcome ?? outcome)
  }

  func close() {
    deadline?.cancel()
    session?.onConnectionChanged = nil
    endpoint?.close()
    session?.close()
  }
}
