import AppKit
import ScreenSharing

extension ScreenSharingHostService {
  func configureDisplay(_ session: ScreenSharingHostSession) {
    let channel = session.peer.channels.display
    channel.onAvailabilityChanged = { [weak channel] available in
      guard available, let channel else { return }
      channel.send(
        ScreenSharingHostVirtualDisplay.isAvailable ? .ready : .unavailable("This Mac can't create a virtual display."))
    }
    channel.onMessage = { [weak self, weak session] message in
      guard let self, let session, !session.stopping else { return }
      switch message {
      case .resize(let width, let height): self.scheduleResize(session, to: (width, height))
      case .restore: self.scheduleResize(session, to: nil)
      case .ready, .resized, .unavailable: return
      }
    }
  }

  static func waitForDisplay(_ display: CGDirectDisplayID, pixels: (width: Int, height: Int)) async throws {
    for _ in 0..<100 {
      guard let mode = CGDisplayCopyDisplayMode(display),
        mode.pixelWidth != pixels.width || mode.pixelHeight != pixels.height
      else { return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func waitForSharedDisplay(_ session: ScreenSharingHostSession) async throws {
    for _ in 0..<150 {
      if followDisplay(session), CGDisplayIsInMirrorSet(session.displayID) == 0 {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func scheduleResize(_ session: ScreenSharingHostSession, to size: (width: Int, height: Int)?) {
    session.pendingResize?.cancel()
    session.pendingResize = Task { [weak self, weak session] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, let session, !session.stopping else { return }
      await session.resizing?.value
      guard !Task.isCancelled, !session.stopping else { return }
      session.dynamicDesktop = size
      await self.updateDisplay(session, reportsFailure: true)
    }
  }

  func updateDisplay(_ session: ScreenSharingHostSession, reportsFailure: Bool = false) async {
    let previous = session.resizing
    let update = Task { [weak self, weak session] in
      await previous?.value
      guard let self, let session, !session.stopping, !Task.isCancelled else { return }
      await self.applyDisplay(session, reportsFailure: reportsFailure)
    }
    session.resizing = update
    await update.value
  }

  private func applyDisplay(_ session: ScreenSharingHostSession, reportsFailure: Bool) async {
    let channel = session.peer.channels.display
    followDisplay(session)
    let points = ScreenSharingHostRetina.virtualDisplaySize(
      dynamic: session.dynamicDesktop, shared: session.sharedMode,
      virtualDisplaysAvailable: ScreenSharingHostVirtualDisplay.isAvailable)
    let standsInForShared = session.virtualDisplayStandsInForShared
    switch (session.virtualDisplay?.size, points) {
    case (nil, nil): return
    case (let size?, let points?) where size == points && standsInForShared:
      channel.send(.resized(width: size.width, height: size.height))
      return
    default: break
    }
    session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 10
    defer { session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 5 }
    do {
      guard
        let movesDisplay = try await showVirtualDisplay(session, points: points, standsInForShared: standsInForShared)
      else { return }
      try await moveCapture(session, movesDisplay: movesDisplay)
      let size = session.virtualDisplay?.size
      session.metrics.label(
        "displaySize",
        size.map { "virtual \($0.width)×\($0.height) pt @2x" }
          ?? "physical, scaled to \(session.configuration.width) px")
      channel.send(.resized(width: size?.width ?? 0, height: size?.height ?? 0))
    } catch is CancellationError {
      return
    } catch let kept as ScreenSharingHostVirtualDisplay.KeptSize {
      Self.logger.error(
        "Display resize failed; kept \(kept.size.width)×\(kept.size.height) pt: \(kept.reason, privacy: .public)")
      channel.send(.resized(width: kept.size.width, height: kept.size.height))
    } catch {
      Self.logger.error("Display change failed: \(error.localizedDescription, privacy: .public)")
      session.metrics.label("displaySize", error.localizedDescription)
      if session.virtualDisplay == nil { try? await waitForSharedDisplay(session) }
      if reportsFailure { channel.send(.unavailable(error.localizedDescription)) }
    }
  }

  private func showVirtualDisplay(
    _ session: ScreenSharingHostSession, points: (width: Int, height: Int)?, standsInForShared: Bool
  ) async throws -> Bool? {
    guard let points else {
      releaseVirtualDisplay(session)
      return true
    }
    let configuration = try session.peer.captureConfiguration(width: points.width * 2, height: points.height * 2)
    if let current = session.virtualDisplay, standsInForShared {
      try await current.resize(width: points.width, height: points.height)
      session.configuration = configuration
      return false
    }
    releaseVirtualDisplay(session)
    let display = try ScreenSharingHostVirtualDisplay(
      width: points.width, height: points.height, standingInFor: session.displayID,
      mirrors: !session.sharedMode.isHeadless)
    try await display.show()
    guard !session.stopping else {
      display.release()
      return nil
    }
    session.virtualDisplay = display
    if display.replacesShared { session.displayID = display.displayID }
    session.configuration = configuration
    return true
  }

  private func moveCapture(_ session: ScreenSharingHostSession, movesDisplay: Bool) async throws {
    if session.virtualDisplay != nil {
      try await Self.waitForDisplay(
        session.captureDisplayID, pixels: (session.configuration.width, session.configuration.height))
    } else {
      try await waitForSharedDisplay(session)
    }
    guard !session.stopping else { throw CancellationError() }
    session.peer.updateVideoConfiguration(session.configuration)
    guard session.state == "viewing" else { return }
    if movesDisplay {
      try? await session.capture.stop()
      try await startWatchedCapture(
        session, reason: session.virtualDisplay == nil ? "physical display restored" : "moved to virtual display")
      return
    }
    let began = ContinuousClock.now
    try await session.capture.update(configuration: session.configuration)
    session.capturing?.configuration = session.configuration
    Self.logger.notice(
      "Capture resized to \(session.configuration.width)×\(session.configuration.height) in \(Self.milliseconds(since: began)) ms"
    )
  }

  private func releaseVirtualDisplay(_ session: ScreenSharingHostSession) {
    guard let display = session.virtualDisplay else { return }
    display.release()
    session.virtualDisplay = nil
    session.configuration = session.physicalConfiguration
  }
}

extension ScreenSharingHostService {
  func screenParametersChanged() {
    guard let current else { return }
    if ProcessInfo.processInfo.systemUptime < current.ownDisplayChangeUntil { return }
    let online = ScreenSharingDisplayIdentity.online()
    guard
      ScreenSharingDisplayIdentity.sessionSurvives(
        shared: current.displayID, identity: current.displayIdentity,
        virtual: current.virtualDisplay?.displayID, online: online)
    else {
      Self.logger.notice("The shared display went away; ending the session")
      return systemStopped()
    }
    let shared = current.displayID
    followDisplay(current)
    if current.displayID != shared { Task { await updateDisplay(current) } }
  }
}
