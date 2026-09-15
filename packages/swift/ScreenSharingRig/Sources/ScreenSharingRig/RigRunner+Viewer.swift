#if os(macOS)
  import AppKit
  import CodevisorScreenSharing
  import Foundation
  import QuartzCore
  import ScreenSharingDiagnostics
  import ScreenSharingRigKit

  extension RigRunner {
    func runViewer() async throws {
      guard let base = configuration.hostBaseURL else { throw ScreenSharingError.invalid("viewer needs peer") }
      let control = try RigHTTPServer(port: configuration.controlPort, loopbackOnly: true) { [weak self] request in
        await self?.handleViewerRequest(request) ?? .error(503, "rig stopping")
      }
      let port = try await control.start()
      server = control
      log("control on 127.0.0.1:\(port); host \(base.absoluteString)")
      showViewerWindow()
      startTelemetry()
      startClockCalibration(base: base)
      var policy = RigReconnectPolicy()
      while true {
        var current: RigSession?
        do {
          let session = try await connectViewer(base: base)
          current = session
          policy.succeeded()
          await waitForEnd(of: session)
        } catch {
          log("connect failed: \(error)")
        }
        if let current {
          await endSession(current, reason: "viewer loop")
        } else if let stale = session {
          await endSession(stale, reason: "viewer loop")
        }
        reconnects += 1
        let delay = policy.failed()
        log("reconnecting in \(delay) s (attempt \(reconnects))")
        try await Task.sleep(for: .seconds(delay))
      }
    }

    func connectViewer(base: URL) async throws -> RigSession {
      reducer.reset()
      let metrics = ScreenSharingMetrics()
      let peer = try ScreenSharingPeer(
        sending: false, configuration: configuration.video, metrics: metrics, codec: configuration.codec)
      let session = RigSession(id: UUID().uuidString.lowercased(), peer: peer, metrics: metrics)
      self.session = session
      peer.onConnectionChanged = { [weak self, weak session] state in
        Task { @MainActor in
          guard let self, let session else { return }
          self.connectionChanged(state, in: session)
        }
      }
      let tuning = configuration.tuning
      let view = try ScreenSharingMetalView(
        mailbox: peer.mailbox, metrics: metrics, renderOnArrival: tuning.renderOnArrival,
        maximumDrawableCount: tuning.maximumDrawableCount, offMainPreparation: tuning.offMainPreparation)
      view.onFrameSize = { [weak session] size in Task { @MainActor in session?.frameSize = size } }
      view.onFramePresented = { [weak self] presented in
        // Delivered on the main actor by the coordinator's hop; the offset is read at that moment.
        MainActor.assumeIsolated {
          guard let self, let offset = self.clockOffset, let source = presented.sourceTimestampNs else { return }
          let age = offset.imageAgeSeconds(
            sourceTimestampNs: source, presentedAtSeconds: presented.presentedAtSeconds)
          self.imageAges.record(ageSeconds: age)
        }
      }
      if let container {
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        if let hud {
          container.addSubview(view, positioned: .below, relativeTo: hud)
        } else {
          container.addSubview(view)
        }
      }
      session.metalView = view
      let offer = try await peer.makeDescription(offer: true)
      let request = RigOfferRequest(sessionID: session.id, offer: offer, build: build, name: name)
      let answer = try await RigHTTPClient.post(
        base.appendingPathComponent("offer"), token: configuration.token, body: request,
        expecting: RigAnswerResponse.self)
      guard answer.sessionID == session.id else { throw ScreenSharingError.invalid("answer for another session") }
      peerName = answer.name
      peerBuild = answer.build
      try await peer.accept(answer.answer)
      log("offered session \(session.id) to \(answer.name) (\(answer.build.label)); waiting for media")
      let states = session.states
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in states {
            if state == "connected" { return }
            if state == "failed" || state == "closed" { throw ScreenSharingError.unavailable("peer \(state)") }
          }
          throw ScreenSharingError.unavailable("session closed before connecting")
        }
        group.addTask {
          try await Task.sleep(for: .seconds(15))
          throw ScreenSharingError.unavailable("no connection within 15 s")
        }
        try await group.next()
        group.cancelAll()
      }
      log("session \(session.id) connected")
      return session
    }

    /// Calibrates `host - viewer` from 25 bracketed `/clock` exchanges, now and every 60 s, keeping the
    /// tightest interval. Image age is only shown while an offset exists.
    func startClockCalibration(base: URL) {
      clockTask?.cancel()
      clockTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          var samples: [RigClockOffset.Sample] = []
          for _ in 0..<25 {
            let sent = CACurrentMediaTime()
            guard
              let reply = try? await RigHTTPClient.get(
                base.appendingPathComponent("clock"), token: configuration.token, expecting: RigClockReply.self,
                timeoutSeconds: 2)
            else { break }
            samples.append(
              RigClockOffset.Sample(
                sentAtSeconds: sent, hostReceivedAtSeconds: reply.receivedAtSeconds,
                hostSentAtSeconds: reply.sentAtSeconds, receivedAtSeconds: CACurrentMediaTime()))
          }
          if let offset = RigClockOffset(samples: samples) {
            if clockOffset == nil {
              log(
                "clock offset \(String(format: "%.3f", offset.offsetSeconds)) s ± \(String(format: "%.2f", offset.errorSeconds * 1000)) ms from \(offset.sampleCount) samples"
              )
            }
            clockOffset = offset
          } else {
            clockOffset = nil
          }
          try? await Task.sleep(for: .seconds(60))
        }
      }
    }

    func waitForEnd(of session: RigSession) async {
      for await state in session.states where state == "failed" || state == "closed" {
        return
      }
    }

    func handleViewerRequest(_ request: RigHTTPRequest) async -> RigHTTPServer.Response {
      guard RigHTTPCodec.isAuthorized(request, token: configuration.token) else { return .error(401, "bad token") }
      if request.method == "POST", request.path == "/control-check" {
        guard let body = try? RigJSON.decode(RigControlCheckRequest.self, from: request.body),
          (0...100).contains(body.clicks), (0...100).contains(body.keys), (0...1).contains(body.x),
          (0...1).contains(body.y)
        else { return .error(400, "control-check needs clicks/keys 0...100 and x/y in 0...1") }
        guard let session, session.connection == "connected" else { return .error(503, "not connected") }
        let base = configuration.hostBaseURL
        let token = configuration.token
        let check = RigViewerControlCheck(channel: session.peer.control, request: body)
        do {
          let result = try await check.run {
            guard let base,
              let metrics = try? await RigHTTPClient.get(
                base.appendingPathComponent("metrics"), token: token, expecting: RigMetricsBody.self, timeoutSeconds: 3)
            else { return nil }
            return metrics.snapshot?.labels["workloadResponses"].flatMap(Int.init)
          }
          log(
            "control check: granted \(result.granted)\(result.deniedReason.map { " (\($0))" } ?? "") · \(result.clicksSent) clicks · \(result.keysSent) keys · responses \(result.responsesBefore.map(String.init) ?? "?") → \(result.responsesAfter.map(String.init) ?? "?") · \(result.delivered ? "delivered" : "not delivered")"
          )
          return .json(200, result)
        } catch {
          return .error(500, "\(error)")
        }
      }
      if request.method == "POST", request.path == "/sample" {
        guard let body = try? RigJSON.decode(RigSampleRequest.self, from: request.body),
          (1...3600).contains(body.seconds), body.report.hasPrefix("/")
        else { return .error(400, "sample needs seconds 1...3600 and an absolute report path") }
        guard sampling == nil else { return .error(409, "a sample is already running") }
        guard session?.connection == "connected" else { return .error(503, "not connected") }
        do {
          return .json(200, try await runSample(seconds: body.seconds, report: URL(fileURLWithPath: body.report)))
        } catch {
          return .error(500, "\(error)")
        }
      }
      return await handleSharedRequest(request) ?? .error(404, "unknown route \(request.method) \(request.path)")
    }

    func runSample(seconds: Int, report: URL) async throws -> RigSampleResponse {
      let hudWasEnabled = hudEnabled
      setHUD(false)
      defer { setHUD(hudWasEnabled) }
      log("sample: \(seconds) s → \(report.path)")
      return try await withCheckedThrowingContinuation { continuation in
        sampling = Sampling(
          deadlineElapsed: elapsedSeconds + Double(seconds), report: report, continuation: continuation)
      }
    }

    func finishSampling(_ sampling: Sampling) async {
      self.sampling = nil
      do {
        var host: RigMetricsBody?
        if let base = configuration.hostBaseURL {
          host = try? await RigHTTPClient.get(
            base.appendingPathComponent("metrics"), token: configuration.token, expecting: RigMetricsBody.self)
        }
        let video = configuration.video
        let report: [String: Any] = [
          "meaning":
            "rig sample: viewer per-second telemetry plus the host's final snapshot; a tool check, not a benchmark",
          "viewer": try JSONSerialization.jsonObject(with: try RigJSON.encode(await metricsBody())),
          "host": try host.map { try JSONSerialization.jsonObject(with: try RigJSON.encode($0)) } ?? NSNull(),
          "samples": try JSONSerialization.jsonObject(with: try RigJSON.encode(sampling.samples)),
          "video":
            "\(video.width)×\(video.height)@\(video.framesPerSecond) \(video.bitrate) bps \(configuration.codec.rawValue)",
        ]
        try FileManager.default.createDirectory(
          at: sampling.report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: sampling.report, options: .atomic)
        let rates = sampling.samples.compactMap(\.presentedFramesPerSecond)
        let mean = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        log(
          "sample written: \(sampling.samples.count) samples, mean presented \(mean.map { String(format: "%.1f", $0) } ?? "-") fps"
        )
        sampling.continuation.resume(
          returning: RigSampleResponse(
            report: sampling.report.path, samples: sampling.samples.count, meanPresentedFramesPerSecond: mean))
      } catch {
        sampling.continuation.resume(throwing: error)
      }
    }

    func showViewerWindow() {
      let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
      let hud = RigHUDView()
      content.addSubview(hud)
      let window = NSWindow(
        contentRect: content.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.title = "Codevisor Screen Sharing Rig · viewer"
      window.contentView = content
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate()
      self.window = window
      container = content
      self.hud = hud
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window, event.charactersIgnoringModifiers?.lowercased() == "h",
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return event }
        self.setHUD(!self.hudEnabled)
        return nil
      }
    }

    func windowWillClose(_ notification: Notification) {
      log("viewer window closed; exiting cleanly (the launch agent will not restart a clean exit)")
      Task { @MainActor in
        await self.stop()
        exit(EXIT_SUCCESS)
      }
    }
  }
#endif
