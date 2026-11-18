import CodevisorClient
import Foundation
import ScreenSharing

extension ScreenSharingHostService {
  func successor(of session: ScreenSharingHostSession) -> ScreenSharingDisplayIdentity.Successor {
    ScreenSharingDisplayIdentity.successor(
      of: session.displayID, identity: session.displayIdentity, pixels: session.displayPixels,
      online: onlineDisplays())
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
      try await move(session, to: try ScreenSharingHostSession.target(remaining))
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
