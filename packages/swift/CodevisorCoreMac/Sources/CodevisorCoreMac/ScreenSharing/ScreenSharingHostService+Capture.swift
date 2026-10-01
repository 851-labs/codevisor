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
  func startWatchedCapture(_ session: ScreenSharingHostSession, reason: String) async throws {
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

  func startCapture(_ session: ScreenSharingHostSession) async throws {
    session.capturing = (session.captureDisplayID, session.configuration)
    // The display may have changed (a virtual display has no HDR headroom): the range follows it
    // before the stream starts, so its first frames are already in the right format.
    if session.hdr.viewerSupports { await applyDynamicRange(session).value }
    try await session.capture.start(
      displayID: session.captureDisplayID, configuration: session.configuration,
      sink: session.peer.frameSender, metrics: session.metrics)
  }

  /// Brings the capture to the session's current display and size before the session reads as
  /// viewing. A resize only moves a capture that's viewing; one that lands while the first capture
  /// is starting, or while this catches up with an earlier one, would otherwise be lost. On
  /// tuftlord (alpha 1112) a second pane size arrived during the catch-up of #165: the capture kept
  /// 1920×1416 while the sender expected 1920×1356 and dropped all 40,864 frames, a frozen picture
  /// with no error. This loops until nothing differs; the caller marks the session viewing with no
  /// suspension in between, so a later resize sees it viewing and applies itself.
  func reconcileCapture(_ session: ScreenSharingHostSession) async throws {
    while true {
      // The audio subscription may be restarting the stream right now (it waited for the same start).
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
  /// How long a capture restart waits for the display set to settle, and how often it looks.
  static let displaySettleAttempts = 10
  static let displaySettleInterval: Duration = .milliseconds(300)

  /// Points the session at its display's current ID when macOS renumbered it. Returns false when
  /// there is no display to follow yet (the display set is mid-change).
  @discardableResult
  func followDisplay(_ session: ScreenSharingHostSession) -> Bool {
    guard
      let current = ScreenSharingDisplayIdentity.follow(
        session.displayID, identity: session.displayIdentity, online: ScreenSharingDisplayIdentity.online())
    else { return false }
    guard current != session.displayID else { return true }
    Self.logger.notice("Shared display \(session.displayID) is now display \(current)")
    session.displayID = current
    session.injector = ScreenSharingInputInjector(displayBounds: CGDisplayBounds(current))
    return true
  }

  /// A capture restart after the display set changed (a virtual display appearing or going, a
  /// mirror ending): macOS may briefly list no display, or renumber the shared one. Follow it and
  /// retry for a few seconds before giving up.
  func restartOnSettledDisplay(_ session: ScreenSharingHostSession) async throws {
    var lastError: (any Error)?
    for attempt in 0..<Self.displaySettleAttempts {
      if attempt > 0 { try await Task.sleep(for: Self.displaySettleInterval) }
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
