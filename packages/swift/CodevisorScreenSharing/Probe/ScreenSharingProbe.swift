#if os(macOS)
  import AppKit
  import CodevisorScreenSharing
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  @preconcurrency import WebRTC

  @main
  @MainActor
  struct ScreenSharingProbe {
    static func main() {
      if CommandLine.arguments.contains("--help") { print(ProbeOptions.usage); return }
      do {
        if CommandLine.arguments.dropFirst().first == "--clock-sync" {
          try ProbeClockSync.run()
          return
        }
        if CommandLine.arguments.dropFirst().first == "--observe-window" {
          let options = try ProbeWindowObservation.Options(arguments: Array(CommandLine.arguments.dropFirst(2)))
          let app = NSApplication.shared
          app.setActivationPolicy(.regular)
          Task { @MainActor in
            do {
              try await ProbeWindowObservation.run(options: options)
              exit(EXIT_SUCCESS)
            } catch {
              FileHandle.standardError.write(Data("Window observation: \(error.localizedDescription)\n".utf8))
              exit(EXIT_FAILURE)
            }
          }
          app.run()
          return
        }
        let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        // This standalone executable owns its process. M152 exposes these experiments through process-wide trials;
        // they are installed once, through the single boundary, before any RTC call.
        try ScreenSharingFieldTrials.process.install(options.fieldTrialSelection)
        let app = NSApplication.shared
        // Headless stays prohibited (no windows); only the owned-window capture
        // mode runs as an accessory so it may own one window without activation.
        app.setActivationPolicy(options.captureOwnedWindow ? .accessory : options.headless ? .prohibited : .regular)
        let runner = ProbeRunner(options: options)
        Task { @MainActor in
          do { try await runner.run(); exit(EXIT_SUCCESS) } catch {
            await runner.stop()
            runner.writeFailureRecord(error)
            FileHandle.standardError.write(Data("Screen Sharing probe: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
          }
        }
        withExtendedLifetime(runner) { app.run() }
      } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }
  }

  @MainActor
  private final class ProbeRunner: NSObject, NSWindowDelegate {
    let options: ProbeOptions
    let senderMetrics = ScreenSharingMetrics()
    let receiverMetrics = ScreenSharingMetrics()
    var sender: ScreenSharingPeer?
    var receiver: ScreenSharingPeer?
    var synthetic: SyntheticSource?
    var capture: ScreenSharingCapture?
    var ownedWorkload: ProbeOwnedWorkloadWindow?
    /// Owned-window mode: bounded first-observed delivery state, nil until
    /// measurement begins; kept on the runner so failure evidence keeps it.
    var firstObservation: ScreenSharingFirstObservation?
    var measurementStartedNs: Int64?
    /// Media start (every mode) on the metrics uptime clock; the event-log diagnostic's measured seconds use it.
    var mediaStartedNs: Int64?
    var picker: ProbeCapturePicker?
    var window: NSWindow?
    var metalView: ScreenSharingMetalView?
    var deliveryAudit: ScreenSharingFrameDeliveryAudit?
    /// Receiver-only diagnostic RTC event-log lifecycle (nil = nothing allocated or scheduled).
    var rtcEventLog: ScreenSharingRtcEventLogDiagnostic?
    /// Sender-only diagnostic RTC event-log lifecycle on the sending peer (nil = nothing allocated or scheduled).
    var senderRtcEventLog: ScreenSharingRtcEventLogDiagnostic?
    /// Outcome of each role's RTC event-log sidecar write made in stop() ("written …" or "write failed: …"); absent = not requested.
    var rtcEventLogSidecarOutcomes: [ScreenSharingRtcEventLogDiagnostic.Role: String] = [:]
    var displayLink: ProbeMetalDisplayLink?
    var encoderLogger: RTCCallbackLogger?

    init(options: ProbeOptions) { self.options = options }

    func run() async throws {
      let build =
        Bundle.main.object(forInfoDictionaryKey: "CodevisorProbeBuildConfiguration") as? String ?? "unspecified"
      senderMetrics.label("probeBuildConfiguration", build)
      receiverMetrics.label("probeBuildConfiguration", build)
      if let window = options.jitterWindowFrames {
        receiverMetrics.label("jitterEstimatorExperiment", "frame-size p95 over \(window) frames")
      }
      // `playoutExperiment` is published by the peer from the INSTALLED trial selection (identical native string),
      // so the label can never describe an option that failed to install.
      if options.requestScreenRecording {
        NSApplication.shared.activate()
        if !CGPreflightScreenCaptureAccess() {
          _ = CGRequestScreenCaptureAccess()
          // Keep the app/run loop alive while the system presents its prompt.
          // Exiting immediately can dismiss the asynchronous permission UI.
          let deadline = ContinuousClock.now.advanced(by: .seconds(options.duration))
          while !CGPreflightScreenCaptureAccess(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
          }
        }
        guard CGPreflightScreenCaptureAccess() else {
          throw ScreenSharingError.unavailable(
            "Allow Screen Sharing Probe in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch."
          )
        }
        print("Screen Recording permission is granted. No capture started.")
        return
      }
      if options.showWorkload {
        try await ProbeDesktopWorkload.run(options: options)
        return
      }
      if options.checkCodecs {
        let configuration = options.configuration
        let report = options.reportURL
        let codecCase = options.codecCase
        try await Task.detached {
          try ProbeCodecCheck.run(configuration: configuration, report: report, caseName: codecCase)
        }.value
        return
      }
      if let host = options.hostCheck {
        try await ProbeHostRecovery(url: host.url, workspace: host.workspace, pane: host.pane).run(
          report: options.reportURL)
        return
      }
      if options.capabilities {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ProbeCapabilities.read())
        if let url = options.reportURL { try data.write(to: url, options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        return
      }
      if options.listDisplays {
        for display in try await ScreenSharingCapture.displays() {
          print("\(display.id): \(display.width) × \(display.height)")
        }
        return
      }
      var pickedFilter: SCContentFilter?
      if options.capturePicker {
        let picker = ProbeCapturePicker()
        self.picker = picker
        pickedFilter = try await picker.choose(window: options.capturePickerWindow)
        senderMetrics.label(
          "captureSelection", options.capturePickerWindow ? "macOS system window picker" : "macOS system display picker"
        )
      }
      // Keep the activity scoped to this finite media run, including error exits.
      // This isolates background scheduling without changing system sleep policy.
      let activity =
        options.userInitiatedActivity
        ? ProcessInfo.processInfo.beginActivity(
          options: .userInitiatedAllowingIdleSystemSleep, reason: "Screen sharing benchmark")
        : nil
      defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
      for metrics in [senderMetrics, receiverMetrics] {
        metrics.label("processActivity", activity == nil ? "none" : "user initiated; idle sleep allowed")
      }
      if options.traceBoundary {
        for metrics in [senderMetrics, receiverMetrics] {
          metrics.enableTracing()
          metrics.label("boundaryTracing", "enabled: bounded refresh/encoder/decoder traces")
        }
      }
      if options.mode != .receive {
        let logger = RTCCallbackLogger()
        if options.traceBoundary { logger.severity = .verbose }
        let metrics = senderMetrics
        let tracing = options.traceBoundary
        logger.start { @Sendable message in
          for (name, count) in ScreenSharingEncoderDropLog.counters(in: message) {
            metrics.increment(name, by: count)
          }
          // Bounded boundary diagnostic: which WebRTC path dropped or held a
          // submitted frame before it reached the native encoder. Addresses are
          // stripped; only the pinned drop/pause messages are retained.
          if tracing, let sanitized = ScreenSharingEncoderDropLog.dropDiagnostic(in: message) {
            metrics.trace("webrtcDropLog", "\(ScreenSharingMetrics.nowNs) \(sanitized)")
          }
        }
        encoderLogger = logger
        sender = try ScreenSharingPeer(
          sending: true, configuration: options.configuration, metrics: senderMetrics,
          useLowLatencyRateControl: !options.standardRateControl, codec: options.videoCodec,
          disableLookAhead: options.disableLookAhead, maximumPendingFrames: options.encoderInFlight,
          maintainSourceRate: options.maintainSourceRate, staticCodecRate: options.staticCodecRate,
          completeEachFrame: options.completeEachFrame, prioritizeSpeed: options.prioritizeSpeed,
          keyframeIntervalSeconds: options.keyframeIntervalSeconds,
          sourceIdleThresholdNs: options.idleThresholdMs.map { Int64($0) * 1_000_000 })
        if let threshold = options.idleThresholdMs {
          senderMetrics.label("sourceIdleThresholdExperiment", "\(threshold) ms idle threshold")
        }
        sender?.onConnectionChanged = { print("Sender: \($0)") }
        if let window = options.senderRtcEventLogWindow, let path = options.senderRtcEventLogPath, let peer = sender {
          // Sender-only diagnostic: the same lifecycle on the sending peer (bracket A on its own start/stop calls).
          let log = ScreenSharingRtcEventLogDiagnostic(
            window: try .init(beginSeconds: window.beginSeconds, durationSeconds: window.durationSeconds), path: path,
            role: .sender,
            boundaries: .init(
              clock: { ScreenSharingRtcEventLogDiagnostic.defaultClock() },
              start: { path, maxSizeBytes in peer.startRtcEventLog(path: path, maxSizeBytes: maxSizeBytes) },
              stop: { peer.stopRtcEventLog() }))
          senderRtcEventLog = log
          senderMetrics.label(
            "rtcEventLog",
            "sender window begin \(log.window.beginSeconds) s duration \(log.window.durationSeconds) s, cap \(log.maxSizeBytes) B, bracket A (CA before/after start and stop); outgoing events at the post-pacer transport hand-off"
          )
        }
      }
      if options.mode != .send {
        // Receiver-only diagnostic frame-delivery audit: allocated only when requested; nil means no work anywhere.
        let deliveryAudit = try options.deliveryAuditWindow.map { window in
          ScreenSharingFrameDeliveryAudit(
            window: try .init(beginSeconds: window.beginSeconds, durationSeconds: window.durationSeconds))
        }
        self.deliveryAudit = deliveryAudit
        if let deliveryAudit {
          receiverMetrics.label(
            "deliveryAudit",
            "window begin \(deliveryAudit.window.beginSeconds) s duration \(deliveryAudit.window.durationSeconds) s, capacity \(deliveryAudit.capacity) records × \(ScreenSharingFrameDeliveryAudit.recordByteStride) B"
          )
        }
        let receiver = try ScreenSharingPeer(
          sending: false, configuration: options.configuration, metrics: receiverMetrics, codec: options.videoCodec,
          deliveryGrace: options.idleGraceMs.map { .milliseconds($0) },
          deliveryGraceExtensions: options.idleGraceExtensions, frameDeliveryAudit: deliveryAudit)
        if let grace = options.idleGraceMs {
          receiverMetrics.label("sourceIdleGraceExperiment", "\(grace) ms delivery grace")
        }
        if let extensions = options.idleGraceExtensions {
          receiverMetrics.label("sourceIdleGraceExtensionExperiment", "up to \(extensions) progress extensions")
        }
        self.receiver = receiver
        if let window = options.rtcEventLogWindow, let path = options.rtcEventLogPath {
          // Bracket A only: the two synchronous shipped API calls through the peer's narrow boundary, timed on
          // CACurrentMediaTime by the diagnostic itself; driven from the measurement ticks below.
          let log = ScreenSharingRtcEventLogDiagnostic(
            window: try .init(beginSeconds: window.beginSeconds, durationSeconds: window.durationSeconds), path: path,
            boundaries: .init(
              clock: { ScreenSharingRtcEventLogDiagnostic.defaultClock() },
              start: { path, maxSizeBytes in receiver.startRtcEventLog(path: path, maxSizeBytes: maxSizeBytes) },
              stop: { receiver.stopRtcEventLog() }))  // Bool: true only when the native stop API ran
          rtcEventLog = log
          receiverMetrics.label(
            "rtcEventLog",
            "window begin \(log.window.beginSeconds) s duration \(log.window.durationSeconds) s, cap \(log.maxSizeBytes) B, bracket A (CA before/after start and stop)"
          )
        }
        if options.checkRecovery {
          receiver.simulateDecoderLoss(
            afterFrames: 120, droppingRecoveryKeyframeFrom: options.dropRecoveryKeyframe ? sender : nil,
            idlingCaptureFrom: options.idleOnDecoderReset ? sender : nil)
        }
        receiver.onConnectionChanged = { print("Receiver: \($0)") }
        if options.headless {
          receiverMetrics.label("presentationTelemetry", "disabled: headless media check")
        } else {
          let view = try ScreenSharingMetalView(
            mailbox: receiver.mailbox, metrics: receiverMetrics, renderOnArrival: options.renderOnArrival,
            maximumDrawableCount: options.drawableCount, unsyncedPresentation: options.unsyncedPresentation,
            offMainPreparation: options.renderOffMain, deliveryAudit: deliveryAudit)
          receiverMetrics.label("renderScheduling", options.renderOnArrival ? "frame arrival" : "display link")
          if let renderFPS = options.renderFPS { view.preferredFramesPerSecond = renderFPS }
          receiverMetrics.label("renderRequestedFPS", String(view.preferredFramesPerSecond))
          let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.delegate = self
          window.title = "Codevisor · Native Screen Sharing Probe"
          if options.keepFront {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
          }
          window.contentView = view
          window.center()
          if let displayID = options.viewerDisplayID {
            guard
              let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              })
            else { throw ScreenSharingError.invalid("The requested viewer display is no longer attached.") }
            window.setFrameOrigin(
              NSPoint(
                x: screen.visibleFrame.midX - window.frame.width / 2,
                y: screen.visibleFrame.midY - window.frame.height / 2))
          }
          window.makeKeyAndOrderFront(nil)
          NSApplication.shared.activate()
          if let report = options.reportURL {
            let ready: [String: Any] = [
              "windowID": window.windowNumber,
              "displayID": (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                ?? 0,
              "widthPoints": window.frame.width, "heightPoints": window.frame.height,
              "contentWidthPoints": view.bounds.width, "contentHeightPoints": view.bounds.height,
              "contentTopPoints": window.frame.height - view.bounds.height,
              "backingScaleFactor": window.backingScaleFactor,
            ]
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".viewer-ready.json"), options: .atomic)
          }
          self.window = window
          metalView = view
          if options.metalDisplayLink {
            displayLink = try ProbeMetalDisplayLink(
              view: view, framesPerSecond: options.renderFPS ?? options.configuration.framesPerSecond)
          }
        }
      }
      switch options.mode {
      case .loopback:
        guard let sender, let receiver else { throw ScreenSharingError.invalid("Missing loopback peers.") }
        // Exercise the product flow: the viewer initiates negotiation.
        try await sender.accept(receiver.makeDescription(offer: true))
        try await receiver.accept(sender.makeDescription(offer: false))
      case .send:
        guard let sender, let offer = options.offerURL, let answer = options.answerURL else { return }
        guard !FileManager.default.fileExists(atPath: answer.path) else {
          throw ScreenSharingError.invalid("Answer file already exists; use fresh signaling paths for each session.")
        }
        try writeDescription(await sender.makeDescription(offer: true), to: offer)
        print("Offer written to \(offer.path). Exchange files over a trusted channel. Waiting for \(answer.path).")
        try await waitUntil(seconds: 120) { FileManager.default.fileExists(atPath: answer.path) }
        try await sender.accept(readDescription(answer))
      case .receive:
        guard let receiver, let offer = options.offerURL, let answer = options.answerURL else { return }
        try await receiver.accept(readDescription(offer))
        try writeDescription(await receiver.makeDescription(offer: false), to: answer)
        print("Answer written to \(answer.path). Send it to the sender over a trusted channel.")
      }
      try await waitUntil(seconds: 120) { [self] in
        (sender == nil || senderMetrics.snapshot().labels["connection"] == "connected")
          && (receiver == nil || receiverMetrics.snapshot().labels["connection"] == "connected")
      }
      if let sender {
        if options.captureOwnedWindow {
          // One owned window, shown without activation; capture starts only
          // after its first draw completed and it is confirmed visible.
          let capture = ScreenSharingCapture(
            queueDepth: options.captureQueueDepth, pixelFormat: options.capturePixelFormat,
            copySurface: options.copyCaptureSurface, captureIntervalFPS: options.captureIntervalFPS)
          self.capture = capture
          let workload = try ProbeOwnedWorkloadWindow(
            configuration: options.configuration, recordDrawTimes: options.recordOwnedWorkloadTimes
          ) {
            try await capture.stop()
          }
          ownedWorkload = workload
          // show → first draw (cancellation-safe gate) → visible → capture start;
          // any failure hides only this window once and surfaces the error.
          var beforeStart: [String: Any] = [:]
          var ready = try await workload.start(timeoutSeconds: 10) {
            // Immediately before OUR capture.start call; the framework's own
            // SCStream.start moment is not observable without shared changes.
            beforeStart = workload.observation("immediately before capture.start (probe call, not the framework start)")
            try await capture.start(
              ownedWindowID: workload.windowID, configuration: options.configuration,
              sender: sender.frameSender, metrics: senderMetrics)
          }
          ready["observationBeforeCaptureStart"] = beforeStart  // also retained in workload.snapshots
          var afterStart = workload.observation("after capture.start returned")
          let startLabels = senderMetrics.snapshot().labels
          afterStart["sckSelectionAndStartLabels"] = Dictionary(
            uniqueKeysWithValues: startLabels.filter { $0.key.hasPrefix("capture") }.map { ($0.key, $0.value) })
          ready["observationAfterCaptureStart"] = afterStart
          if let report = options.reportURL {
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".workload-ready.json"), options: .atomic)
          }
          senderMetrics.label("ownedWorkloadWindowID", String(workload.windowID))
          senderMetrics.label("ownedWorkloadReadyAtNs", String(workload.lifecycle.timestampsNs[.ready] ?? 0))
          print(
            "Owned workload window \(workload.windowID) is being captured through ScreenCaptureKit; no viewer rendering."
          )
        } else if let pickedFilter {
          let capture = ScreenSharingCapture(
            queueDepth: options.captureQueueDepth, pixelFormat: options.capturePixelFormat,
            copySurface: options.copyCaptureSurface, captureIntervalFPS: options.captureIntervalFPS)
          self.capture = capture
          try await capture.start(
            pickedFilter: pickedFilter, configuration: options.configuration,
            sender: sender.frameSender, metrics: senderMetrics)
        } else if let display = options.displayID {
          let capture = ScreenSharingCapture(
            queueDepth: options.captureQueueDepth, pixelFormat: options.capturePixelFormat,
            copySurface: options.copyCaptureSurface, captureIntervalFPS: options.captureIntervalFPS)
          self.capture = capture
          try await capture.start(
            displayID: display, configuration: options.configuration,
            sender: sender.frameSender, metrics: senderMetrics)
        } else {
          let source = try SyntheticSource(
            configuration: options.configuration,
            sender: sender.frameSender, metrics: senderMetrics, pixelFormat: options.syntheticPixelFormat,
            desktopPattern: options.desktopPattern, gapMilliseconds: options.syntheticGapMs)
          synthetic = source
          source.start()
        }
      }
      if let sender, let receiver {
        try await ProbeControlCheck(host: sender.control, viewer: receiver.control).run()
        senderMetrics.label("controlChannel", "ordered input and release verified")
        print("Control channel: eight input events and release acknowledged; no OS input posted.")
        try await ProbeClipboardCheck(host: sender.clipboard, viewer: receiver.clipboard).run()
        senderMetrics.label("clipboardChannel", "bidirectional chunked Unicode transfer verified")
        print("Clipboard channel: bidirectional Unicode transfer verified; no system clipboard accessed.")
      }
      if options.checkQuality { try await checkQuality() }
      print(
        "Measuring \(options.duration) seconds of \(options.configuration.width)×\(options.configuration.height) video."
      )
      let started = ScreenSharingMetrics.nowNs
      mediaStartedNs = started
      let startedAtSeconds = CACurrentMediaTime()
      for metrics in [senderMetrics, receiverMetrics] { metrics.label("mediaStartUptimeNs", String(started)) }
      // The audit window is relative to this media start on the audit's own clock (CACurrentMediaTime).
      deliveryAudit?.start(originNs: Int64(startedAtSeconds * 1_000_000_000))
      // The event-log diagnostics' first tick is the media-start boundary itself (a begin of 0 starts here).
      rtcEventLog?.tick(measuredSeconds: 0)
      senderRtcEventLog?.tick(measuredSeconds: 0)
      // Relay checks require this exact capability; absent counters are never zero.
      receiverMetrics.label("idleAuditInstrumentation", "demand-attribution-1")
      if let report = options.reportURL {
        // Both clocks are read back to back so a relay can verify that the
        // Core Animation and Dispatch uptime clocks agree within this process.
        let ready: [String: Any] = [
          "startedAtSeconds": startedAtSeconds, "startedAtUptimeNs": started,
          "startedAtMediaTimeNs": Int64(CACurrentMediaTime() * 1_000_000_000),
          // Backward compatible: existing keys unchanged; the meaning is now explicit.
          "meaning":
            "SETUP readiness: peers connected and the source (synthetic, display, picked or owned-window stream) started; not a first captured, encoded or decoded frame",
        ]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
          .write(to: URL(fileURLWithPath: report.path + ".media-ready.json"), options: .atomic)
      }
      var transport = ProbeTransportTimeline()
      transport.append(
        elapsed: 0, sender: await sender?.statistics() ?? [:], receiver: await receiver?.statistics() ?? [:])
      var timeline = ProbeTimeline()
      timeline.append(
        elapsed: 0, sender: senderMetrics.snapshot(), receiver: receiverMetrics.snapshot(),
        drops: receiver?.mailbox.droppedFrames ?? 0)
      try timeline.writeProgress(to: options.reportURL)
      var measured = 0.0
      var sourcePausedAt: Double?
      var workloadPausedAt: Double?
      // Owned-window mode: first-observed delivery over measurement ticks (bounded, one entry per metric),
      // kept on the runner so failure evidence retains what was already seen.
      if options.captureOwnedWindow {
        firstObservation = ScreenSharingFirstObservation(names: [
          "anyCallbackIncludingInvalidOrMissingStatus", "completeStatusCallbacks", "acceptedCapturedFrames",
          "decodedFrames",
        ])
        measurementStartedNs = started
      }
      try recordFirstObservation(elapsedSeconds: measured)  // initial counter observation at tick 0
      var idleCheckpointTaken = false
      var settlingCheckpointAtSeconds: Double?
      let settlingCounters = [
        (
          senderMetrics,
          ["capturedFrames", "encodedFrames", "refreshFrames", "videoRefreshRequestsReceived", "sourceIdleEvaluations"]
        ),
        (receiverMetrics, ["videoRefreshRequestsSent"]),
      ]
      while measured < options.duration {
        // The event-log diagnostic borrows these ticks: the sleep is shortened to its next requested boundary so
        // the start/stop calls happen at the first tick at or after it (requested and actual are both recorded).
        let boundaries = [rtcEventLog?.nextBoundarySeconds(), senderRtcEventLog?.nextBoundarySeconds()]
          .compactMap { $0 }
        try await Task.sleep(
          for: .seconds(
            ScreenSharingRtcEventLogDiagnostic.sleepSeconds(
              measured: measured, remaining: options.duration - measured, nextBoundary: boundaries.min())))
        measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
        rtcEventLog?.tick(measuredSeconds: measured)
        senderRtcEventLog?.tick(measuredSeconds: measured)
        if let pauseAfter = options.pauseSourceAfterSeconds, sourcePausedAt == nil, measured >= pauseAfter {
          if options.finalBurstSignal, let report = options.reportURL {
            // Announce that the final changing content follows, keep producing it
            // briefly, then stop. A loss relay coordinates its drop window on this.
            let signal: [String: Any] = [
              "signalAtSeconds": CACurrentMediaTime(), "measuredSeconds": measured, "continueMilliseconds": 250,
            ]
            try JSONSerialization.data(withJSONObject: signal, options: [.sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".final-burst.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(250))
          }
          synthetic?.stop()
          senderMetrics.label("sourcePausedAtMediaTimeSeconds", String(CACurrentMediaTime()))
          measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
          sourcePausedAt = measured
          if let report = options.reportURL {
            // The source has drained (stop waits for its queue); a relay may end
            // a coordinated drop window shortly after observing this file.
            let paused: [String: Any] = [
              "pausedAtSeconds": CACurrentMediaTime(), "pausedAtUptimeNs": ScreenSharingMetrics.nowNs,
              "measuredSeconds": measured,
              "latestCapturedTimestampNs": senderMetrics.snapshot().labels["latestCapturedTimestampNs"] ?? "none",
            ]
            try JSONSerialization.data(withJSONObject: paused, options: [.sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".source-paused.json"), options: .atomic)
          }
          senderMetrics.label("sourceIdleExperiment", "synthetic input stopped; observe automatic idle output")
          senderMetrics.label("sourcePausedAtSeconds", String(measured))
          senderMetrics.increment("sourcePauseEvents")
        }
        if let pauseAfter = options.pauseWorkloadAfterSeconds, workloadPausedAt == nil, measured >= pauseAfter,
          let workload = ownedWorkload
        {
          // Only the animation stops; the window and its last frame remain on
          // screen and remain the captured content. The stream is not touched.
          var record = try workload.pauseAnimation()
          measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
          workloadPausedAt = measured
          sourcePausedAt = measured  // idle-checkpoint accounting only; not a pass criterion here
          let snapshot = senderMetrics.snapshot()
          record["measuredSeconds"] = measured
          record["capturedFramesAtPause"] = snapshot.counters["capturedFrames", default: 0]
          record["captureCallbacksCompleteAtPause"] = snapshot.counters["captureCallbacksComplete", default: 0]
          record["latestCapturedTimestampNs"] = snapshot.labels["latestCapturedTimestampNs"] ?? "none"
          if let report = options.reportURL {
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".workload-paused.json"), options: .atomic)
          }
          senderMetrics.label("sourceIdleExperiment", "owned workload animation paused; static window remains captured")
          senderMetrics.label("sourcePausedAtSeconds", String(measured))
          senderMetrics.label("workloadPausedAtSeconds", String(measured))
          senderMetrics.label("workloadPausedAtMediaTimeSeconds", String(CACurrentMediaTime()))
          senderMetrics.increment("workloadPauseEvents")
        }
        if options.idleOnDecoderReset, sourcePausedAt == nil,
          receiverMetrics.snapshot().counters["recoveryKeyframesReceived", default: 0] == 1
        {
          sourcePausedAt = measured
          senderMetrics.label("idleRecoveryObservedAtSeconds", String(measured))
        }
        if let sourcePausedAt, !idleCheckpointTaken, measured >= sourcePausedAt + 2 {
          let snapshot = senderMetrics.snapshot()
          senderMetrics.increment("capturedFramesAtIdleCheckpoint", by: snapshot.counters["capturedFrames", default: 0])
          senderMetrics.increment("encodedFramesAtIdleCheckpoint", by: snapshot.counters["encodedFrames", default: 0])
          senderMetrics.increment("refreshFramesAtIdleCheckpoint", by: snapshot.counters["refreshFrames", default: 0])
          senderMetrics.increment(
            "videoRefreshRequestsReceivedAtIdleCheckpoint",
            by: snapshot.counters["videoRefreshRequestsReceived", default: 0])
          receiverMetrics.increment(
            "videoRefreshRequestsSentAtIdleCheckpoint",
            by: receiverMetrics.snapshot().counters["videoRefreshRequestsSent", default: 0])
          senderMetrics.label("idleCheckpointAtSeconds", String(measured))
          idleCheckpointTaken = true
        }
        // Recovery may legitimately continue after the idle checkpoint (a
        // blackout); the final three seconds must then be genuinely quiet.
        // Every headless peer records the window so a separate-process
        // experiment can verify both ends.
        if options.headless, settlingCheckpointAtSeconds == nil, measured >= options.duration - 3 {
          for (metrics, names) in settlingCounters {
            let snapshot = metrics.snapshot()
            for name in names {
              metrics.increment(name + "AtSettlingCheckpoint", by: snapshot.counters[name, default: 0])
            }
            metrics.label("settlingCheckpointAtSeconds", String(measured))
          }
          settlingCheckpointAtSeconds = measured
        }
        try recordFirstObservation(elapsedSeconds: measured)
        transport.append(
          elapsed: measured, sender: await sender?.statistics() ?? [:], receiver: await receiver?.statistics() ?? [:])
        if measured - (timeline.samples.last?.elapsedSeconds ?? 0) >= Double(options.sampleIntervalSeconds)
          || measured >= options.duration
        {
          timeline.append(
            elapsed: measured, sender: senderMetrics.snapshot(), receiver: receiverMetrics.snapshot(),
            drops: receiver?.mailbox.droppedFrames ?? 0)
          try timeline.writeProgress(to: options.reportURL)
          print("Measurement progress: \(Int(measured)) / \(Int(options.duration)) seconds")
        }
      }
      // Normal completion: each event log is stopped exactly once here, before any peer teardown.
      rtcEventLog?.finish(measuredSeconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000)
      senderRtcEventLog?.finish(measuredSeconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000)
      synthetic?.stop()
      if let workload = ownedWorkload {
        // Boundary order: stream stop through the session (success or failure
        // preserved; the lifecycle advances only on success), then the window
        // closes during stop(); both are in the report and the after-close file.
        let stopped = await workload.stopCapture()
        guard stopped else {
          throw ScreenSharingError.unavailable(
            "Capture stop failed: \(senderMetrics.snapshot().labels["captureStopFailed"] ?? "unknown error").")
        }
      } else {
        try await capture?.stop()
      }
      if let workload = ownedWorkload {
        measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
        try recordFirstObservation(elapsedSeconds: measured)  // final post-stop observation
        publishFirstObservationLabels()
        let snapshot = senderMetrics.snapshot()
        var stopped: [String: Any] = [
          "captureStopRequestedAtNs": snapshot.labels["captureStopRequestedAtNs"] ?? "none",
          "captureStopCompletedAtNs": snapshot.labels["captureStopCompletedAtNs"] ?? "none",
          "capturedFrames": snapshot.counters["capturedFrames", default: 0],
          "lifecycle": workload.lifecycleRecord,
          "observationAfterStop": workload.observation("after capture stop completed"),
          "firstObservations": firstObservation?.summary ?? "measurement never began",
        ]
        for name in ScreenSharingCaptureCallbackAccounting.Status.allCases.map(\.counterName)
          + [
            ScreenSharingCaptureCallbackAccounting.otherStatusCounter,
            ScreenSharingCaptureCallbackAccounting.invalidSampleCounter,
            ScreenSharingCaptureCallbackAccounting.missingStatusCounter,
            ScreenSharingCaptureCallbackAccounting.missingImageCounter,
          ]
        {
          stopped[name] = snapshot.counters[name, default: 0]
        }
        if let report = options.reportURL {
          try JSONSerialization.data(withJSONObject: stopped, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report.path + ".capture-stopped.json"), options: .atomic)
          if let times = workload.workloadTimesReport(mediaMeasuredSeconds: measured) {
            try JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".workload-times.json"), options: .atomic)
          }
        }
      }
      let elapsed = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
      let senderStats = await sender?.statistics() ?? [:]
      let receiverStats = await receiver?.statistics() ?? [:]
      if options.headless, let latest = receiver?.mailbox.take() {
        receiverMetrics.label("latestReceivedRtpTimestamp", String(latest.rtpTimestamp))
      }
      let sent = senderMetrics.snapshot()
      let received = receiverMetrics.snapshot()
      // After the checkpoint the host may encode only cache refreshes, each
      // answering a viewer request received after the checkpoint; a viewer in
      // this process may request one only after a verified delivery shortfall
      // (transport loss before idle). Without loss nothing continues.
      func sinceCheckpoint(_ snapshot: ScreenSharingMetrics.Snapshot, _ name: String) -> Int {
        snapshot.counters[name, default: 0] - snapshot.counters[name + "AtIdleCheckpoint", default: 0]
      }
      func settled(_ snapshot: ScreenSharingMetrics.Snapshot, _ name: String) -> Bool {
        snapshot.counters[name, default: 0] == snapshot.counters[name + "AtSettlingCheckpoint", default: 0]
      }
      // A late checkpoint (delayed loop) must not pass with an unobserved window.
      let settlingObserved = settlingCheckpointAtSeconds.map { elapsed - $0 >= 2 } ?? false
      let idleObservationPassed =
        (options.pauseSourceAfterSeconds == nil && !options.idleOnDecoderReset)
        || (idleCheckpointTaken && sinceCheckpoint(sent, "capturedFrames") == 0
          && sinceCheckpoint(sent, "encodedFrames") <= sinceCheckpoint(sent, "refreshFrames")
          && sinceCheckpoint(sent, "refreshFrames") <= sinceCheckpoint(sent, "videoRefreshRequestsReceived")
          && (received.counters["sourceIdleRefreshRequests", default: 0] > 0
            || sinceCheckpoint(received, "videoRefreshRequestsSent") == 0)
          && settlingObserved
          && settlingCounters.allSatisfy { metrics, names in
            let snapshot = metrics === senderMetrics ? sent : received
            return names.allSatisfy { settled(snapshot, $0) }
          })
      let idleResetPassed =
        !options.idleOnDecoderReset || sent.counters["captureDeliveryStoppedAtDecoderReset", default: 0] == 1
      let encoderRetryPassed =
        !options.dropRecoveryKeyframe
        || (sent.counters["injectedEncoderKeyframeDrops", default: 0] == 1
          && sent.counters["encoderRetriedKeyframes", default: 0] >= 1
          // The idle retry intentionally creates another request. Retention
          // without a new request is covered by the encoder state tests.
          && sent.counters["encoderForcedKeyframesSubmitted", default: 0] >= 3)
      let recoveryPassed =
        !options.checkRecovery
        || (received.counters["injectedDecoderResets", default: 0] == 1
          && received.counters["recoveryKeyframesReceived", default: 0] == 1
          && received.counters["decodedFrames", default: 0] >= (options.idleOnDecoderReset ? 120 : 126)
          && (options.headless || received.counters["presentedFrames", default: 0] >= 126)
          && (received.timings["decoderResetToRecoveryKeyframe"]?.maximumMs ?? .infinity) < 2000)
      // Owned-window mode passes on delivered media, no errors, a recorded
      // pause when one was requested, and a completed capture stop. Idle
      // behaviour after the pause is recorded, not judged, in this mode.
      let ownedWindowPassed =
        !options.captureOwnedWindow
        || (sent.labels["captureStartedAtNs"] != nil && sent.labels["captureStopCompletedAtNs"] != nil
          && sent.counters["captureCallbacksComplete", default: 0] > 0
          && (options.pauseWorkloadAfterSeconds == nil || workloadPausedAt != nil))
      let passed =
        ownedWindowPassed
        && (sender == nil || sent.counters["encodedFrames", default: 0] > 0)
        && (receiver == nil
          || received.counters[options.headless ? "decodedFrames" : "presentedFrames", default: 0] > 0)
        && sent.labels["captureError"] == nil && sent.labels["encoderError"] == nil
        && received.labels["decoderError"] == nil
        && sent.counters["encodeErrors", default: 0] == 0 && received.counters["decodeErrors", default: 0] == 0
        && sent.counters["syntheticDrawErrors", default: 0] == 0
        && sent.counters["syntheticConversionErrors", default: 0] == 0
        && received.counters["renderErrors", default: 0] == 0
        && recoveryPassed
        && encoderRetryPassed
        && idleObservationPassed
        && idleResetPassed
      let report = ProbeReport(
        mode: options.mode, configuration: options.configuration,
        source: options.mode == .receive
          ? "remote"
          : options.captureOwnedWindow
            ? "ScreenCaptureKit owned window"
            : (options.displayID != nil || options.capturePicker) ? "ScreenCaptureKit" : "synthetic",
        startedAtSeconds: startedAtSeconds, elapsedSeconds: elapsed,
        passed: passed, renderingEnabled: receiver != nil && !options.headless, sender: sent,
        receiver: received,
        senderRTC: senderStats, receiverRTC: receiverStats,
        rendererMailboxDrops: receiver?.mailbox.droppedFrames ?? 0,
        presentedFramesPerSecond: Double(
          received.counters["presentedFrames", default: 0]
            - (timeline.samples.first?.receiver.counters["presentedFrames"] ?? 0)) / elapsed,
        timeline: timeline.samples, transportTimeline: transport.samples,
        receiverDeliveryAudit: deliveryAudit?.snapshot(), receiverRtcEventLog: rtcEventLog?.record,
        senderRtcEventLog: senderRtcEventLog?.record)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(report)
      if let url = options.reportURL { try data.write(to: url, options: .atomic) }
      print(String(decoding: data, as: UTF8.self))
      let cacheHeldBeforeClose = sender?.frameSender.isHoldingCachedFrame
      await stop()
      // Close check in three observations: immediately after close (tasks
      // cancelled, not yet awaited), after each peer's owned work completed,
      // and after a bounded 500 ms observation window. It fails the run when
      // the cache or mailbox is still held or a tracked counter moved during
      // that window. Only owned main-actor tasks are awaited; WebRTC and
      // VideoToolbox threads are outside this boundary.
      func observation() throws -> [String: Any] {
        let sent = senderMetrics.snapshot()
        let received = receiverMetrics.snapshot()
        return [
          "cacheHeld": sender?.frameSender.isHoldingCachedFrame ?? false,
          "mailboxHeld": receiver?.mailbox.isHolding ?? false,
          "encoderPendingAtStop": sent.labels["encoderPendingAtStop"] ?? "not observed",
          "sender": try JSONSerialization.jsonObject(with: encoder.encode(sent)),
          "receiver": try JSONSerialization.jsonObject(with: encoder.encode(received)),
        ]
      }
      let immediate = try observation()
      let senderTasks = await sender?.awaitClosed()
      let receiverTasks = await receiver?.awaitClosed()
      let drained = try observation()
      try await Task.sleep(for: .milliseconds(500))
      let settled = try observation()
      let tracked = [
        "capturedFrames", "encodedFrames", "refreshFrames", "sourceIdleEvaluations", "decodedFrames",
        "videoRefreshRequestsSent", "videoRefreshRequestsReceived",
      ]
      func counters(_ observation: [String: Any]) -> [String: Int] {
        var result: [String: Int] = [:]
        for side in ["sender", "receiver"] {
          let values = (observation[side] as? [String: Any])?["counters"] as? [String: Int] ?? [:]
          for name in tracked { result[side + "." + name] = values[name] ?? 0 }
        }
        return result
      }
      let movedCounters = counters(drained).filter { counters(settled)[$0.key] != $0.value }.keys.sorted()
      // An owned-window run must also have closed its window in order after a
      // successful stream stop; an abandoned lifecycle never passes this check.
      let closeCheckPassed =
        movedCounters.isEmpty && settled["cacheHeld"] as? Bool == false && settled["mailboxHeld"] as? Bool == false
        && (ownedWorkload?.session.completedInOrder ?? true)
      let closed: [String: Any] = [
        "applicable": true, "passed": closeCheckPassed,
        "cacheHeldBeforeClose": cacheHeldBeforeClose ?? false,
        "ownedTasksAwaited": ["sender": senderTasks ?? -1, "receiver": receiverTasks ?? -1],
        "immediate": immediate, "afterOwnedWorkDrained": drained, "afterObservationWindow": settled,
        "observationWindowMilliseconds": 500, "trackedCounters": tracked, "movedCounters": movedCounters,
        "rtcEventLogSidecar": rtcEventLogSidecarOutcomes[.receiver] ?? "not requested",
        "senderRtcEventLogSidecar": rtcEventLogSidecarOutcomes[.sender] ?? "not requested",
        "quiescentOverObservationWindow": closeCheckPassed,
        "scope": "owned main-actor tasks awaited; WebRTC and VideoToolbox threads not covered",
        "ownedWorkload": ownedWorkload?.lifecycleRecord ?? "not used",
      ]
      if let url = options.reportURL {
        try JSONSerialization.data(withJSONObject: closed, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: url.path + ".after-close.json"), options: .atomic)
      }
      guard passed else { throw ScreenSharingError.unavailable("Media did not pass the probe. See the metrics above.") }
      guard closeCheckPassed else {
        throw ScreenSharingError.unavailable(
          "Close check failed: cache/mailbox retained, counters moved (\(movedCounters.joined(separator: ", ")))"
            + " or the owned window did not close in order.")
      }
    }

    func deliveryValues() -> [String: Int] {
      let sent = senderMetrics.snapshot().counters
      let received = receiverMetrics.snapshot().counters
      return [
        // Every callback bucket once; captureSamplesWithoutImage is a sub-count of complete and is NOT added.
        "anyCallbackIncludingInvalidOrMissingStatus": ScreenSharingCaptureCallbackAccounting.callbackTotal(
          counters: sent),
        "completeStatusCallbacks": sent["captureCallbacksComplete", default: 0],
        "acceptedCapturedFrames": sent["capturedFrames", default: 0],
        "decodedFrames": received["decodedFrames", default: 0],
      ]
    }

    /// One tick of first-observed delivery; writes the first-callback /
    /// first-frame sidecars the first time their metric becomes non-zero.
    func recordFirstObservation(elapsedSeconds: Double) throws {
      guard firstObservation != nil else { return }
      let values = deliveryValues()
      let newly = firstObservation!.record(elapsedSeconds: elapsedSeconds, values: values)
      guard let report = options.reportURL else { return }
      for name in newly {
        let sidecar: String? =
          name == "anyCallbackIncludingInvalidOrMissingStatus"
          ? "first-callback" : name == "acceptedCapturedFrames" ? "first-frame" : nil
        guard let sidecar else { continue }
        let record: [String: Any] = [
          "metric": name, "observedAtSeconds": elapsedSeconds, "tick": (firstObservation?.ticks ?? 1) - 1,
          "values": values,
          "resolution": ScreenSharingFirstObservation.resolution,
          "definition": sidecar == "first-frame"
            ? "first measurement tick with capturedFrames > 0 (frames ACCEPTED by the sender), not merely a complete-status callback"
            : "first measurement tick with any SCK callback counter > 0, including invalid/missing-status samples",
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: report.path + ".\(sidecar).json"), options: .atomic)
      }
    }

    func publishFirstObservationLabels() {
      guard let firstObservation else { return }
      for (name, metric) in firstObservation.summary {
        senderMetrics.label(
          "firstObserved." + name, metric["firstObservedAtSeconds"] ?? ScreenSharingFirstObservation.neverObserved)
      }
      senderMetrics.label("firstObservedResolution", ScreenSharingFirstObservation.resolution)
    }

    /// The final event-log record: the diagnostic's own when it was constructed, otherwise (options requested a
    /// log but the probe failed earlier) an explicit not-initialized record; nil when no log was requested.
    func rtcEventLogRecord(
      role: ScreenSharingRtcEventLogDiagnostic.Role, reason: String
    ) -> ScreenSharingRtcEventLogDiagnostic.Record? {
      let log = role == .receiver ? rtcEventLog : senderRtcEventLog
      if let log { return log.record }
      let window = role == .receiver ? options.rtcEventLogWindow : options.senderRtcEventLogWindow
      let path = role == .receiver ? options.rtcEventLogPath : options.senderRtcEventLogPath
      guard let window, let path else { return nil }
      return .notInitialized(
        beginSeconds: window.beginSeconds, durationSeconds: window.durationSeconds, path: path,
        maxSizeBytes: ScreenSharingRtcEventLogDiagnostic.fixedMaxSizeBytes, reason: reason, role: role)
    }

    /// Shared finalization (normal completion, failure, window close): after the actual stop, publish the record
    /// atomically as REPORT.rtc-event-log.json so the brackets and close reason survive even without a report.
    /// A write error is recorded and printed, never a silent success. Idempotent per process.
    func publishRtcEventLogSidecar(role: ScreenSharingRtcEventLogDiagnostic.Role) {
      guard rtcEventLogSidecarOutcomes[role] == nil, let url = options.reportURL,
        let record = rtcEventLogRecord(role: role, reason: "probe stopped before the peer and the log were constructed")
      else { return }
      let suffix = role == .receiver ? ".rtc-event-log.json" : ".sender-rtc-event-log.json"
      let sidecar = URL(fileURLWithPath: url.path + suffix)
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: sidecar, options: .atomic)
        rtcEventLogSidecarOutcomes[role] = "written \(sidecar.path)"
      } catch {
        rtcEventLogSidecarOutcomes[role] = "write failed: \(error.localizedDescription)"
        FileHandle.standardError.write(
          Data("RTC event log sidecar (\(role.rawValue)): \(rtcEventLogSidecarOutcomes[role] ?? "")\n".utf8))
      }
    }

    /// The role's final event-log record as a JSON object for the failure record; nil when no log was requested.
    func failureRecordJSON(role: ScreenSharingRtcEventLogDiagnostic.Role) -> Any? {
      let reason = "probe failed before the peer and the log were constructed"
      guard let record = rtcEventLogRecord(role: role, reason: reason) else { return nil }
      return (try? JSONEncoder().encode(record)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Durable failure evidence: written after cleanup on any failed run so the
    /// original error, a stop failure, the owned window's real lifecycle, every
    /// snapshot already taken (readiness / before-start / after-start / pause /
    /// stop) and the first-observed delivery state survive even when the normal
    /// report was never written. A final observation is taken only if
    /// measurement had begun; elapsed times are never invented.
    func writeFailureRecord(_ error: any Error) {
      guard let url = options.reportURL else { return }
      if firstObservation != nil, let startedNs = measurementStartedNs {
        try? recordFirstObservation(elapsedSeconds: Double(ScreenSharingMetrics.nowNs - startedNs) / 1_000_000_000)
        publishFirstObservationLabels()
      }
      let sent = senderMetrics.snapshot()
      let record: [String: Any] = [
        "failure": error.localizedDescription, "failedAtUptimeNs": ScreenSharingMetrics.nowNs,
        "reportWritten": FileManager.default.fileExists(atPath: url.path),
        "captureStopFailed": sent.labels["captureStopFailed"] ?? "none",
        "captureStopCompletedAtNs": sent.labels["captureStopCompletedAtNs"] ?? "none",
        "captureError": sent.labels["captureError"] ?? "none",
        "ownedWorkload": ownedWorkload?.lifecycleRecord ?? "not used",
        "ownedWorkloadCleanup": sent.labels["ownedWorkloadCleanup"] ?? "none",
        "firstObservations": firstObservation?.summary ?? "measurement never began",
        "firstObservationTicks": firstObservation?.ticks ?? 0,
        "snapshots": ownedWorkload?.snapshots ?? "not used",
        "observationAtFailure": ownedWorkload?.observation("failure record (after cleanup)") ?? "not used",
        // The event-log diagnostic record survives a failure (stop() already closed it before peer teardown and
        // published the sidecar); a request that never reached construction is stated as not initialized.
        "rtcEventLog": failureRecordJSON(role: .receiver) ?? "not requested",
        "rtcEventLogSidecar": rtcEventLogSidecarOutcomes[.receiver] ?? "not requested",
        "senderRtcEventLog": failureRecordJSON(role: .sender) ?? "not requested",
        "senderRtcEventLogSidecar": rtcEventLogSidecarOutcomes[.sender] ?? "not requested",
      ]
      try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: url.path + ".failure.json"), options: .atomic)
      // Draw timestamps already recorded survive a failure too (same schema, marked partial).
      if let workload = ownedWorkload,
        var times = workload.workloadTimesReport(
          mediaMeasuredSeconds: measurementStartedNs.map { Double(ScreenSharingMetrics.nowNs - $0) / 1_000_000_000 }
            ?? 0)
      {
        times["partial"] = true
        try? JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: url.path + ".workload-times.json"), options: .atomic)
      }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      Task { @MainActor in
        await stop(); exit(EXIT_SUCCESS)
      }
      return false
    }

    func stop() async {
      synthetic?.stop()
      synthetic = nil
      if ownedWorkload == nil { try? await capture?.stop() }
      if let workload = ownedWorkload {
        // Every exit path (normal, error, cancel) goes through one boundary:
        // the stop is credited only when the session recorded a successful
        // stream stop; the window closes in order or is abandoned; only this
        // window is ever hidden, at most once. A stop never attempted (error
        // before the normal end) is attempted here and its result preserved.
        if workload.lifecycle.state == .capturing || workload.lifecycle.state == .workloadPaused {
          await workload.stopCapture()
        }
        let outcome = workload.cleanUp()
        senderMetrics.label("ownedWorkloadCleanup", String(describing: outcome))
        senderMetrics.label("ownedWorkloadFinalState", workload.lifecycle.state.rawValue)
        if let closed = workload.lifecycle.timestampsNs[.close] {
          senderMetrics.label("ownedWorkloadClosedAtNs", String(closed))
        }
        if let abandoned = workload.lifecycle.timestampsNs[.abandon] {
          senderMetrics.label("ownedWorkloadAbandonedAtNs", String(abandoned))
          senderMetrics.label("ownedWorkloadAbandonedFrom", workload.lifecycle.abandonedFrom?.rawValue ?? "unknown")
        }
      }
      capture = nil
      picker?.stop()
      picker = nil
      // The standalone display link is invalidated before the renderer's
      // terminal stop so no supplied-drawable draw can follow it.
      displayLink?.stop()
      displayLink = nil
      metalView?.stop()
      // Failure, cancellation or early close: stop a started event log exactly once before the peer closes;
      // after a normal completion this is already final and does nothing.
      let measuredAtStop = mediaStartedNs.map { Double(ScreenSharingMetrics.nowNs - $0) / 1_000_000_000 }
      rtcEventLog?.closeEarly(measuredSeconds: measuredAtStop, reason: "runner stop before peer teardown")
      senderRtcEventLog?.closeEarly(measuredSeconds: measuredAtStop, reason: "runner stop before peer teardown")
      publishRtcEventLogSidecar(role: .receiver)
      publishRtcEventLogSidecar(role: .sender)
      sender?.close()
      receiver?.close()
      encoderLogger?.stop()
      encoderLogger = nil
      window?.orderOut(nil)
    }

    private func checkQuality() async throws {
      guard let sender else { return }
      let original = options.configuration
      for (scale, fps) in [(1.0, 30), (0.75, 30), (0.5, 20), (1.0, 60)] {
        let video = try ScreenSharingVideoConfiguration(
          width: max(64, Int(Double(original.width) * scale) / 2 * 2),
          height: max(64, Int(Double(original.height) * scale) / 2 * 2),
          framesPerSecond: min(fps, original.framesPerSecond), bitrate: original.bitrate)
        synthetic?.stop()
        sender.updateVideoConfiguration(video)
        if let capture {
          try await capture.update(configuration: video)
        } else {
          synthetic = try SyntheticSource(
            configuration: video, sender: sender.frameSender, metrics: senderMetrics,
            pixelFormat: options.syntheticPixelFormat, desktopPattern: options.desktopPattern)
          synthetic?.start()
        }
        let frames = receiverMetrics.snapshot().counters["presentedFrames", default: 0]
        try await waitUntil(seconds: 15) { [self] in
          let snapshot = receiverMetrics.snapshot()
          return snapshot.labels["videoSize"] == "\(video.width) × \(video.height)"
            && snapshot.counters["presentedFrames", default: 0] >= frames + 6
        }
        print("Format transition: \(video.width) × \(video.height) at requested \(video.framesPerSecond) fps")
      }
      senderMetrics.label("qualityTransitions", "full30, 75%30, 50%20, full60 verified")
    }

    private func readDescription(_ url: URL) throws -> ScreenSharingDescription {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      let data = try file.read(upToCount: 256 * 1024 + 1) ?? Data()
      guard data.count <= 256 * 1024 else { throw ScreenSharingError.invalid("Signaling file is too large.") }
      return try JSONDecoder().decode(ScreenSharingDescription.self, from: data)
    }

    private func writeDescription(_ description: ScreenSharingDescription, to url: URL) throws {
      // Publish a complete private file atomically, refusing to replace a prior
      // session. The receiver can never observe a partially written description.
      let data = try JSONEncoder().encode(description)
      let temporary = url.deletingLastPathComponent().appendingPathComponent(".screen-sharing-" + UUID().uuidString)
      let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { throw ScreenSharingError.unavailable("Cannot create private signaling file.") }
      defer { unlink(temporary.path) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try file.write(contentsOf: data)
      try file.close()
      guard link(temporary.path, url.path) == 0 else {
        throw ScreenSharingError.unavailable("Cannot publish signaling file; use fresh paths for each session.")
      }
    }

    /// Real diagnostic workflow, not a test synchronization primitive. Bounded
    /// polling allows a human to transfer the signaling file without a server.
    private func waitUntil(seconds: Double, condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(seconds)
      while !condition() {
        guard ContinuousClock.now < deadline else { throw ScreenSharingError.unavailable("Probe setup timed out.") }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private struct ProbeReport: Encodable {
    let mode: ProbeOptions.Mode
    let configuration: ScreenSharingVideoConfiguration
    let source: String
    let startedAtSeconds: Double
    let elapsedSeconds: Double
    let passed: Bool
    let renderingEnabled: Bool
    let sender: ScreenSharingMetrics.Snapshot
    let receiver: ScreenSharingMetrics.Snapshot
    let senderRTC: [String: String]
    let receiverRTC: [String: String]
    let rendererMailboxDrops: Int
    let presentedFramesPerSecond: Double
    let timeline: [ProbeTimeline.Sample]
    let transportTimeline: [ProbeTransportTimeline.Sample]
    /// Receiver-only diagnostic audit snapshot taken at report time (before close); absent when not requested.
    let receiverDeliveryAudit: ScreenSharingFrameDeliveryAudit.Snapshot?
    /// Receiver-only diagnostic RTC event-log lifecycle record (final at report time); absent when not requested.
    let receiverRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
    /// Sender-only diagnostic RTC event-log lifecycle record on the sending peer; absent when not requested.
    let senderRtcEventLog: ScreenSharingRtcEventLogDiagnostic.Record?
  }
#else
  @main
  struct ScreenSharingProbe {
    static func main() { print("The diagnostic executable requires macOS; the media library also supports iOS.") }
  }
#endif
