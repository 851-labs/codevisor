#if os(macOS)
  import CoreMedia
  import ScreenCaptureKit

  /// One display, SDR, no audio. Lifecycle stays on the main actor; sample
  /// delivery goes straight from SCK's serial queue into the native sender.
  @MainActor
  public final class ScreenSharingCapture {
    public var onStopped: ((String) -> Void)?
    private var generation = 0
    private var starting = false
    private var stream: (any ScreenSharingCaptureStream)?
    private var output: ScreenSharingCaptureOutput?
    private let queueDepth: Int
    private let pixelFormat: OSType
    private let copySurface: Bool
    /// Optional SCK minimum-frame-interval request in frames per second, isolated
    /// from the negotiated video/encoder rate. `nil` keeps the existing behaviour
    /// (interval = 1 / video fps). Validated by `ScreenSharingCaptureIntervalRequest`.
    /// The interval request in force. It changes only through `update(configuration:captureIntervalFPS:)`, and only
    /// AFTER a successful stream update in the same generation (see `ScreenSharingCaptureRequestState`).
    private(set) var requestState: ScreenSharingCaptureRequestState
    private var captureIntervalFPS: Int? { requestState.overrideFramesPerSecond }

    public init(
      queueDepth: Int = 3, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      copySurface: Bool = false, captureIntervalFPS: Int? = nil
    ) {
      self.queueDepth = queueDepth; self.pixelFormat = pixelFormat
      self.copySurface = copySurface
      self.requestState = ScreenSharingCaptureRequestState(overrideFramesPerSecond: captureIntervalFPS)
    }

    public static func displays() async throws -> [(id: UInt32, width: Int, height: Int)] {
      try requirePermission()
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      return content.displays.map { ($0.displayID, $0.width, $0.height) }
    }

    public func start(
      displayID: UInt32, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
    ) async throws {
      try Self.requirePermission()
      guard stream == nil, !starting else { throw ScreenSharingError.invalid("Capture is already running.") }
      generation += 1
      let generation = generation
      starting = true
      defer { if self.generation == generation { starting = false } }
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenSharingError.unavailable("Selected display is unavailable.")
      }
      try await startResolved(
        target: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
        sink: sink, metrics: metrics, generation: generation)
    }

    /// Diagnostic mode: capture one window this process owns, selected from
    /// current-process shareable content (available without TCC consent per the
    /// SDK) by exact window ID and owning process ID. There is no display or
    /// other-window fallback; any mismatch fails closed. SCK validates the
    /// filter when the stream starts.
    public func start(
      ownedWindowID: UInt32, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
    ) async throws {
      guard stream == nil, !starting else { throw ScreenSharingError.invalid("Capture is already running.") }
      generation += 1
      let generation = generation
      starting = true
      defer { if self.generation == generation { starting = false } }
      let content = try await SCShareableContent.currentProcess
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      let processID = ProcessInfo.processInfo.processIdentifier
      let candidates = content.windows.map {
        ScreenSharingOwnedWindowSelection.Candidate(
          windowID: $0.windowID, owningProcessID: $0.owningApplication?.processID)
      }
      metrics.label("captureOwnedWindowCandidates", String(candidates.count))
      let window: SCWindow
      switch ScreenSharingOwnedWindowSelection.select(windowID: ownedWindowID, processID: processID, from: candidates) {
      case .success(let selected):
        guard let match = content.windows.first(where: { $0.windowID == selected.windowID }) else {
          throw ScreenSharingError.unavailable("Owned window \(ownedWindowID) disappeared before capture.")
        }
        window = match
      case .failure(let failure):
        throw ScreenSharingError.unavailable("Owned window \(ownedWindowID) is not capturable: \(failure).")
      }
      metrics.label(
        "captureSelection", "owned window \(ownedWindowID) of pid \(processID) via SCShareableContent.currentProcess")
      metrics.label(
        "captureOwnedWindowFramePoints",
        "\(window.frame.width)x\(window.frame.height)@\(window.frame.minX),\(window.frame.minY)")
      metrics.label("captureOwnedWindowOnScreen", String(window.isOnScreen))
      try await startResolved(
        target: SCContentFilter(desktopIndependentWindow: window), configuration: configuration,
        sink: sink, metrics: metrics, generation: generation)
    }

    /// A filter returned by the system content picker carries its own scoped
    /// authorization. SCK validates it when starting; no persistent grant is needed.
    public func start(
      pickedFilter: SCContentFilter, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
    ) async throws {
      try await start(target: pickedFilter, configuration: configuration, sink: sink, metrics: metrics)
    }

    /// The start transaction over an ALREADY RESOLVED target: refuse a concurrent start, take a
    /// generation, and run the shared start path in it. The picker hands its filter straight to
    /// this; the display and owned-window entry points resolve a filter first and then call
    /// `startResolved` with the generation they took.
    func start(
      target: any ScreenSharingCaptureTarget, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
    ) async throws {
      guard stream == nil, !starting else { throw ScreenSharingError.invalid("Capture is already running.") }
      generation += 1
      let generation = generation
      starting = true
      defer { if self.generation == generation { starting = false } }
      try Task.checkCancellation()
      try await startResolved(
        target: target, configuration: configuration, sink: sink, metrics: metrics, generation: generation)
    }

    private func startResolved(
      target: any ScreenSharingCaptureTarget, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics, generation: Int
    ) async throws {
      guard (3...8).contains(queueDepth) else { throw ScreenSharingError.invalid("Capture queue depth must be 3...8.") }
      guard [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA].contains(pixelFormat) else {
        throw ScreenSharingError.invalid("Unsupported capture pixel format.")
      }
      // The interval request is validated on EVERY start and update (no silent fallback); telemetry
      // describes only requests that were actually applied.
      let interval = try requestState.validated(video: configuration, override: captureIntervalFPS)
      let streamConfiguration = Self.streamConfiguration(
        configuration, interval: interval, queueDepth: queueDepth, pixelFormat: pixelFormat)
      requestState.commit(override: captureIntervalFPS, request: interval, metrics: metrics)
      metrics.label("captureQueueDepth", String(queueDepth))
      metrics.label("capturePixelFormat", String(pixelFormat))
      metrics.label("captureSurface", copySurface ? "separate pool experiment" : "SCK surface")
      let content = target.captureContent
      metrics.label("captureContentStyle", content.style)
      metrics.label("captureContentWidthPoints", String(content.widthPoints))
      metrics.label("captureContentHeightPoints", String(content.heightPoints))
      metrics.label("captureContentPixelScale", String(content.pointPixelScale))
      let output = ScreenSharingCaptureOutput(sink: sink, metrics: metrics, copySurface: copySurface) {
        [weak self] message in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.onStopped?(message)
        }
      }
      let stream = try target.makeCaptureStream(configuration: streamConfiguration, output: output)
      self.output = output
      self.stream = stream
      do {
        try await stream.startCapture()
        metrics.label("captureStartedAtNs", String(ScreenSharingMetrics.nowNs))
        guard self.generation == generation, !Task.isCancelled else {
          try? await stream.stopCapture()
          throw CancellationError()
        }
      } catch {
        if self.generation == generation { self.stream = nil; self.output = nil }
        throw error
      }
    }

    /// Unchanged behaviour for the probe and every existing caller: keeps whatever interval request is currently in
    /// force — the value this capture was constructed with until an explicit level-aware update changes it, and that
    /// changed value afterwards.
    public func update(configuration: ScreenSharingVideoConfiguration) async throws {
      try await update(configuration: configuration, captureIntervalFPS: captureIntervalFPS)
    }

    /// The smallest explicit override needed for a level-aware request: the SAME single validated configuration path,
    /// with the interval request supplied by the caller for this update (nil = the video rate).
    ///
    /// Ordering matters and is deliberate: validate, then call ScreenCaptureKit, and only then — still in the same
    /// generation — commit the stored request state and its labels. A validation failure, a failed stream update or a
    /// generation change leaves the previous request and telemetry exactly as they were.
    public func update(configuration: ScreenSharingVideoConfiguration, captureIntervalFPS: Int?) async throws {
      guard let stream, let output else { throw ScreenSharingError.unavailable("Capture is not running.") }
      let generation = generation
      // An override that was valid for the previous video rate may be invalid for the new one
      // (e.g. video 30 + override 30, then video 60): the update throws instead of silently
      // requesting the video rate while the telemetry still says 30.
      try await applyIntervalUpdate(
        configuration: configuration, override: captureIntervalFPS, metrics: output.metrics,
        apply: { interval in
          try await stream.updateConfiguration(
            Self.streamConfiguration(
              configuration, interval: interval, queueDepth: self.queueDepth, pixelFormat: self.pixelFormat))
        }, isCurrent: { self.generation == generation })
    }

    /// The whole update transaction in one place: validate, apply, re-check the generation, and only then commit the
    /// request state and its labels. `apply` and `isCurrent` are the seams the real `update` fills with
    /// ScreenCaptureKit and the generation counter, and which tests fill with a controlled apply — the ORDER and the
    /// guards live here, in the code production runs, not in a test-only copy of the algorithm.
    func applyIntervalUpdate(
      configuration: ScreenSharingVideoConfiguration, override: Int?, metrics: ScreenSharingMetrics,
      apply: (ScreenSharingCaptureIntervalRequest) async throws -> Void, isCurrent: () -> Bool
    ) async throws {
      let interval = try requestState.validated(video: configuration, override: override)
      try await apply(interval)
      guard isCurrent() else { throw CancellationError() }
      requestState.commit(override: override, request: interval, metrics: metrics)
    }

    /// Builds the stream configuration from an ALREADY VALIDATED interval request. Validation lives in
    /// `ScreenSharingCaptureRequestState`, which both the start and update paths use, so no path can build a
    /// configuration from an unvalidated request.
    private static func streamConfiguration(
      _ video: ScreenSharingVideoConfiguration, interval: ScreenSharingCaptureIntervalRequest, queueDepth: Int,
      pixelFormat: OSType
    ) -> SCStreamConfiguration {
      let config = SCStreamConfiguration()
      config.width = video.width; config.height = video.height
      config.minimumFrameInterval = interval.minimumFrameInterval
      config.queueDepth = queueDepth
      config.pixelFormat = pixelFormat
      config.colorSpaceName = CGColorSpace.itur_709
      config.showsCursor = true
      config.capturesAudio = false
      config.scalesToFit = true
      return config
    }

    private static func requirePermission() throws {
      guard CGPreflightScreenCaptureAccess() else {
        throw ScreenSharingError.unavailable(
          "Screen Recording permission is required. Enable it for this app in System Settings, then relaunch."
        )
      }
    }

    /// Stops the stream and records the request/completion boundary so a
    /// report can order it against the window's close.
    public func stop() async throws {
      generation += 1
      starting = false
      let generation = generation
      guard let stream else {
        // Nothing to stop (never started, already stopped, or cleared by a
        // failed stop). Recorded as skipped; this is not completion evidence.
        output?.metrics.increment("captureStopSkippedNoStream")
        return
      }
      self.stream = nil
      let metrics = output?.metrics
      defer { if self.generation == generation { output = nil } }
      metrics?.label("captureStopRequestedAtNs", String(ScreenSharingMetrics.nowNs))
      do {
        try await stream.stopCapture()
      } catch {
        // A failed stop is evidence too; it never produces a completion label.
        metrics?.label("captureStopFailed", error.localizedDescription)
        metrics?.increment("captureStopFailures")
        throw error
      }
      metrics?.label("captureStopCompletedAtNs", String(ScreenSharingMetrics.nowNs))
      metrics?.increment("captureStops")
    }
  }

  /// Internal so a capture target can attach it to whatever stream it creates. Both delegate
  /// callbacks forward to a method that takes no `SCStream`, which is what makes the sample and
  /// error paths reachable from a test that has no stream to hand back.
  final class ScreenSharingCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "codevisor.screen-sharing.capture", qos: .userInteractive)
    let sink: any ScreenSharingFrameSink
    let metrics: ScreenSharingMetrics
    let onStopped: @Sendable (String) -> Void
    private let surfaceCopy: ScreenSharingCaptureBufferCopy?

    init(
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics, copySurface: Bool,
      onStopped: @escaping @Sendable (String) -> Void
    ) {
      self.sink = sink
      self.metrics = metrics
      self.onStopped = onStopped
      surfaceCopy = copySurface ? ScreenSharingCaptureBufferCopy() : nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      deliver(sampleBuffer, of: type)
    }

    func deliver(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      guard type == .screen else { return }
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]]
      let status = attachments?.first?[.status] as? Int
      let pixel = sampleBuffer.imageBuffer
      // Every callback is counted by status; only a complete frame with an
      // image is delivered. Absent callbacks are not a measured drop count.
      guard
        ScreenSharingCaptureCallbackAccounting.record(
          valid: sampleBuffer.isValid, rawStatus: status, hasImage: pixel != nil, metrics: metrics),
        let pixel
      else { return }
      // SCK's presentation timestamp uses the host clock. Forward it without
      // copying pixels; WebRTC maps the local clock onto RTP timestamps.
      let time = CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 1_000_000_000, method: .default)
      guard time.isNumeric, time.value >= 0 else { return }
      let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
      metrics.observe(
        "captureDeliveryAge", milliseconds: CMTimeGetSeconds(hostTime - sampleBuffer.presentationTimeStamp) * 1000)
      do {
        let frame: CVPixelBuffer
        if let surfaceCopy {
          let started = ScreenSharingMetrics.nowNs
          guard let copied = try surfaceCopy.copy(pixel) else {
            metrics.increment("captureCopyPoolDrops"); return
          }
          metrics.observe("captureSurfaceCopy", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
          frame = copied
        } else {
          frame = pixel
        }
        sink.push(ScreenSharingVideoFrame(pixelBuffer: frame, timestampNs: time.value))
      } catch {
        metrics.increment("captureCopyErrors")
        metrics.label("captureError", error.localizedDescription)
        onStopped(error.localizedDescription)
      }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
      handleStop(error: error)
    }

    func handleStop(error: any Error) {
      metrics.label("captureError", error.localizedDescription)
      onStopped(error.localizedDescription)
    }
  }
#endif
