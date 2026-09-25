import AppKit
import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  /// Dynamic Resolution for a native viewer (851-2376): once the display channel opens the host
  /// says whether it can size a virtual display; the viewer's pane size then arrives as `resize`
  /// (in points) and `restore` puts the physical display back.
  func configureDisplay(_ session: Session) {
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

  /// Until `display` reports `pixels` (at most 1 s): the new mode has taken effect.
  static func waitForDisplay(_ display: CGDirectDisplayID, pixels: (width: Int, height: Int)) async throws {
    for _ in 0..<100 {
      guard let mode = CGDisplayCopyDisplayMode(display),
        mode.pixelWidth != pixels.width || mode.pixelHeight != pixels.height
      else { return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Until the physical display has left the mirror set (at most 1 s): back to its own mode.
  static func waitForMirrorToEnd(_ display: CGDirectDisplayID) async throws {
    for _ in 0..<100 where CGDisplayIsInMirrorSet(display) != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// A pane being dragged sends a burst of sizes: the last one within 300 ms wins.
  private func scheduleResize(_ session: Session, to size: (width: Int, height: Int)?) {
    session.pendingResize?.cancel()
    session.pendingResize = Task { [weak self, weak session] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, let session, !session.stopping else { return }
      await self.resize(session, to: size)
    }
  }

  private func resize(_ session: Session, to size: (width: Int, height: Int)?) async {
    let channel = session.peer.displayChannel
    // The virtual display appearing, the mirror and the new mode each post a screen change.
    session.ownDisplayChangeUntil = ProcessInfo.processInfo.systemUptime + 5
    let movesDisplay: Bool
    do {
      if let size {
        // The video first: if the encoder can't take this size, nothing on the host changes.
        let points = ScreenSharingHostVirtualDisplay.clamp(width: size.width, height: size.height)
        let configuration = try ScreenSharingVideoConfiguration(
          width: points.width * 2, height: points.height * 2, bitrate: Self.bitrateCeiling)
        if let display = session.virtualDisplay {
          try display.resize(width: points.width, height: points.height)
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
      // WindowServer applies the mirror and the new mode asynchronously; until the capture has the
      // new size it squeezes the display into the old frame. Wait only until the display reports
      // its new size (tens of milliseconds), then update at once.
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
          try await startWatchedCapture(session)
        } else {
          try await session.capture.update(configuration: session.configuration)
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
