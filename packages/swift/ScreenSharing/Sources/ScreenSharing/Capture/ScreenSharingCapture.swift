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
    public nonisolated static let defaultQueueDepth = 3
    public var pixelFormat: OSType
    public var queueDepth = ScreenSharingCapture.defaultQueueDepth
    public private(set) var showsCursor = true
    public private(set) var dynamicRange = ScreenSharingDynamicRange.standard
    public private(set) var capturesAudio = false
    public let audio = ScreenSharingCaptureAudioTap()
    private var video: ScreenSharingVideoConfiguration?
    public private(set) var cadence = ScreenSharingCaptureCadence(displayRefreshHz: nil)
    private var displayRefresh: @MainActor () -> Double? = { nil }
    private var reconfigurations = ScreenSharingCaptureTurns()
    var queuedReconfigurations: Int { reconfigurations.queued }
    private var restart:
      (target: any ScreenSharingCaptureTarget, sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics)?

    public init(pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
      self.pixelFormat = pixelFormat
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
      displayRefresh = { ScreenSharingDisplayRefresh.hz(of: displayID) }
      try await startResolved(
        target: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
        sink: sink, metrics: metrics, generation: generation)
    }

    package func start(
      filter: SCContentFilter, configuration: ScreenSharingVideoConfiguration, sink: any ScreenSharingFrameSink,
      metrics: ScreenSharingMetrics, displayID: CGDirectDisplayID? = nil
    ) async throws {
      try await start(
        target: filter, configuration: configuration, sink: sink, metrics: metrics,
        displayRefresh: { displayID.flatMap(ScreenSharingDisplayRefresh.hz(of:)) })
    }

    func start(
      target: any ScreenSharingCaptureTarget, configuration: ScreenSharingVideoConfiguration,
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics,
      displayRefresh: @escaping @MainActor () -> Double? = { nil }
    ) async throws {
      guard stream == nil, !starting else { throw ScreenSharingError.invalid("Capture is already running.") }
      self.displayRefresh = displayRefresh
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
      guard [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA].contains(pixelFormat) else {
        throw ScreenSharingError.invalid("Unsupported capture pixel format.")
      }
      cadence = ScreenSharingCaptureCadence(displayRefreshHz: displayRefresh())
      let streamConfiguration = Self.streamConfiguration(
        configuration, pixelFormat: pixelFormat, showsCursor: showsCursor,
        capturesAudio: capturesAudio, dynamicRange: dynamicRange, queueDepth: queueDepth, cadence: cadence)
      label(cadence, on: metrics)
      metrics.label("captureQueueDepth", String(queueDepth))
      metrics.label("capturePixelFormat", String(pixelFormat))
      metrics.label("captureDynamicRange", dynamicRange.rawValue)
      let content = target.captureContent
      metrics.label("captureContentStyle", content.style)
      metrics.label("captureContentWidthPoints", String(content.widthPoints))
      metrics.label("captureContentHeightPoints", String(content.heightPoints))
      metrics.label("captureContentPixelScale", String(content.pointPixelScale))
      let output = ScreenSharingCaptureOutput(sink: sink, metrics: metrics, audio: audio) { [weak self] message in
        Task { @MainActor in
          guard let self, self.generation == generation else { return }
          self.onStopped?(message)
        }
      }
      let stream = try target.makeCaptureStream(configuration: streamConfiguration, output: output)
      reconfigurations = ScreenSharingCaptureTurns()
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
      guard stream != nil, output != nil else { throw ScreenSharingError.unavailable("Capture is not running.") }
      try await inTurn { [self] in try await apply(configuration) }
    }

    private func inTurn(_ work: @escaping @MainActor () async throws -> Void) async throws {
      let queue = reconfigurations
      try await queue.run { [self] in
        await startSettled()
        guard queue === reconfigurations else { return try await inTurn(work) }

        try await work()
      }
    }

    private func apply(_ configuration: ScreenSharingVideoConfiguration) async throws {
      guard let stream, let output else { throw ScreenSharingError.unavailable("Capture is not running.") }
      let generation = generation
      output.changes.reconfigurationBegan()
      defer { output.changes.reconfigurationEnded() }
      try await stream.updateConfiguration(
        Self.streamConfiguration(
          configuration, pixelFormat: pixelFormat, showsCursor: showsCursor, capturesAudio: capturesAudio,
          dynamicRange: dynamicRange, queueDepth: queueDepth, cadence: cadence))
      guard self.generation == generation else { throw CancellationError() }
      video = configuration
    }

    public func followDisplayRefresh() async throws {
      try await inTurn { [self] in try await applyDisplayRefresh() }
    }

    private func applyDisplayRefresh() async throws {
      guard let refreshHz = displayRefresh(), let video, stream != nil else { return }

      let following = ScreenSharingCaptureCadence(displayRefreshHz: refreshHz)
      guard following.displayRefreshHz != cadence.displayRefreshHz else { return }

      let previous = cadence
      let generation = generation
      cadence = following
      if following != previous {
        do { try await apply(video) } catch {
          if self.generation == generation { cadence = previous }
          throw error
        }
      }
      if self.generation == generation, let metrics = output?.metrics { label(cadence, on: metrics) }
    }

    private func label(_ cadence: ScreenSharingCaptureCadence, on metrics: ScreenSharingMetrics) {
      metrics.label("captureDisplayRefreshHz", String(cadence.displayRefreshHz))
      metrics.label(
        "captureMinimumFrameIntervalNs",
        String(cadence.minimumFrameInterval.convertScale(1_000_000_000, method: .default).value))
    }

    public func setShowsCursor(_ shows: Bool) async throws {
      try await inTurn { [self] in
        guard shows != showsCursor else { return }

        let previous = showsCursor
        showsCursor = shows
        do { try await applyCurrent() } catch {
          showsCursor = previous
          throw error
        }
      }
    }

    public func setDynamicRange(_ range: ScreenSharingDynamicRange) async throws {
      guard range == .standard || pixelFormat == kCVPixelFormatType_32BGRA else {
        throw ScreenSharingError.invalid("High dynamic range needs a 4:4:4 capture.")
      }
      try await inTurn { [self] in
        guard range != dynamicRange else { return }

        let previous = dynamicRange
        dynamicRange = range
        do { try await applyCurrent() } catch {
          dynamicRange = previous
          throw error
        }
        output?.metrics.label("captureDynamicRange", range.rawValue)
      }
    }

    public func setCapturesAudio(_ captures: Bool) async throws {
      await settled()
      guard captures != capturesAudio else { return }
      changing += 1
      defer { changing -= 1 }
      guard captures, stream != nil, let restart, let video else {
        return try await inTurn { [self] in
          let previous = capturesAudio
          capturesAudio = captures
          do { try await applyCurrent() } catch {
            capturesAudio = previous
            throw error
          }
        }
      }

      let previous = capturesAudio
      capturesAudio = captures
      do {
        try await stop()
        try await start(
          target: restart.target, configuration: video, sink: restart.sink, metrics: restart.metrics,
          displayRefresh: displayRefresh)
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

    private func applyCurrent() async throws {
      guard let video, stream != nil else { return }

      try await apply(video)
    }

    static func streamConfiguration(
      _ video: ScreenSharingVideoConfiguration, pixelFormat: OSType, showsCursor: Bool, capturesAudio: Bool,
      dynamicRange: ScreenSharingDynamicRange = .standard, queueDepth: Int = defaultQueueDepth,
      cadence: ScreenSharingCaptureCadence = ScreenSharingCaptureCadence(displayRefreshHz: nil)
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
      config.minimumFrameInterval = cadence.minimumFrameInterval(requesting: video.framesPerSecond)
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
      guard CGPreflightScreenCaptureAccess() else { throw ScreenSharingError.captureNotPermitted }
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
    let changes = ScreenSharingCaptureChanges()

    init(
      sink: any ScreenSharingFrameSink, metrics: ScreenSharingMetrics,
      audio: ScreenSharingCaptureAudioTap? = nil, onStopped: @escaping @Sendable (String) -> Void
    ) {
      self.sink = sink
      self.metrics = metrics
      self.onStopped = onStopped
      self.audio = audio
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
      else { return skipped(status: status) }
      let time = CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 1_000_000_000, method: .default)
      guard time.isNumeric, time.value >= 0 else { return changes.interrupt() }
      let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
      metrics.observe(
        "captureDeliveryAge", milliseconds: CMTimeGetSeconds(hostTime - sampleBuffer.presentationTimeStamp) * 1000)
      ScreenSharingCaptureColorTags.tagStandardTransfer(pixel)
      let nativeScale = (attachments?.first?[.contentScale] as? Double).map { $0 == 1 } ?? false
      let reported = (attachments?.first?[.dirtyRects] as? [NSDictionary]).flatMap { rects in
        nativeScale ? rects.compactMap { CGRect(dictionaryRepresentation: $0) } : nil
      }
      let dirtyRects = changes.sinceLastDeliveredFrame(reported)
      sink.push(ScreenSharingVideoFrame(pixelBuffer: pixel, timestampNs: time.value, dirtyRects: dirtyRects))
    }

    private func skipped(status: Int?) {
      guard status != ScreenSharingCaptureCallbackAccounting.Status.idle.rawValue else { return }

      changes.interrupt()
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
