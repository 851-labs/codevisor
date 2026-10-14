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
    if session.hdr.viewerSupports { await applyDynamicRange(session).value }
    try await session.capture.start(
      displayID: session.captureDisplayID, configuration: session.configuration,
      sink: session.peer.frameSender, metrics: session.metrics)
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
