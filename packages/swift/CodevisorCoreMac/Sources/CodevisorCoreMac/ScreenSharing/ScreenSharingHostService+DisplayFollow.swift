import CodevisorClient
import CoreGraphics
import Foundation
import ScreenSharing

extension ScreenSharingHostService {
  func successor(of session: ScreenSharingHostSession) -> ScreenSharingDisplayIdentity.Successor {
    ScreenSharingDisplayIdentity.successor(
      of: session.displayID, identity: session.displayIdentity, pixels: session.displayPixels,
      online: onlineDisplays())
  }

  func identity(of display: CGDirectDisplayID) -> ScreenSharingDisplayIdentity? {
    onlineDisplays().first { $0.id == display }?.identity
  }

  func noteSharedDisplaySize(_ session: ScreenSharingHostSession) {
    guard let shared = onlineDisplays().first(where: { $0.id == session.displayID }), !shared.isVirtual,
      let pixels = shared.pixels
    else { return }

    session.displayPixels = pixels
  }

  @discardableResult
  func followsToAnotherDisplay(_ session: ScreenSharingHostSession) -> Bool {
    if session.displayFollow != nil { return true }
    guard case .another = successor(of: session) else { return false }

    let previous = session.resizing
    let follow = Task { [weak self, weak session] in
      await previous?.value
      if let self, let session { await self.moveToRemainingDisplay(session) }
      session?.displayFollow = nil
      if let self, let session { self.restartCaptureLeftStopped(session) }
    }
    session.displayFollow = follow
    session.resizing = follow
    return true
  }

  func moveToRemainingDisplay(_ session: ScreenSharingHostSession) async {
    do {
      guard let remaining = try await remainingDisplay(for: session) else { return }

      Self.logger.notice(
        "The shared display went away; moving to \(remaining.description.name, privacy: .public)")
      try await move(
        session, to: try ScreenSharingHostSession.target(remaining, identity: identity(of: remaining.id)))
      session.display = remaining.description
      session.sharesStandIn = logicalDisplays.kind(remaining.id) == .standIn
      let shown = (try? await enumerateDisplays()) ?? [remaining]
      guard current === session, !session.stopping else { return }

      describe(session, among: shown)
      indicator.setDisplay(session.display.name)
    } catch {
      guard current === session, !session.stopping, !Task.isCancelled else { return }

      Self.logger.error(
        "Moving to the remaining display failed: \(error.localizedDescription, privacy: .public)")
      await end(session, as: .captureFailed(ScreenSharingHostFailure(error)))
    }
  }

  private func remainingDisplay(for session: ScreenSharingHostSession) async throws -> Display? {
    for attempt in 0..<Self.displaySettleAttempts {
      if attempt > 0 { try await Task.sleep(for: Self.displaySettleInterval) }
      guard current === session, !session.stopping, !Task.isCancelled else { return nil }
      guard case .another(let id) = successor(of: session) else { return nil }

      guard let available = try? await enumerateDisplays() else { continue }
      guard current === session, !session.stopping else { return nil }
      let listed = logicalDisplays.list(available, shared: shared(session))
      if let remaining = listed.first(where: { $0.id == id }) { return remaining }
    }
    throw ScreenSharingError.unavailable("The remaining display wasn't listed.")
  }
}

extension ScreenSharingHostService {
  func captureStopped(_ session: ScreenSharingHostSession, message: String) {
    guard current === session, !session.stopping else { return }
    if leavesCaptureToDisplayFollow(session, stopped: message) { return }
    guard mayBeLosingItsDisplay(session) else { return restartCapture(session, after: message) }

    let generation = session.captureGeneration
    let pending = session.captureTask
    pending?.cancel()
    session.captureTask = Task { [weak self, weak session] in
      await pending?.value
      try? await Task.sleep(for: self?.displayListCatchUp ?? .zero)
      guard let self, let session, self.current === session, !session.stopping, !Task.isCancelled else { return }
      guard session.captureGeneration == generation else { return }
      if self.leavesCaptureToDisplayFollow(session, stopped: message) { return }

      self.restartCapture(session, after: message)
    }
  }

  private func mayBeLosingItsDisplay(_ session: ScreenSharingHostSession) -> Bool {
    session.state == "viewing" && onlineDisplays().count(where: { !$0.isVirtual }) > 1
  }

  private func leavesCaptureToDisplayFollow(_ session: ScreenSharingHostSession, stopped message: String) -> Bool {
    guard session.state == "viewing", followsToAnotherDisplay(session) else { return false }

    Self.logger.notice("Capture stopped (\(message, privacy: .public)); its display went away")
    session.captureStopLeftToFollow = (message, session.captureGeneration)
    return true
  }

  private func restartCaptureLeftStopped(_ session: ScreenSharingHostSession) {
    guard let stop = session.captureStopLeftToFollow else { return }

    session.captureStopLeftToFollow = nil
    guard current === session, !session.stopping, session.state == "viewing" else { return }
    guard stop.generation == session.captureGeneration else { return }

    Self.logger.notice("The move to another display ended with the capture stopped; restarting it")
    captureStopped(session, message: stop.message)
  }
}
