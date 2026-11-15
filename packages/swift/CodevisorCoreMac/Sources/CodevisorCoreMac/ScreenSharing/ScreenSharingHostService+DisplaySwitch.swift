import CodevisorClient
import Foundation
import ScreenSharing

extension ScreenSharingHostService {
  static let displayNotConnected = "That display isn't connected to this Mac."
  static let displayNotCaptured = "This Mac couldn't capture that display, so it kept sharing the previous one."

  func sharing(
    _ request: ServerScreenSharingRequest, in session: ScreenSharingHostSession
  ) async -> ScreenSharingHostDisplaySwitch? {
    guard request.session != nil, session.owner.appKey != nil, let wanted = request.displayId else { return nil }

    let pending = session.displaySwitch
    if let pending, pending.target == wanted, pending.isMoving {
      await pending.wait(atMost: displaySwitchWait)
      return pending
    }
    guard wanted != session.display.id || pending?.isMoving == true else { return nil }

    pending?.supersede()
    let change = enqueue(wanted, in: session)
    await change.wait(atMost: displaySwitchWait)
    return change
  }

  func heartbeatReply(
    from session: ScreenSharingHostSession, after change: ScreenSharingHostDisplaySwitch?
  ) -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: session.state, message: session.notice)
    guard let change, session.display.id != change.target else { return reply }

    reply.reason = change.isFinished ? .displayUnavailable : .displaySwitching
    if change.isFinished, let failure = change.failure { reply.message = failure }
    return reply
  }

  private func enqueue(_ wanted: String, in session: ScreenSharingHostSession) -> ScreenSharingHostDisplaySwitch {
    let change = ScreenSharingHostDisplaySwitch(target: wanted)
    let previous = session.resizing
    session.displaySwitch = change
    session.resizing = Task { [weak self, weak session] in
      await previous?.value
      if let self, let session, !change.isSuperseded { await self.perform(change, in: session) }
      change.finish()
    }
    return change
  }

  private func perform(_ change: ScreenSharingHostDisplaySwitch, in session: ScreenSharingHostSession) async {
    guard let available = try? await enumerateDisplays(), current === session, !session.stopping else { return }

    let listed = logicalDisplays.list(available, shared: shared(session))
    guard let target = listed.first(where: { $0.description.id == change.target }) else {
      change.failure = Self.displayNotConnected
      return
    }
    guard target.id != session.captureDisplayID, target.id != session.displayID,
      let next = try? ScreenSharingHostSession.target(target)
    else { return describe(session, among: available) }

    let previous = session.target
    Self.logger.notice("Switching the shared display to \(target.description.name, privacy: .public)")
    do {
      try await move(session, to: next)
    } catch {
      guard current === session, !session.stopping else { return }

      Self.logger.error("Display switch failed: \(error.localizedDescription, privacy: .public); going back")
      change.failure = Self.displayNotCaptured
      do { try await move(session, to: previous) } catch { return await end(session, as: .failed(Self.captureFailed)) }
      return
    }
    session.display = target.description
    session.sharesStandIn = logicalDisplays.kind(target.id) == .standIn
    let shown = (try? await enumerateDisplays()) ?? available
    guard current === session, !session.stopping else { return }

    describe(session, among: shown)
    indicator.setDisplay(session.display.name)
  }

  private func move(_ session: ScreenSharingHostSession, to target: ScreenSharingHostSession.Target) async throws {
    session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 10
    defer { session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 5 }
    session.control?.releaseHeld()
    let showsDesktop = session.virtualDisplay != nil || session.state == "viewing"
    if session.state == "viewing" { try? await session.capture.stop() }
    releaseVirtualDisplay(session)
    session.share(target)
    guard showsDesktop else { return session.peer.updateVideoConfiguration(session.configuration) }

    try await waitForSharedDisplay(session)
    let points = ScreenSharingHostRetina.virtualDisplaySize(
      dynamic: session.dynamicDesktop, shared: session.sharedMode,
      virtualDisplaysAvailable: ScreenSharingHostVirtualDisplay.isAvailable)
    if let points {
      guard try await showVirtualDisplay(session, points: points, standsInForShared: false) != nil else {
        throw CancellationError()
      }
    }
    try await moveCapture(session, movesDisplay: true)
    guard session.dynamicDesktop != nil else { return }

    let size = session.virtualDisplay?.size
    session.peer.channels.display.send(.resized(width: size?.width ?? 0, height: size?.height ?? 0))
  }
}
