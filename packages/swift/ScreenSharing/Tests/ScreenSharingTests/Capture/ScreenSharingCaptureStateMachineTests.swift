#if os(macOS)
  import CodevisorTestSupport
  import CoreMedia
  import CoreVideo
  import Foundation
  import ScreenCaptureKit
  import Testing

  @testable import ScreenSharing

  /// The capture's whole lifecycle over a stream the test owns: start, reconfigure, stop, restart
  /// after an error, and a source that goes away. Only the two ScreenCaptureKit objects are
  /// replaced — the target that resolves the content and the stream itself. The generation counter,
  /// the validated interval request, the label writes and the ordering of every step are production
  /// code. None of it needs Screen Recording consent, which is why this state machine could not be
  /// covered before.
  @Suite @MainActor struct ScreenSharingCaptureStateMachineTests {
    // MARK: Starting

    @Test func startPublishesTheResolvedContentAndTheValidatedRequestBeforeTheStreamStarts() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      #expect(fixture.stream.calls == [.start])
      let settings = try #require(fixture.target.settings)
      #expect(settings.width == 1920 && settings.height == 1080)
      #expect(settings.interval == CMTime(value: 1, timescale: 60))
      #expect(settings.queueDepth == 3)
      #expect(settings.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      #expect(settings.showsCursor && !settings.capturesAudio && settings.scalesToFit)
      #expect(settings.colorSpaceName == CGColorSpace.itur_709)
      let labels = fixture.metrics.snapshot().labels
      #expect(labels["captureContentStyle"] == "test-display")
      #expect(labels["captureContentWidthPoints"] == "1440.0")
      #expect(labels["captureContentHeightPoints"] == "900.0")
      #expect(labels["captureContentPixelScale"] == "2.0")
      #expect(labels["captureQueueDepth"] == "3")
      #expect(labels["captureSurface"] == "SCK surface")
      #expect(labels["captureRequestedMinimumFrameIntervalFPS"] == "60")
      #expect(labels["captureRequestedFrameIntervalOverride"] == "none")
      #expect(labels["captureStartedAtNs"] != nil)
    }

    @Test func aConstructionOverrideIsRequestedOfTheStreamAndDescribedAsAnOverride() async throws {
      let fixture = CaptureFixture(captureIntervalFPS: 120)
      try await fixture.start()
      #expect(fixture.target.settings?.interval == CMTime(value: 1, timescale: 120))
      let labels = fixture.metrics.snapshot().labels
      #expect(labels["captureRequestedMinimumFrameIntervalFPS"] == "120")
      #expect(labels["captureRequestedFrameIntervalOverride"] == "120")
    }

    @Test func aSecondStartIsRefusedWhileTheFirstIsStillStarting() async throws {
      let fixture = CaptureFixture()
      let held = CaptureGate()
      fixture.stream.holdStart = held
      let first = Task { @MainActor in try await fixture.start() }
      await held.entered.wait()
      let other = CaptureTargetDouble(style: "second")
      await #expect(throws: ScreenSharingError.self) {
        try await fixture.capture.start(
          target: other, configuration: .init(), sink: fixture.sink, metrics: fixture.metrics)
      }
      #expect(other.settings == nil)
      held.release()
      try await first.value
      #expect(fixture.stream.calls == [.start])
    }

    @Test func aStartedCaptureRefusesAnotherStartUntilItHasStopped() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      await #expect(throws: ScreenSharingError.self) { try await fixture.start() }
      try await fixture.capture.stop()
      try await fixture.start()
      #expect(fixture.stream.calls == [.start, .stop, .start])
    }

    @Test func aFailedStartClearsTheCaptureSoTheSourceCanBeStartedAgain() async throws {
      let fixture = CaptureFixture()
      fixture.stream.startFailure = CaptureFailure.start
      await #expect(throws: CaptureFailure.start) { try await fixture.start() }
      #expect(fixture.metrics.snapshot().labels["captureStartedAtNs"] == nil)
      fixture.stream.startFailure = nil
      try await fixture.start()
      #expect(fixture.stream.calls == [.start, .start])
    }

    @Test func aTargetThatCannotProduceAStreamLeavesNothingRunning() async throws {
      let fixture = CaptureFixture()
      fixture.target.makeFailure = CaptureFailure.makeStream
      await #expect(throws: CaptureFailure.makeStream) { try await fixture.start() }
      try await fixture.capture.stop()
      #expect(fixture.stream.calls.isEmpty)
      // The capture never took ownership of the metrics sink (that happens with the stream), so the
      // stop has nowhere to record itself and stays silent rather than inventing a skip.
      #expect(fixture.metrics.snapshot().counters.isEmpty)
    }

    @Test func anUnsupportedQueueDepthOrPixelFormatFailsBeforeAnyStreamExists() async throws {
      for capture in [
        ScreenSharingCapture(queueDepth: 9), ScreenSharingCapture(pixelFormat: kCVPixelFormatType_32ARGB),
      ] {
        let fixture = CaptureFixture(capture: capture)
        await #expect(throws: ScreenSharingError.self) { try await fixture.start() }
        #expect(fixture.target.settings == nil)
        #expect(fixture.metrics.snapshot().labels.isEmpty)
      }
    }

    @Test func anInvalidIntervalRequestIsRefusedBeforeTheStreamIsBuilt() async throws {
      // The override is below the video rate. It must fail on the start path rather than quietly
      // become the video rate while the telemetry still claims the override.
      let fixture = CaptureFixture(captureIntervalFPS: 30)
      await #expect(throws: ScreenSharingError.self) {
        try await fixture.start(configuration: .init(framesPerSecond: 60))
      }
      #expect(fixture.target.settings == nil)
      #expect(fixture.metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == nil)
    }

    // MARK: Reconfiguring

    @Test func anIntervalUpdateReconfiguresTheLiveStreamAndThenCommitsItsRequest() async throws {
      let fixture = CaptureFixture(captureIntervalFPS: 120)
      try await fixture.start()
      try await fixture.capture.update(configuration: .init(width: 1280, height: 720, framesPerSecond: 30))
      #expect(fixture.stream.calls == [.start, .update])
      let updated = try #require(fixture.stream.updated)
      #expect(updated.width == 1280 && updated.height == 720)
      // The no-argument update keeps whatever request is in force, so the override survives.
      #expect(updated.interval == CMTime(value: 1, timescale: 120))
      #expect(fixture.capture.requestState.overrideFramesPerSecond == 120)
      try await fixture.capture.update(configuration: .init(framesPerSecond: 30), captureIntervalFPS: nil)
      #expect(fixture.stream.updated?.interval == CMTime(value: 1, timescale: 30))
      #expect(fixture.capture.requestState.overrideFramesPerSecond == nil)
      #expect(fixture.metrics.snapshot().labels["captureRequestedFrameIntervalOverride"] == "none")
    }

    @Test func aRefusedUpdateLeavesTheRequestAndTheStreamExactlyAsTheyWere() async throws {
      let fixture = CaptureFixture(captureIntervalFPS: 120)
      try await fixture.start()
      let before = fixture.metrics.snapshot().labels
      // 30 fps video with a 20 fps request: invalid, and the stream is never called.
      await #expect(throws: ScreenSharingError.self) {
        try await fixture.capture.update(configuration: .init(framesPerSecond: 30), captureIntervalFPS: 20)
      }
      #expect(fixture.stream.calls == [.start])
      fixture.stream.updateFailure = CaptureFailure.update
      await #expect(throws: CaptureFailure.update) {
        try await fixture.capture.update(configuration: .init(framesPerSecond: 30))
      }
      #expect(fixture.stream.calls == [.start, .update])
      #expect(fixture.capture.requestState.overrideFramesPerSecond == 120)
      #expect(fixture.metrics.snapshot().labels == before)
    }

    @Test func anUpdateBeforeAStartOrAfterAStopIsRefusedWithoutTouchingAnyStream() async throws {
      let fixture = CaptureFixture()
      await #expect(throws: ScreenSharingError.self) { try await fixture.capture.update(configuration: .init()) }
      try await fixture.start()
      try await fixture.capture.stop()
      await #expect(throws: ScreenSharingError.self) { try await fixture.capture.update(configuration: .init()) }
      #expect(fixture.stream.calls == [.start, .stop])
    }

    // MARK: Stopping

    @Test func aCompletedStopRecordsBothBoundariesAndReleasesTheCaptureOnce() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      try await fixture.capture.stop()
      let labels = fixture.metrics.snapshot().labels
      let requested = try #require(labels["captureStopRequestedAtNs"].flatMap(Int64.init))
      let completed = try #require(labels["captureStopCompletedAtNs"].flatMap(Int64.init))
      #expect(requested <= completed)
      #expect(labels["captureStopFailed"] == nil)
      try await fixture.capture.stop()
      let counters = fixture.metrics.snapshot().counters
      #expect(counters["captureStops"] == 1)
      #expect(fixture.stream.calls == [.start, .stop])
    }

    @Test func aStopThatOverlapsAnotherStopIsRecordedAsASkipAndNeverAsASecondCompletion() async throws {
      let fixture = CaptureFixture()
      try await fixture.capture.stop()
      #expect(fixture.metrics.snapshot().counters.isEmpty)
      try await fixture.start()
      let held = CaptureGate()
      fixture.stream.holdStop = held
      let first = Task { @MainActor in try await fixture.capture.stop() }
      await held.entered.wait()
      try await fixture.capture.stop()
      let overlapping = fixture.metrics.snapshot().counters
      #expect(overlapping["captureStopSkippedNoStream"] == 1)
      #expect(overlapping["captureStops"] == nil)
      held.release()
      try await first.value
      #expect(fixture.metrics.snapshot().counters["captureStops"] == 1)
      #expect(fixture.stream.calls == [.start, .stop])
    }

    @Test func aFailedStopIsRecordedAsAFailureAndStillReleasesTheCapture() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      fixture.stream.stopFailure = CaptureFailure.stop
      await #expect(throws: CaptureFailure.stop) { try await fixture.capture.stop() }
      let snapshot = fixture.metrics.snapshot()
      #expect(snapshot.labels["captureStopCompletedAtNs"] == nil)
      #expect(snapshot.labels["captureStopFailed"] != nil)
      #expect(snapshot.counters["captureStopFailures"] == 1)
      #expect(snapshot.counters["captureStops"] == nil)
      // A failed stop still releases the stream, so the source can be started again, not wedged.
      fixture.stream.stopFailure = nil
      try await fixture.start()
      #expect(fixture.stream.calls == [.start, .stop, .start])
    }

    @Test func stoppingDuringAHeldStartStopsTheStreamThatArrivesLate() async throws {
      let fixture = CaptureFixture()
      let held = CaptureGate()
      fixture.stream.holdStart = held
      let start = Task { @MainActor in try await fixture.start() }
      await held.entered.wait()
      try await fixture.capture.stop()
      // The stop found the stream the held start had already installed and stopped it.
      #expect(fixture.stream.calls == [.stop])
      held.release()
      await #expect(throws: CancellationError.self) { try await start.value }
      // The start then saw the newer generation and stopped the stream it had just started.
      #expect(fixture.stream.calls == [.stop, .start, .stop])
    }

    // MARK: A source that goes away

    @Test func aStreamErrorIsReportedOnceAndOnlyForTheGenerationThatIsStillLive() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      let stopped = TestSignal()
      var messages: [String] = []
      fixture.capture.onStopped = { message in
        messages.append(message)
        stopped.signal()
      }
      let first = try #require(fixture.target.output)
      first.handleStop(error: ScreenSharingError.unavailable("Source disappeared."))
      await stopped.wait()
      #expect(messages == ["Source disappeared."])
      #expect(fixture.metrics.snapshot().labels["captureError"] == "Source disappeared.")

      // A restart takes a new generation. `captureError` is written synchronously by the stale
      // output's callback, which proves it ran and was dropped by the generation guard before the
      // live generation's notification is awaited.
      try await fixture.capture.stop()
      try await fixture.start()
      first.handleStop(error: ScreenSharingError.unavailable("Stale."))
      #expect(fixture.metrics.snapshot().labels["captureError"] == "Stale.")
      let second = try #require(fixture.target.output)
      second.handleStop(error: ScreenSharingError.unavailable("Live."))
      await stopped.wait(for: 2)
      #expect(messages == ["Source disappeared.", "Live."])
    }

    @Test func restartingAgainstADifferentSourcePublishesTheNewContent() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      try await fixture.capture.stop()
      let window = CaptureTargetDouble(style: "test-window", width: 640, height: 480, scale: 1)
      try await fixture.capture.start(
        target: window, configuration: .init(), sink: fixture.sink, metrics: fixture.metrics)
      let labels = fixture.metrics.snapshot().labels
      #expect(labels["captureContentStyle"] == "test-window")
      #expect(labels["captureContentWidthPoints"] == "640.0")
      #expect(labels["captureContentHeightPoints"] == "480.0")
      #expect(labels["captureContentPixelScale"] == "1.0")
    }

    // MARK: Sample delivery

    @Test func onlyScreenSamplesReachTheSinkAndTheyCarryTheCapturePresentationTime() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      let output = try #require(fixture.target.output)
      let sample = try Self.screenSample(presentationNs: 1_500_000_000)
      output.deliver(sample, of: .audio)
      #expect(fixture.sink.frames.isEmpty)
      output.deliver(sample, of: .screen)
      #expect(fixture.sink.frames == [1_500_000_000])
      #expect(fixture.metrics.snapshot().counters["captureCallbacksComplete"] == 1)
    }

    /// One ready 16x16 BGRA sample marked complete: what ScreenCaptureKit hands the output for a
    /// frame it actually captured.
    private static func screenSample(presentationNs: Int64) throws -> CMSampleBuffer {
      var pixel: CVPixelBuffer?
      #expect(
        CVPixelBufferCreate(
          nil, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
          == kCVReturnSuccess)
      let buffer = try #require(pixel)
      var format: CMFormatDescription?
      #expect(
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
          == noErr)
      var timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: CMTime(value: presentationNs, timescale: 1_000_000_000),
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      #expect(
        CMSampleBufferCreateReadyWithImageBuffer(
          allocator: nil, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing,
          sampleBufferOut: &sample) == noErr)
      let ready = try #require(sample)
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(ready, createIfNecessary: true) as? [NSMutableDictionary]
      try #require(attachments?.first)[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.complete.rawValue
      return ready
    }
  }

  private enum CaptureFailure: Error, Equatable { case start, stop, update, makeStream }

  /// One capture, one target and one stream created together, so no test ever observes a
  /// half-configured capture.
  @MainActor private final class CaptureFixture {
    let capture: ScreenSharingCapture
    let metrics = ScreenSharingMetrics()
    let sink = RecordingFrameSink()
    let target = CaptureTargetDouble(style: "test-display")
    var stream: CaptureStreamDouble { target.stream }

    init(capture: ScreenSharingCapture) { self.capture = capture }
    convenience init(captureIntervalFPS: Int? = nil) {
      self.init(capture: ScreenSharingCapture(captureIntervalFPS: captureIntervalFPS))
    }

    func start(configuration: ScreenSharingVideoConfiguration? = nil) async throws {
      try await capture.start(
        target: target, configuration: configuration ?? .init(), sink: sink, metrics: metrics)
    }
  }

  /// Everything the capture reads from an `SCContentFilter`, and the stream it would have built.
  private final class CaptureTargetDouble: ScreenSharingCaptureTarget {
    let stream = CaptureStreamDouble()
    let captureContent: ScreenSharingCaptureContent
    var makeFailure: (any Error)?
    private(set) var settings: CaptureStreamDouble.Settings?
    private(set) var output: ScreenSharingCaptureOutput?

    init(style: String, width: Double = 1440, height: Double = 900, scale: Float = 2) {
      captureContent = ScreenSharingCaptureContent(
        style: style, widthPoints: width, heightPoints: height, pointPixelScale: scale)
    }

    func makeCaptureStream(
      configuration: SCStreamConfiguration, output: ScreenSharingCaptureOutput
    ) throws -> any ScreenSharingCaptureStream {
      if let makeFailure { throw makeFailure }
      settings = CaptureStreamDouble.Settings(configuration)
      self.output = output
      return stream
    }
  }

  /// The stream the capture drives. The recorded calls are lock-guarded because the protocol keeps
  /// the caller's isolation rather than promising the main actor.
  private final class CaptureStreamDouble: ScreenSharingCaptureStream, @unchecked Sendable {
    enum Call: Equatable { case start, stop, update }

    /// The scalars the capture asks ScreenCaptureKit for, captured when the stream is built or
    /// reconfigured. `SCStreamConfiguration` is mutable, so its values are read immediately.
    struct Settings {
      let width: Int
      let height: Int
      let interval: CMTime
      let queueDepth: Int
      let pixelFormat: OSType
      let colorSpaceName: CFString?
      let showsCursor: Bool
      let capturesAudio: Bool
      let scalesToFit: Bool

      init(_ configuration: SCStreamConfiguration) {
        width = configuration.width
        height = configuration.height
        interval = configuration.minimumFrameInterval
        queueDepth = configuration.queueDepth
        pixelFormat = configuration.pixelFormat
        colorSpaceName = configuration.colorSpaceName
        showsCursor = configuration.showsCursor
        capturesAudio = configuration.capturesAudio
        scalesToFit = configuration.scalesToFit
      }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var lastUpdate: Settings?
    private var failures: [Call: any Error] = [:]
    private var gates: [Call: CaptureGate] = [:]

    var calls: [Call] { lock.withLock { recorded } }
    var updated: Settings? { lock.withLock { lastUpdate } }
    var startFailure: (any Error)? {
      get { lock.withLock { failures[.start] } }
      set { lock.withLock { failures[.start] = newValue } }
    }
    var stopFailure: (any Error)? {
      get { lock.withLock { failures[.stop] } }
      set { lock.withLock { failures[.stop] = newValue } }
    }
    var updateFailure: (any Error)? {
      get { lock.withLock { failures[.update] } }
      set { lock.withLock { failures[.update] = newValue } }
    }
    var holdStart: CaptureGate? {
      get { lock.withLock { gates[.start] } }
      set { lock.withLock { gates[.start] = newValue } }
    }
    var holdStop: CaptureGate? {
      get { lock.withLock { gates[.stop] } }
      set { lock.withLock { gates[.stop] = newValue } }
    }

    nonisolated(nonsending) func startCapture() async throws {
      await lock.withLock { gates[.start] }?.enter()
      try record(.start)
    }

    nonisolated(nonsending) func stopCapture() async throws {
      await lock.withLock { gates[.stop] }?.enter()
      try record(.stop)
    }

    nonisolated(nonsending) func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
      let settings = Settings(configuration)
      try lock.withLock {
        recorded.append(.update)
        lastUpdate = settings
        if let failure = failures[.update] { throw failure }
      }
    }

    private func record(_ call: Call) throws {
      try lock.withLock {
        recorded.append(call)
        if let failure = failures[call] { throw failure }
      }
    }
  }

  /// A stream call held open until the test releases it, so an operation can be observed in flight
  /// instead of racing against it.
  private final class CaptureGate: @unchecked Sendable {
    let entered = TestSignal()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func enter() async {
      await withCheckedContinuation { continuation in
        let open = lock.withLock {
          if released { return true }
          self.continuation = continuation
          return false
        }
        entered.signal()
        if open { continuation.resume() }
      }
    }

    func release() {
      let pending = lock.withLock {
        released = true
        let pending = continuation
        continuation = nil
        return pending
      }
      pending?.resume()
    }
  }

  private final class RecordingFrameSink: ScreenSharingFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pushed: [Int64] = []
    var frames: [Int64] { lock.withLock { pushed } }
    func push(_ frame: ScreenSharingVideoFrame) { lock.withLock { pushed.append(frame.timestampNs) } }
  }
#endif
