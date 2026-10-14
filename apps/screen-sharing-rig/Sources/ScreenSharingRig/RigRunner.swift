#if os(macOS)
  import AppKit
  import CodevisorCoreMac
  import ScreenSharing
  import ScreenSharingWebRTC
  import ScreenSharingDiagnostics
  import Foundation
  import ScreenSharingRigKit
  import os

  @MainActor
  final class RigSession {
    let id: String
    let peer: ScreenSharingPeer
    let metrics: ScreenSharingMetrics
    let states: AsyncStream<String>
    private let stateContinuation: AsyncStream<String>.Continuation
    private(set) var connection = "new"
    private(set) var closed = false
    var capture: ScreenSharingCapture?
    var workload: ProbeOwnedWorkloadWindow?
    var virtualDisplay: RigVirtualDisplay?
    var displaySleepAssertion: ScreenSharingDisplaySleepAssertion?
    var controlDisplayID: CGDirectDisplayID? {
      didSet { cursorDisplayID.withLock { [controlDisplayID] in $0 = controlDisplayID } }
    }
    let cursorDisplayID = OSAllocatedUnfairLock<CGDirectDisplayID?>(initialState: nil)
    var hostControl: ScreenSharingHostControl?
    var controlDeadlineTask: Task<Void, Never>?
    var lastCaptureRecoveryNs: Int64 = 0
    var captureRecoveryPending = false
    var synthetic: SyntheticSource?
    var metalView: ScreenSharingMetalView?
    var frameSize: CGSize?
    var sourceStarted = false
    var cursor: ScreenSharingCursorPublisher?
    var audioEncoder: ScreenSharingAudioEncoder?
    var capturePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var codec: ScreenSharingVideoCodec?
    var viewerHighDynamicRange = false

    var frameSender: ScreenSharingFrameSender {
      guard let sender = peer as? ScreenSharingSender else { preconditionFailure("Frame sender on a viewer session") }
      return sender.frameSender
    }

    init(id: String, peer: ScreenSharingPeer, metrics: ScreenSharingMetrics) {
      self.id = id
      self.peer = peer
      self.metrics = metrics
      (states, stateContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    func record(_ state: String) {
      connection = state
      stateContinuation.yield(state)
    }

    var frameSizeLabel: String? { frameSize.map { "\(Int($0.width))×\(Int($0.height))" } }

    func stopSource() async {
      controlDeadlineTask?.cancel()
      controlDeadlineTask = nil
      hostControl?.revoke("The source stopped.")
      hostControl = nil
      peer.controlChannel.onMessage = nil
      controlDisplayID = nil
      synthetic?.stop()
      synthetic = nil
      if let workload {
        if workload.lifecycle.state == .capturing || workload.lifecycle.state == .workloadPaused {
          await workload.stopCapture()
        }
        workload.cleanUp()
      } else {
        try? await capture?.stop()
      }
      workload = nil
      capture = nil
      virtualDisplay = nil
      displaySleepAssertion = nil
      sourceStarted = false
    }

    func close() async {
      guard !closed else { return }
      closed = true
      stateContinuation.finish()
      cursor?.stop()
      cursor = nil
      await stopSource()
      metalView?.stop()
      metalView?.removeFromSuperview()
      metalView = nil
      peer.close()
    }
  }

  @MainActor
  final class RigRunner: NSObject, NSWindowDelegate {
    struct Sampling {
      let deadlineElapsed: Double
      let report: URL
      var samples: [RigTelemetrySample] = []
      let continuation: CheckedContinuation<RigSampleResponse, any Error>
    }

    let configuration: RigConfiguration
    var activeCapture: RigConfiguration.CaptureSource
    let build: RigBuildInfo
    let name: String
    let startedNs = ScreenSharingMetrics.nowNs
    var server: RigHTTPServer?
    var session: RigSession?
    var reconnects = 0
    var peerName: String?
    var peerBuild: RigBuildInfo?
    var window: NSWindow?
    var container: NSView?
    var hud: RigHUDView?
    var hudEnabled: Bool
    var telemetryTask: Task<Void, Never>?
    var telemetry: RigTelemetryWriter?
    var reducer = RigTelemetryReducer()
    var latestSample: RigTelemetrySample?
    var latestStatistics: [String: String] = [:]
    var sampling: Sampling?
    var keyMonitor: Any?
    var disconnectGrace: Task<Void, Never>?
    var screenRecordingRequested = false
    var accessibilityRequested = false
    var clockOffset: RigClockOffset?
    var clockTask: Task<Void, Never>?
    var imageAges = RigImageAge()
    let nativeSession = RigNativeSessionStatus()

    init(configuration: RigConfiguration, build: RigBuildInfo) {
      self.configuration = configuration
      activeCapture = configuration.capture
      self.build = build
      name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
      hudEnabled = configuration.hud
      nativeSession.hudEnabled = hudEnabled
    }

    var elapsedSeconds: Double { Double(ScreenSharingMetrics.nowNs - startedNs) / 1_000_000_000 }

    var useLowLatencyRateControl: Bool {
      !configuration.tuning.standardRateControl && configuration.codec != .hevc444
    }

    func log(_ message: String) {
      let stamp = ISO8601DateFormatter().string(from: Date())
      print("\(stamp) rig \(configuration.role.rawValue): \(message)")
      fflush(stdout)
    }

    func run() async throws {
      let directory =
        configuration.telemetryDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CodevisorRig")
      telemetry = try RigTelemetryWriter(directory: directory, role: configuration.role.rawValue)
      log("build \(build.label) on \(name); telemetry \(telemetry?.url.path ?? "-")")
      if let label = configuration.tuning.label { log("tuning: \(label)") }
      switch configuration.role {
      case .host: try await runHost()
      case .viewer: try await runViewer()
      }
    }

    func stop() async {
      telemetryTask?.cancel()
      clockTask?.cancel()
      server?.stop()
      if let session {
        self.session = nil
        await session.close()
      }
      telemetry?.close()
    }

    func connectionChanged(_ state: String, in session: RigSession) {
      guard session === self.session, !session.closed else { return }
      session.record(state)
      log("session \(session.id): \(state)")
      switch state {
      case "connected":
        disconnectGrace?.cancel()
        disconnectGrace = nil
        if configuration.role == .host, !session.sourceStarted {
          session.sourceStarted = true
          Task { @MainActor in
            do {
              let baseline = ScreenSharingCaptureStallRecovery.activity(session.metrics.snapshot().counters)
              try await self.startSource(in: session)
              await self.watchForStall(in: session, baseline: baseline)
            } catch {
              self.log("source \(self.activeCapture) failed: \(error)")
              await self.endSession(session, reason: "source failed")
            }
          }
        }
      case "failed", "closed":
        Task { await self.endSession(session, reason: state) }
      case "disconnected":
        disconnectGrace?.cancel()
        disconnectGrace = Task { @MainActor in
          if await self.hostForgotSession(session) {
            await self.endSession(session, reason: "host no longer has this session")
            return
          }
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled, session === self.session, session.connection == "disconnected" else { return }
          await self.endSession(session, reason: "disconnected for 5 s")
        }
      default: break
      }
    }

    func hostForgotSession(_ session: RigSession) async -> Bool {
      guard configuration.role == .viewer, let base = configuration.hostBaseURL else { return false }
      guard
        let status = try? await RigHTTPClient.get(
          base.appendingPathComponent("status"), token: configuration.token, expecting: RigStatus.self,
          timeoutSeconds: 2)
      else { return false }
      return status.sessionID != session.id
    }

    func endSession(_ session: RigSession, reason: String) async {
      guard session === self.session else { return }
      self.session = nil
      log("session \(session.id) ended: \(reason)")
      await session.close()
    }

    func setHUD(_ enabled: Bool) {
      hudEnabled = enabled
      hud?.isHidden = !enabled
      nativeSession.hudEnabled = enabled
    }

    func nativeSessionLine() -> String {
      var parts = [session.map { "connection: \($0.connection)" } ?? "connection: waiting"]
      if let peerName { parts.append("peer \(peerName) · \(peerBuild?.label ?? "?")") }
      if let size = session?.frameSizeLabel { parts.append(size) }
      parts.append("reconnects \(reconnects)")
      parts.append("up \(Int(elapsedSeconds)) s")
      return parts.joined(separator: " · ")
    }

    func startTelemetry() {
      telemetryTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard let self else { return }
          await self.tick()
        }
      }
    }

    func tick() async {
      let elapsed = elapsedSeconds
      if let session, !session.closed {
        if configuration.role == .host {
          await recoverFromCaptureError(in: session)
          if let workload = session.workload {
            session.metrics.label("workloadResponses", String(workload.view.responses))
          }
        }
        let statistics = await session.peer.statistics()
        guard !session.closed else { return }
        latestStatistics = statistics
        let sample = reducer.reduce(
          elapsed: elapsed, role: configuration.role.rawValue, connection: session.connection, sessionID: session.id,
          snapshot: session.metrics.snapshot(), statistics: statistics,
          mailboxDrops: (session.peer as? ScreenSharingReceiver)?.mailbox.droppedFrames ?? 0,
          frameSize: session.frameSizeLabel, imageAge: imageAges.take(),
          clockErrorMilliseconds: clockOffset.map { $0.errorSeconds * 1000 })
        latestSample = sample
        try? telemetry?.append(sample)
        if var sampling {
          sampling.samples.append(sample)
          self.sampling = sampling
          if elapsed >= sampling.deadlineElapsed { await finishSampling(sampling) }
        }
      } else {
        latestSample = nil
        latestStatistics = [:]
        if let sampling {
          self.sampling = nil
          sampling.continuation.resume(throwing: ScreenSharingError.unavailable("session ended during the sample"))
        }
      }
      if hudEnabled {
        hud?.update(
          lines: RigHUDFormatter.lines(
            sample: latestSample, role: configuration.role, name: name, build: build, peerName: peerName,
            peerBuild: peerBuild, reconnects: reconnects, capture: activeCapture.description,
            tuning: configuration.tuning.label))
      }
      if configuration.role == .viewer { nativeSession.line = nativeSessionLine() }
    }

    func status() -> RigStatus {
      RigStatus(
        role: configuration.role.rawValue, name: name, build: build, connection: session?.connection ?? "none",
        sessionID: session?.id, peerName: peerName, peerBuild: peerBuild, uptimeSeconds: elapsedSeconds,
        reconnects: reconnects, capture: configuration.role == .host ? activeCapture.description : nil,
        hud: hudEnabled, tuning: configuration.tuning.label)
    }

    func metricsBody() async -> RigMetricsBody {
      if configuration.role == .host, let workload = session?.workload {
        session?.metrics.label("workloadResponses", String(workload.view.responses))
      }
      return RigMetricsBody(
        role: configuration.role.rawValue, name: name, build: build, connection: session?.connection ?? "none",
        sessionID: session?.id, capture: configuration.role == .host ? activeCapture.description : nil,
        snapshot: session?.metrics.snapshot(), statistics: latestStatistics, latestSample: latestSample)
    }

    func handleSharedRequest(_ request: RigHTTPRequest) async -> RigHTTPServer.Response? {
      switch (request.method, request.path) {
      case ("GET", "/status"): return .json(200, status())
      case ("GET", "/metrics"): return .json(200, await metricsBody())
      case ("POST", "/hud"):
        guard let body = try? RigJSON.decode(RigHUDRequest.self, from: request.body) else {
          return .error(400, "malformed")
        }
        setHUD(body.enabled)
        return .json(200, RigHUDRequest(enabled: hudEnabled))
      default: return nil
      }
    }
  }
#endif
