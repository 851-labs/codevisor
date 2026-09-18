import ScreenSharingDiagnostics
#if os(macOS)
  import AppKit
  import ScreenSharing
  import ScreenSharingWebRTC
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  @preconcurrency import WebRTC

  /// `screen-sharing-rig probe …`: the single-process diagnostic — both peers in this
  /// process over a loopback exchange, with the measurement and recovery experiments
  /// described in packages/swift/ScreenSharing/README.md. Owns the process
  /// once dispatched: it installs the field trials and runs its own application loop.
  @MainActor
  enum ProbeCommand {
    /// `arguments` are the words after `probe`.
    static func main(arguments: [String]) {
      if arguments.contains("--help") { print(ProbeOptions.usage); return }
      do {
        if arguments.first == "--clock-sync" {
          try ProbeClockSync.run(arguments: arguments)
          return
        }
        if arguments.first == "--observe-window" {
          let options = try ProbeWindowObservation.Options(arguments: Array(arguments.dropFirst()))
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
        let options = try ProbeOptions(arguments: arguments)
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
  final class ProbeRunner: NSObject, NSWindowDelegate {
    let options: ProbeOptions
    let senderMetrics = ScreenSharingMetrics()
    let receiverMetrics = ScreenSharingMetrics()
    var sender: ScreenSharingSender?
    var receiver: ScreenSharingReceiver?
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
        var senderOptions = ScreenSharingPeerOptions()
        senderOptions.useLowLatencyRateControl = !options.standardRateControl
        senderOptions.codec = options.videoCodec
        senderOptions.disableLookAhead = options.disableLookAhead
        senderOptions.maximumPendingFrames = options.encoderInFlight
        senderOptions.maintainSourceRate = options.maintainSourceRate
        senderOptions.staticCodecRate = options.staticCodecRate
        senderOptions.completeEachFrame = options.completeEachFrame
        senderOptions.prioritizeSpeed = options.prioritizeSpeed
        senderOptions.keyframeIntervalSeconds = options.keyframeIntervalSeconds
        senderOptions.sourceIdleThresholdNs = options.idleThresholdMs.map { Int64($0) * 1_000_000 }
        sender = try ScreenSharingSender(
          configuration: options.configuration, metrics: senderMetrics, options: senderOptions)
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
        var receiverOptions = ScreenSharingPeerOptions()
        receiverOptions.codec = options.videoCodec
        receiverOptions.deliveryGrace = options.idleGraceMs.map { .milliseconds($0) }
        receiverOptions.deliveryGraceExtensions = options.idleGraceExtensions
        let receiver = try ScreenSharingReceiver(
          configuration: options.configuration, metrics: receiverMetrics, options: receiverOptions,
          frameDeliveryAudit: deliveryAudit)
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
              sink: sender.frameSender, metrics: senderMetrics)
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
            sink: sender.frameSender, metrics: senderMetrics)
        } else if let display = options.displayID {
          let capture = ScreenSharingCapture(
            queueDepth: options.captureQueueDepth, pixelFormat: options.capturePixelFormat,
            copySurface: options.copyCaptureSurface, captureIntervalFPS: options.captureIntervalFPS)
          self.capture = capture
          try await capture.start(
            displayID: display, configuration: options.configuration,
            sink: sender.frameSender, metrics: senderMetrics)
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
        try await ProbeControlCheck(host: sender.controlChannel, viewer: receiver.controlChannel).run()
        senderMetrics.label("controlChannel", "ordered input and release verified")
        print("Control channel: eight input events and release acknowledged; no OS input posted.")
        try await ProbeClipboardCheck(host: sender.clipboardChannel, viewer: receiver.clipboardChannel).run()
        senderMetrics.label("clipboardChannel", "bidirectional chunked Unicode transfer verified")
        print("Clipboard channel: bidirectional Unicode transfer verified; no system clipboard accessed.")
      }
      if options.checkQuality { try await checkQuality() }
      try await measure()
    }
  }
#endif
