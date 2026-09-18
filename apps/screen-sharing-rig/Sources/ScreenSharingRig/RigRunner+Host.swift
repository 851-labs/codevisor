#if os(macOS)
  import AppKit
  import ScreenSharing
  import ScreenSharingWebRTC
  import ScreenSharingDiagnostics
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  import ScreenSharingRigKit

  extension RigRunner {
    func runHost() async throws {
      let server = try RigHTTPServer(port: configuration.port, loopbackOnly: false) { [weak self] request in
        await self?.handleHostRequest(request) ?? .error(503, "rig stopping")
      }
      let port = try await server.start()
      self.server = server
      log("listening on port \(port); source \(configuration.capture); waiting for a viewer")
      if hudEnabled { showHostWindow() }
      startTelemetry()
      while true { try await Task.sleep(for: .seconds(3600)) }
    }

    func handleHostRequest(_ request: RigHTTPRequest) async -> RigHTTPServer.Response {
      guard RigHTTPCodec.isAuthorized(request, token: configuration.token) else { return .error(401, "bad token") }
      if request.method == "POST", request.path == "/source" {
        guard let body = try? RigJSON.decode(RigSourceRequest.self, from: request.body),
          let capture = try? RigConfiguration.CaptureSource.parse(body.capture)
        else { return .error(400, "source needs a valid capture spec") }
        do { return .json(200, try await switchSource(to: capture)) } catch {
          log("switch to \(capture) failed: \(error)")
          return .error(500, "\(error)")
        }
      }
      if request.method == "GET", request.path == "/clock" {
        // Both stamps are this process's CACurrentMediaTime, the clock capture timestamps use.
        let received = request.receivedAtSeconds
        return .json(200, RigClockReply(receivedAtSeconds: received, sentAtSeconds: CACurrentMediaTime()))
      }
      if request.method == "POST", request.path == "/offer" {
        guard let offer = try? RigJSON.decode(RigOfferRequest.self, from: request.body), offer.version == 1 else {
          return .error(400, "malformed offer")
        }
        do { return .json(200, try await startHostSession(offer)) } catch {
          log("offer from \(offer.name) failed: \(error)")
          return .error(500, "\(error)")
        }
      }
      return await handleSharedRequest(request) ?? .error(404, "unknown route \(request.method) \(request.path)")
    }

    /// Replaces the source on the live session (or just the default for the next one). The peer,
    /// its negotiated size and the viewer are untouched, so two sources compare on one session.
    func switchSource(to capture: RigConfiguration.CaptureSource) async throws -> RigSourceResponse {
      let previous = activeCapture
      activeCapture = capture
      guard let session, !session.closed else {
        log("source set to \(capture) for the next session (previously \(previous))")
        return RigSourceResponse(capture: capture.description, previous: previous.description, live: false)
      }
      await session.stopSource()
      session.metrics.label("captureSize", "")
      do {
        session.sourceStarted = true
        try await startSource(in: session)
      } catch {
        activeCapture = previous
        session.sourceStarted = true
        try? await startSource(in: session)
        throw error
      }
      log("source switched \(previous) → \(capture) on session \(session.id)")
      return RigSourceResponse(capture: capture.description, previous: previous.description, live: true)
    }

    /// Latest offer wins: a new viewer replaces the current session outright.
    func startHostSession(_ offer: RigOfferRequest) async throws -> RigAnswerResponse {
      if let existing = session {
        log("replacing session \(existing.id) with \(offer.sessionID) from \(offer.name)")
        session = nil
        await existing.close()
      }
      reducer.reset()
      let metrics = ScreenSharingMetrics()
      var options = ScreenSharingPeerOptions()
      options.useLowLatencyRateControl = useLowLatencyRateControl
      options.codec = configuration.codec
      options.maximumPendingFrames = configuration.tuning.pendingFrames ?? 2
      options.staticCodecRate = configuration.tuning.staticCodecRate
      options.keyframeIntervalSeconds = configuration.tuning.keyframeIntervalSeconds ?? 2
      options.transportCeilingBps = configuration.tuning.transportCeilingBps
      let peer = try ScreenSharingSender(configuration: configuration.video, metrics: metrics, options: options)
      let session = RigSession(id: offer.sessionID, peer: peer, metrics: metrics)
      self.session = session
      peerName = offer.name
      peerBuild = offer.build
      peer.onConnectionChanged = { [weak self, weak session] state in
        Task { @MainActor in
          guard let self, let session else { return }
          self.connectionChanged(state, in: session)
        }
      }
      try await peer.accept(offer.offer)
      let answer = try await peer.makeDescription(offer: false)
      log("answered \(offer.name) (\(offer.build.label)) for session \(offer.sessionID)")
      return RigAnswerResponse(sessionID: offer.sessionID, answer: answer, build: build, name: name)
    }

    func startSource(in session: RigSession) async throws {
      let video = configuration.video
      session.metrics.label("captureError", "")
      if session.displaySleepAssertion == nil {
        session.displaySleepAssertion = RigDisplaySleepAssertion(reason: "Codevisor Screen Sharing Rig host session")
      }
      switch activeCapture {
      case .synthetic:
        let source = try SyntheticSource(
          configuration: video, sender: session.frameSender, metrics: session.metrics, pixelFormat: .nv12,
          desktopPattern: true)
        session.synthetic = source
        session.metrics.label("captureSize", "\(video.width) × \(video.height)")
        session.metrics.label("captureFPS", String(video.framesPerSecond))
        session.metrics.label("captureSelection", "synthetic desktop pattern (no capture)")
        source.start()
        log("synthetic source started")
      case .workload(let width, let height, let fps):
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        let workloadConfiguration = try ScreenSharingVideoConfiguration(
          width: width, height: height, framesPerSecond: fps, bitrate: video.bitrate)
        let workload = try ProbeOwnedWorkloadWindow(configuration: workloadConfiguration) { try await capture.stop() }
        session.workload = workload
        let sender = session.frameSender
        let metrics = session.metrics
        _ = try await workload.start(timeoutSeconds: 10) {
          try await capture.start(
            ownedWindowID: workload.windowID, configuration: video, sink: sender, metrics: metrics)
        }
        log("owned workload window \(workload.windowID) captured at \(width)×\(height)@\(fps)")
      case .virtual(let width, let height, let fps):
        try requireScreenRecording(for: "a virtual display, which is captured like a physical one")
        let (virtualDisplay, screen) = try await createVirtualDisplay(
          width: width, height: height, fps: fps, in: session)
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        let workloadConfiguration = try ScreenSharingVideoConfiguration(
          width: width, height: height, framesPerSecond: fps, bitrate: video.bitrate)
        let workload = try ProbeOwnedWorkloadWindow(configuration: workloadConfiguration, screen: screen) {
          try await capture.stop()
        }
        session.workload = workload
        // Cover the virtual display's menu bar so the captured raster is only the workload.
        workload.window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        // On a display nobody else uses, the workload may take clicks and keys: its Response counter proves injection.
        workload.window.ignoresMouseEvents = false
        workload.window.acceptsKeys = true
        let sender = session.frameSender
        let metrics = session.metrics
        let displayID = virtualDisplay.displayID
        _ = try await workload.start(timeoutSeconds: 10) {
          try await capture.start(displayID: displayID, configuration: video, sink: sender, metrics: metrics)
        }
        session.metrics.label("captureSelection", "virtual display \(displayID) with the owned workload window")
        installHostControl(in: session, displayID: displayID)
        log("virtual display \(displayID) captured with the workload window on it (\(width)×\(height)@\(fps))")
      case .virtualDesktop(let width, let height, let fps):
        try requireScreenRecording(for: "a virtual display, which is captured like a physical one")
        let (virtualDisplay, _) = try await createVirtualDisplay(width: width, height: height, fps: fps, in: session)
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        try await capture.start(
          displayID: virtualDisplay.displayID, configuration: video, sink: session.frameSender,
          metrics: session.metrics)
        session.metrics.label("captureSelection", "bare virtual display \(virtualDisplay.displayID)")
        installHostControl(in: session, displayID: virtualDisplay.displayID)
        log(
          "bare virtual display \(virtualDisplay.displayID) captured (\(width)×\(height)@\(fps)); move windows onto \"\(RigVirtualDisplay.name)\" to stream them"
        )
      case .app(let bundle):
        try requireScreenRecording(for: "an application's windows")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let application = content.applications.first(where: { $0.bundleIdentifier == bundle }) else {
          throw ScreenSharingError.unavailable("no running application with bundle identifier \(bundle)")
        }
        guard
          let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? content.displays.first
        else { throw ScreenSharingError.unavailable("no display to capture \(bundle) on") }
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        try await capture.start(
          pickedFilter: SCContentFilter(display: display, including: [application], exceptingWindows: []),
          configuration: video, sink: session.frameSender, metrics: session.metrics)
        session.metrics.label(
          "captureSelection", "application \(bundle) (\(application.applicationName)) on display \(display.displayID)")
        log("application \(bundle) captured on display \(display.displayID)")
      case .window(let id):
        try requireScreenRecording(for: "a window")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
          throw ScreenSharingError.unavailable("no window with ID \(id)")
        }
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        try await capture.start(
          pickedFilter: SCContentFilter(desktopIndependentWindow: window), configuration: video,
          sink: session.frameSender, metrics: session.metrics)
        session.metrics.label(
          "captureSelection",
          "window \(id) \"\(window.title ?? "")\" of \(window.owningApplication?.bundleIdentifier ?? "?")")
        log("window \(id) (\(window.title ?? "untitled")) captured")
      case .display(let id):
        try requireScreenRecording(for: "a physical display")
        let capture = ScreenSharingCapture(captureIntervalFPS: configuration.tuning.captureIntervalFPS)
        session.capture = capture
        try await capture.start(
          displayID: id, configuration: video, sink: session.frameSender, metrics: session.metrics)
        installHostControl(in: session, displayID: id)
        log("display \(id) captured")
      }
    }

    /// ScreenCaptureKit stops a stream with an error when the displays sleep or the target
    /// disappears, and never restarts it. The capture records the error in a label; when it
    /// appears, re-apply the active source, at most every 5 s while the error persists.
    func recoverFromCaptureError(in session: RigSession) async {
      guard session.sourceStarted else { return }
      let error = session.metrics.snapshot().labels["captureError"] ?? ""
      if !error.isEmpty, !session.captureRecoveryPending {
        session.captureRecoveryPending = true
        log("capture error on \(activeCapture): \(error); restarting the source")
        session.metrics.label("sourceStall", "capture stopped: \(error); restarting")
      }
      guard session.captureRecoveryPending else { return }
      let now = ScreenSharingMetrics.nowNs
      guard now - session.lastCaptureRecoveryNs > 5_000_000_000 else { return }
      session.lastCaptureRecoveryNs = now
      do {
        _ = try await switchSource(to: activeCapture)
        session.captureRecoveryPending = false
        session.metrics.label("sourceStall", "")
        log("source restarted after the capture error")
      } catch {
        // Displays may still be asleep; keep the flag and try again on a later tick.
        log("source restart failed: \(error); retrying")
      }
    }

    /// A source that starts and then delivers nothing is what an exhausted capture daemon looks
    /// like (see the plan): say so instead of showing a silent "— fps".
    static let stallSeconds: Double = 5

    func watchForStall(in session: RigSession) {
      session.metrics.label("sourceStall", "")
      let started = session.metrics.snapshot().counters["capturedFrames", default: 0]
      Task { @MainActor [weak self, weak session] in
        try? await Task.sleep(for: .seconds(Self.stallSeconds))
        guard let self, let session, session === self.session, !session.closed else { return }
        let frames = session.metrics.snapshot().counters["capturedFrames", default: 0]
        guard frames == started else { return }
        let text =
          "no frames \(Int(Self.stallSeconds)) s after \(self.activeCapture) started; if this persists for physical displays too, replayd is probably exhausted (kill it; see docs/plans/screen-sharing-rig.md)"
        session.metrics.label("sourceStall", text)
        self.log("stall: \(text)")
      }
    }

    /// Non-owned capture needs the Screen Recording grant. When it is missing, ask once so the rig
    /// appears in System Settings → Privacy & Security → Screen & System Audio Recording, then fail
    /// clearly; the viewer keeps retrying and picks the grant up on the next session.
    func requireScreenRecording(for purpose: String) throws {
      guard !CGPreflightScreenCaptureAccess() else { return }
      if !screenRecordingRequested {
        screenRecordingRequested = true
        _ = CGRequestScreenCaptureAccess()
      }
      throw ScreenSharingError.unavailable(
        "Screen Recording is not granted to the rig on this Mac (needed for \(purpose)); enable Codevisor Screen Sharing Rig under Privacy & Security → Screen & System Audio Recording, or use capture workload."
      )
    }

    /// The product's control lease and CGEvent injector, bound to the captured display. Only display-backed
    /// sources accept control; a request is answered with the reason otherwise. Accessibility is asked for
    /// once so the rig appears in System Settings on a Mac where prompts do not show.
    func installHostControl(in session: RigSession, displayID: CGDirectDisplayID) {
      session.controlDisplayID = displayID
      let injector = ScreenSharingInputInjector(displayBounds: CGDisplayBounds(displayID))
      let control = ScreenSharingHostControl(
        availability: { [weak self, weak session] in
          guard let session, session.controlDisplayID != nil else {
            return "Control needs a display-backed source (virtual, virtual-desktop or display)."
          }
          guard AXIsProcessTrusted() else {
            if let self, !self.accessibilityRequested {
              self.accessibilityRequested = true
              let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
              _ = AXIsProcessTrustedWithOptions(options)
            }
            return
              "Accessibility is not granted to the rig on this Mac; enable Codevisor Screen Sharing Rig under Privacy & Security → Accessibility."
          }
          guard injector.isAvailable else { return "No event source." }
          return nil
        },
        inject: { injector.post($0) },
        send: { [weak session] message in session?.peer.controlChannel.send(message) ?? false })
      control.onChanged = { [weak self, weak session] active in
        self?.log("control \(active ? "granted" : "released") on display \(displayID)")
        session?.metrics.label("controlActive", active ? "true" : "false")
        // Injected key events go to the frontmost app's key window: for the lease's duration, that is the
        // workload on the virtual display. Focus returns to whatever was active on release.
        guard let window = session?.workload?.window, window.acceptsKeys else { return }
        if active {
          NSApplication.shared.activate()
          window.makeKeyAndOrderFront(nil)
          window.makeFirstResponder(window.contentView)
        } else {
          NSApplication.shared.deactivate()
        }
      }
      session.peer.controlChannel.onMessage = { [weak control] message in control?.receive(message) }
      session.hostControl = control
      session.controlDeadlineTask = Task { @MainActor [weak control] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          control?.checkDeadline()
        }
      }
    }

    /// Creates the 1:1 virtual display for a WxH-pixel video and waits for AppKit to attach it.
    func createVirtualDisplay(
      width: Int, height: Int, fps: Int, in session: RigSession
    ) async throws -> (display: RigVirtualDisplay, screen: NSScreen) {
      // The display's pixel raster equals the video raster: WxH pixels is (W/2)x(H/2) points at 2x.
      let virtualDisplay = try RigVirtualDisplay(width: width / 2, height: height / 2, framesPerSecond: fps) {
        [weak self] in
        Task { @MainActor in
          guard let self, let session = self.session else { return }
          await self.endSession(session, reason: "virtual display terminated by the system")
        }
      }
      session.virtualDisplay = virtualDisplay
      let screen = try await virtualDisplay.waitForScreen(timeoutSeconds: 10)
      log(virtualDisplay.summary + " · backing scale \(screen.backingScaleFactor)")
      return (virtualDisplay, screen)
    }

    func showHostWindow() {
      let hud = RigHUDView()
      let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 140))
      content.addSubview(hud)
      let window = NSWindow(
        contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Codevisor Screen Sharing Rig · host"
      window.level = .floating
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.contentView = content
      window.setFrameOrigin(NSPoint(x: 40, y: 60))
      window.orderFrontRegardless()
      self.window = window
      container = content
      self.hud = hud
    }
  }
#endif
