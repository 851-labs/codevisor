#if os(macOS)
  import AppKit
  import CodevisorScreenSharing
  import ScreenSharingDiagnostics
  import Foundation
  import ScreenSharingDiagnostics
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

    /// Latest offer wins: a new viewer replaces the current session outright.
    func startHostSession(_ offer: RigOfferRequest) async throws -> RigAnswerResponse {
      if let existing = session {
        log("replacing session \(existing.id) with \(offer.sessionID) from \(offer.name)")
        session = nil
        await existing.close()
      }
      reducer.reset()
      let metrics = ScreenSharingMetrics()
      let peer = try ScreenSharingPeer(
        sending: true, configuration: configuration.video, metrics: metrics, codec: configuration.codec)
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
      switch configuration.capture {
      case .synthetic:
        let source = try SyntheticSource(
          configuration: video, sender: session.peer.frameSender, metrics: session.metrics, pixelFormat: .nv12,
          desktopPattern: true)
        session.synthetic = source
        session.metrics.label("captureSize", "\(video.width) × \(video.height)")
        session.metrics.label("captureFPS", String(video.framesPerSecond))
        source.start()
        log("synthetic source started")
      case .workload(let width, let height, let fps):
        let capture = ScreenSharingCapture()
        session.capture = capture
        let workloadConfiguration = try ScreenSharingVideoConfiguration(
          width: width, height: height, framesPerSecond: fps, bitrate: video.bitrate)
        let workload = try ProbeOwnedWorkloadWindow(configuration: workloadConfiguration) { try await capture.stop() }
        session.workload = workload
        let sender = session.peer.frameSender
        let metrics = session.metrics
        _ = try await workload.start(timeoutSeconds: 10) {
          try await capture.start(
            ownedWindowID: workload.windowID, configuration: video, sender: sender, metrics: metrics)
        }
        log("owned workload window \(workload.windowID) captured at \(width)×\(height)@\(fps)")
      case .display(let id):
        guard CGPreflightScreenCaptureAccess() else {
          throw ScreenSharingError.unavailable(
            "Screen Recording is not granted to the rig on this Mac; use capture workload or grant it in System Settings."
          )
        }
        let capture = ScreenSharingCapture()
        session.capture = capture
        try await capture.start(
          displayID: id, configuration: video, sender: session.peer.frameSender, metrics: session.metrics)
        log("display \(id) captured")
      }
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
