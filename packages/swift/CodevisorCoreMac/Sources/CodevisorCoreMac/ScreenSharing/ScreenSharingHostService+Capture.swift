import CoreGraphics
import Foundation
import ScreenSharing

extension ScreenSharingHostService {
  /// A capture that never delivers is restarted, then `replayd` is (851-2385). Meanwhile the
  /// session reads as connecting, with a notice for the viewer; if nothing helps, the capture
  /// error ends it at the viewer's next heartbeat.
  /// Starts the capture, restarting a wedged `replayd` if the start doesn't return (851-2385).
  /// Every start is logged with `reason`, what it captures and how long it took, so a start that
  /// hangs can be traced to what asked for it (851-2393).
  func startWatchedCapture(_ session: Session, reason: String) async throws {
    let recovery = captureRecovery(session)
    let began = ContinuousClock.now
    let what = "display \(session.captureDisplayID), \(session.configuration.width)×\(session.configuration.height)"
    Self.logger.notice("Capture start (\(reason, privacy: .public)): \(what, privacy: .public)")
    do {
      try await recovery.start { [weak self, weak session] retry in
        guard let self, let session else { throw CancellationError() }
        // The abandoned attempt may still hold the capture's start; stopping clears it.
        if retry {
          Self.logger.notice("Capture start retried on a fresh replayd")
          try? await session.capture.stop()
        }
        try await self.startCapture(session)
      }
      Self.logger.notice("Capture started in \(Self.milliseconds(since: began)) ms (\(reason, privacy: .public))")
    } catch {
      Self.logger.error(
        "Capture start failed after \(Self.milliseconds(since: began)) ms (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  /// The capture a viewer's connection starts, and what it started with.
  func startFirstCapture(
    _ session: Session
  ) async throws -> (display: CGDirectDisplayID, configuration: ScreenSharingVideoConfiguration) {
    let started = (display: session.captureDisplayID, configuration: session.configuration)
    try await startWatchedCapture(session, reason: "viewer connected")
    return started
  }

  /// A resize only moves a capture that's running. One that lands while the first capture is
  /// still starting (on tuftlord a start took 1.1 s) made the virtual display and mirrored onto
  /// it, and the capture then stayed on the old display at the old size: the viewer saw the
  /// desktop cut off and letterboxed. Once the start returns, the capture follows.
  func catchUpWithResize(
    _ session: Session,
    startedWith started: (display: CGDirectDisplayID, configuration: ScreenSharingVideoConfiguration)
  ) async throws {
    if session.captureDisplayID != started.display {
      try? await session.capture.stop()
      try await startWatchedCapture(session, reason: "display changed while starting")
    } else if session.configuration != started.configuration {
      try await session.capture.update(configuration: session.configuration)
    }
  }
}
