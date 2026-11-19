import CoreGraphics
import Foundation
import ScreenSharing

extension ScreenSharingHostService {
  func startWatchedCapture(_ session: ScreenSharingHostSession, reason: String) async throws {
    let recovery = captureRecovery(session)
    let began = ContinuousClock.now
    let what = "display \(session.captureDisplayID), \(session.configuration.width)×\(session.configuration.height)"
    Self.logger.notice("Capture start (\(reason, privacy: .public)): \(what, privacy: .public)")
    do {
      try await recovery.start { [weak self, weak session] retry in
        guard let self, let session else { throw CancellationError() }
        if retry {
          Self.logger.notice("Capture start retried on a fresh replayd")
          try? await session.capture.stop()
        }
        try await self.startCapture(session)
      }
      Self.logger.notice("Capture started in \(Self.milliseconds(since: began)) ms (\(reason, privacy: .public))")
    } catch {
      Self.logger.error(
        "Capture start failed after \(Self.milliseconds(since: began)) ms (\(reason, privacy: .public), \(ScreenSharingHostFailure(error).code, privacy: .public)): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  func restartFailed(_ session: ScreenSharingHostSession, _ error: any Error) async {
    let failure = ScreenSharingHostFailure(error)
    Self.logger.error(
      "Capture restart failed (\(failure.code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
    guard failure.isRefusedCapture else {
      session.captureFailure = "The host Mac's screen capture stopped and couldn't be restarted."
      return
    }

    await end(session, as: .captureRefused)
  }

  static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  static func startCaptureStream(of session: ScreenSharingHostSession) async throws {
    try await session.capture.start(
      displayID: session.captureDisplayID, configuration: session.configuration, sink: session.peer.frameSink,
      metrics: session.metrics)
  }

  func startCapture(_ session: ScreenSharingHostSession) async throws {
    session.capturing = (session.captureDisplayID, session.configuration)
    session.captureGeneration += 1
    if session.hdr.viewerSupports { await applyDynamicRange(session).value }
    if let format = session.peer.capturePixelFormat { session.capture.pixelFormat = format }
    try await startsCapture(session)
  }

  func reconcileCapture(_ session: ScreenSharingHostSession) async throws {
    while true {
      await session.capture.settled()
      guard let capturing = session.capturing else { return }
      if session.captureDisplayID != capturing.display {
        try? await session.capture.stop()
        try await startWatchedCapture(session, reason: "display changed while starting")
      } else if session.configuration != capturing.configuration {
        let configuration = session.configuration
        try await session.capture.update(configuration: configuration)
        session.capturing?.configuration = configuration
        Self.logger.notice("Capture resized to \(configuration.width)×\(configuration.height) while starting")
      } else {
        return
      }
    }
  }
}

extension ScreenSharingHostService {
  static let displaySettleAttempts = 10
  static let displaySettleInterval: Duration = .milliseconds(300)

  @discardableResult
  func followDisplay(_ session: ScreenSharingHostSession) -> Bool {
    switch successor(of: session) {
    case .another, .none: return false
    case .unchanged: break
    case .renumbered(let current):
      Self.logger.notice("Shared display \(session.displayID) is now display \(current)")
      session.displayID = current
      session.sharedMode = .init(display: current)
    }
    noteSharedDisplaySize(session)
    return true
  }

  func restartOnSettledDisplay(_ session: ScreenSharingHostSession) async throws {
    var lastError: (any Error)?
    for attempt in 0..<Self.displaySettleAttempts {
      if attempt > 0 { try await Task.sleep(for: Self.displaySettleInterval) }
      guard !session.stopping, !Task.isCancelled else { throw CancellationError() }
      if followsToAnotherDisplay(session) { await session.displayFollow?.value }
      guard !session.stopping, !Task.isCancelled else { throw CancellationError() }
      guard followDisplay(session) else { continue }
      do {
        try await startWatchedCapture(
          session, reason: attempt == 0 ? "capture stopped" : "capture stopped, retry \(attempt)")
        return
      } catch let error as ScreenSharingError {
        guard case .unavailable = error else { throw error }
        lastError = error
        try? await session.capture.stop()
      }
    }
    throw lastError ?? ScreenSharingError.unavailable("The shared display didn't come back.")
  }
}
