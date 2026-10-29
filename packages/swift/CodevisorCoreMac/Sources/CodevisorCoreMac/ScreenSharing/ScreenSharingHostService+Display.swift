import AppKit
import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  func configureDisplay(_ session: ScreenSharingHostSession) {
    let channel = session.peer.displayChannel
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

  static func waitForMirrorToEnd(_ display: CGDirectDisplayID) async throws {
    for _ in 0..<100 where CGDisplayIsInMirrorSet(display) != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func scheduleResize(_ session: ScreenSharingHostSession, to size: (width: Int, height: Int)?) {
    session.pendingResize?.cancel()
    session.pendingResize = Task { [weak self, weak session] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, let session, !session.stopping else { return }
      await session.resizing?.value
      guard !Task.isCancelled, !session.stopping else { return }
      let resizing = Task { await self.resize(session, to: size) }
      session.resizing = resizing
      await resizing.value
    }
  }

  private func resize(_ session: ScreenSharingHostSession, to size: (width: Int, height: Int)?) async {
    let channel = session.peer.displayChannel
    session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 5
    followDisplay(session)
    let movesDisplay: Bool
    do {
      if let size {
        let points = ScreenSharingHostVirtualDisplay.clamp(width: size.width, height: size.height)
        let configuration = try ScreenSharingVideoConfiguration(
          width: points.width * 2, height: points.height * 2, bitrate: ScreenSharingProductProfile.bitrateCeiling)
        if let display = session.virtualDisplay {
          try display.resize(width: points.width, height: points.height)
          try await display.selectHiDPIMode()
          movesDisplay = false
        } else {
          let display = try ScreenSharingHostVirtualDisplay(
            width: points.width, height: points.height, mirroring: session.displayID)
          try await display.mirror()
          session.virtualDisplay = display
          movesDisplay = true
        }
        session.configuration = configuration
      } else {
        guard let display = session.virtualDisplay else { return }
        display.release()
        session.virtualDisplay = nil
        session.configuration = session.physicalConfiguration
        movesDisplay = true
      }
      if session.virtualDisplay != nil {
        try await Self.waitForDisplay(
          session.captureDisplayID, pixels: (session.configuration.width, session.configuration.height))
      } else {
        try await Self.waitForMirrorToEnd(session.displayID)
      }
      guard !session.stopping else { return }
      session.injector = ScreenSharingInputInjector(displayBounds: CGDisplayBounds(session.displayID))
      session.peer.updateVideoConfiguration(session.configuration)
      if session.state == "viewing" {
        if movesDisplay {
          try? await session.capture.stop()
          try await startWatchedCapture(
            session, reason: session.virtualDisplay == nil ? "physical display restored" : "moved to virtual display")
        } else {
          let began = ContinuousClock.now
          try await session.capture.update(configuration: session.configuration)
          session.capturing?.configuration = session.configuration
          Self.logger.notice(
            "Capture resized to \(session.configuration.width)×\(session.configuration.height) in \(Self.milliseconds(since: began)) ms"
          )
        }
      }
      let points = session.virtualDisplay?.size
      session.metrics.label(
        "displaySize",
        points.map { "virtual \($0.width)×\($0.height) pt" } ?? "physical, scaled to \(session.configuration.width) px")
      channel.send(.resized(width: points?.width ?? 0, height: points?.height ?? 0))
    } catch is CancellationError {
      return
    } catch {
      session.metrics.label("displaySize", error.localizedDescription)
      channel.send(.unavailable(error.localizedDescription))
    }
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
    followDisplay(current)
  }
}
