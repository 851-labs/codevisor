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
        if let display = session.virtualDisplay {
          try display.resize(width: size.width, height: size.height)
          movesDisplay = false
        } else {
          let display = try ScreenSharingHostVirtualDisplay(
            width: size.width, height: size.height, mirroring: session.displayID)
          try await display.mirror()
          session.virtualDisplay = display
          movesDisplay = true
        }
        let points = session.virtualDisplay?.size ?? size
        session.configuration = try ScreenSharingVideoConfiguration(
          width: points.width * 2, height: points.height * 2, bitrate: Self.bitrateCeiling)
      } else {
        guard let display = session.virtualDisplay else { return }
        display.release()
        session.virtualDisplay = nil
        session.configuration = session.physicalConfiguration
        movesDisplay = true
      }
      // WindowServer applies the mirror and the new mode asynchronously.
      try await Task.sleep(for: .milliseconds(500))
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
