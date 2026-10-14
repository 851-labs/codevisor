#if os(macOS)
  import CoreMedia
  import ScreenCaptureKit

  @MainActor
  public final class ScreenSharingCapture {
    public var onStopped: ((String) -> Void)?
    private var generation = 0
    private var starting = false {
      didSet { if !starting { wakeWaiters() } }
    }
    private var changing = 0 {
      didSet { if changing < oldValue { wakeWaiters() } }
    }
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    var onWaitingForStart: (() -> Void)?
    private var stream: (any ScreenSharingCaptureStream)?
    private var output: ScreenSharingCaptureOutput?
    private let queueDepth: Int
    public var pixelFormat: OSType
    private let copySurface: Bool
    private(set) var requestState: ScreenSharingCaptureRequestState
    private var captureIntervalFPS: Int? { requestState.overrideFramesPerSecond }
    public private(set) var showsCursor = true
    public private(set) var dynamicRange = ScreenSharingDynamicRange.standard
    public private(set) var capturesAudio = false
    public let audio = ScreenSharingCaptureAudioTap()
    private var video: ScreenSharingVideoConfiguration?
    private var restart:
      (target: any ScreenSharingCaptureTarget, sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics)?

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

    public func start(
      pickedFilter: SCContentFilter, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics
    ) async throws {
      try await start(target: pickedFilter, configuration: configuration, sink: sink, metrics: metrics)
    }

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
      let interval = try requestState.validated(video: configuration, override: captureIntervalFPS)
      let streamConfiguration = Self.streamConfiguration(
        configuration, interval: interval, queueDepth: queueDepth, pixelFormat: pixelFormat, showsCursor: showsCursor,
        capturesAudio: capturesAudio, dynamicRange: dynamicRange)
      requestState.commit(override: captureIntervalFPS, request: interval, metrics: metrics)
      metrics.label("captureQueueDepth", String(queueDepth))
      metrics.label("capturePixelFormat", String(pixelFormat))
      metrics.label("captureDynamicRange", dynamicRange.rawValue)
      metrics.label("captureSurface", copySurface ? "separate pool experiment" : "SCK surface")
      let content = target.captureContent
      metrics.label("captureContentStyle", content.style)
      metrics.label("captureContentWidthPoints", String(content.widthPoints))
      metrics.label("captureContentHeightPoints", String(content.heightPoints))
      metrics.label("captureContentPixelScale", String(content.pointPixelScale))
      let output = ScreenSharingCaptureOutput(
        sink: sink, metrics: metrics, copySurface: copySurface, audio: audio
      ) {
        [weak self] message in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.onStopped?(message)
        }
      }
      let stream = try target.makeCaptureStream(configuration: streamConfiguration, output: output)
      self.output = output
      self.stream = stream
      video = configuration
      restart = (target, sink, metrics)
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

    public func update(configuration: ScreenSharingVideoConfiguration) async throws {
      try await update(configuration: configuration, captureIntervalFPS: captureIntervalFPS)
    }

    public func update(configuration: ScreenSharingVideoConfiguration, captureIntervalFPS: Int?) async throws {
      guard let stream, let output else { throw ScreenSharingError.unavailable("Capture is not running.") }
      let generation = generation
      try await applyIntervalUpdate(
        configuration: configuration, override: captureIntervalFPS, metrics: output.metrics,
        apply: { interval in
          try await stream.updateConfiguration(
            Self.streamConfiguration(
              configuration, interval: interval, queueDepth: self.queueDepth, pixelFormat: self.pixelFormat,
              showsCursor: self.showsCursor, capturesAudio: self.capturesAudio, dynamicRange: self.dynamicRange))
        }, isCurrent: { self.generation == generation })
      video = configuration
    }

    public func setShowsCursor(_ shows: Bool) async throws {
      guard shows != showsCursor else { return }
      let previous = showsCursor
      showsCursor = shows
      do { try await reconfigure() } catch {
        showsCursor = previous
        throw error
      }
    }

    public func setDynamicRange(_ range: ScreenSharingDynamicRange) async throws {
      guard range != dynamicRange else { return }
      guard range == .standard || pixelFormat == kCVPixelFormatType_32BGRA else {
        throw ScreenSharingError.invalid("High dynamic range needs a 4:4:4 capture.")
      }
      let previous = dynamicRange
      dynamicRange = range
      do { try await reconfigure() } catch {
        dynamicRange = previous
        throw error
      }
      output?.metrics.label("captureDynamicRange", range.rawValue)
    }

    public func setCapturesAudio(_ captures: Bool) async throws {
      await settled()
      guard captures != capturesAudio else { return }
      changing += 1
      defer { changing -= 1 }
      let previous = capturesAudio
      capturesAudio = captures
      do {
        if captures, stream != nil, let restart, let video {
          try await stop()
          try await start(target: restart.target, configuration: video, sink: restart.sink, metrics: restart.metrics)
        } else {
          try await reconfigure()
        }
      } catch {
        capturesAudio = previous
        throw error
      }
    }

    private func startSettled() async {
      while starting { await waitForChange() }
    }

    public func settled() async {
      while starting || changing > 0 { await waitForChange() }
    }

    private func waitForChange() async {
      await withCheckedContinuation { continuation in
        startWaiters.append(continuation)
        onWaitingForStart?()
      }
    }

    private func wakeWaiters() {
      let waiters = startWaiters
      startWaiters = []
      for waiter in waiters { waiter.resume() }
    }

    private func reconfigure() async throws {
      await startSettled()
      guard let video, stream != nil else { return }
      try await update(configuration: video, captureIntervalFPS: captureIntervalFPS)
    }

    func applyIntervalUpdate(
      configuration: ScreenSharingVideoConfiguration, override: Int?, metrics: ScreenSharingMetrics,
      apply: (ScreenSharingCaptureIntervalRequest) async throws -> Void, isCurrent: () -> Bool
    ) async throws {
      let interval = try requestState.validated(video: configuration, override: override)
      try await apply(interval)
      guard isCurrent() else { throw CancellationError() }
      requestState.commit(override: override, request: interval, metrics: metrics)
    }

    static func streamConfiguration(
      _ video: ScreenSharingVideoConfiguration, interval: ScreenSharingCaptureIntervalRequest, queueDepth: Int,
      pixelFormat: OSType, showsCursor: Bool, capturesAudio: Bool, dynamicRange: ScreenSharingDynamicRange = .standard
    ) -> SCStreamConfiguration {
      let config: SCStreamConfiguration
      if dynamicRange == .high {
        config = SCStreamConfiguration(preset: .captureHDRStreamCanonicalDisplay)
        config.pixelFormat = ScreenSharingDynamicRange.highCapturePixelFormat
      } else {
        config = SCStreamConfiguration()
        config.pixelFormat = pixelFormat
        config.colorSpaceName = CGColorSpace.sRGB
      }
      config.width = video.width; config.height = video.height
      config.minimumFrameInterval = interval.minimumFrameInterval
      config.queueDepth = queueDepth
      config.showsCursor = showsCursor
      config.capturesAudio = capturesAudio
      if capturesAudio {
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
      }
      config.scalesToFit = true
      config.preservesAspectRatio = false
      return config
    }

    private static func requirePermission() throws {
      guard CGPreflightScreenCaptureAccess() else {
        throw ScreenSharingError.unavailable(
          "Screen Recording permission is required. Enable it for this app in System Settings, then relaunch."
        )
      }
    }

    public func stop() async throws {
      generation += 1
      starting = false
      let generation = generation
      guard let stream else {
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
        metrics?.label("captureStopFailed", error.localizedDescription)
        metrics?.increment("captureStopFailures")
        throw error
      }
      metrics?.label("captureStopCompletedAtNs", String(ScreenSharingMetrics.nowNs))
      metrics?.increment("captureStops")
    }
  }

  final class ScreenSharingCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "codevisor.screen-sharing.capture", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "codevisor.screen-sharing.capture-audio", qos: .userInteractive)
    let sink: any ScreenSharingFrameSink
    let metrics: ScreenSharingMetrics
    let onStopped: @Sendable (String) -> Void
    let audio: ScreenSharingCaptureAudioTap?
    private let surfaceCopy: ScreenSharingCaptureBufferCopy?

    init(
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics, copySurface: Bool,
      audio: ScreenSharingCaptureAudioTap? = nil, onStopped: @escaping @Sendable (String) -> Void
    ) {
      self.sink = sink
      self.metrics = metrics
      self.onStopped = onStopped
      self.audio = audio
      surfaceCopy = copySurface ? ScreenSharingCaptureBufferCopy() : nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      deliver(sampleBuffer, of: type)
    }

    func deliver(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
      if type == .audio {
        metrics.increment("captureAudioBuffers")
        audio?.deliver(sampleBuffer)
        return
      }
      guard type == .screen else { return }
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]]
      let status = attachments?.first?[.status] as? Int
      let pixel = sampleBuffer.imageBuffer
      guard
        ScreenSharingCaptureCallbackAccounting.record(
          valid: sampleBuffer.isValid, rawStatus: status, hasImage: pixel != nil, metrics: metrics),
        let pixel
      else { return }
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

  public final class ScreenSharingCaptureAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?

    public init() {}

    public func set(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) { lock.withLock { self.handler = handler } }

    func deliver(_ sampleBuffer: CMSampleBuffer) { lock.withLock { handler }?(sampleBuffer) }
  }
#endif
