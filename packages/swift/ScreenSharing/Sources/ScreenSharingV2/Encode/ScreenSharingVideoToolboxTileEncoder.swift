import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

public final class ScreenSharingVideoToolboxTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  private struct State {
    var output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
    var inFlight = 0
    var acknowledged: [UInt64] = []
    var carriedRefresh: ScreenSharingTileRefresh?
    var lastPresentationNs: Int64 = 0
    var stopped = false
  }

  private struct Submission: Sendable {
    let request: ScreenSharingTileEncodeRequest
    let refresh: ScreenSharingTileRefresh?
    let submittedNs: Int64
  }

  public let tileCount = 1
  private let session: VTCompressionSession
  private let metrics: ScreenSharingMetrics
  private let state = Mutex(State())

  public init(configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics) throws {
    session = try ScreenSharingVideoToolboxSessionFactory(
      width: configuration.width, height: configuration.height, framesPerSecond: configuration.framesPerSecond,
      bitrate: configuration.bitrate
    ).make()
    self.metrics = metrics
    metrics.label("encoder", "VideoToolbox HEVC Main, low-latency rate control, LTR, no periodic keyframe")
    metrics.label("encoderSize", "\(configuration.width)x\(configuration.height)")
  }

  deinit { stop() }

  public var framesInFlight: Int { state.withLock { $0.inFlight } }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    state.withLock { $0.output = handler }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    let (submission, acknowledged, presentationNs) = try begin(request)
    let status = VTCompressionSessionEncodeFrame(
      session, imageBuffer: request.pixelBuffer,
      presentationTimeStamp: CMTime(value: presentationNs, timescale: 1_000_000_000), duration: .invalid,
      frameProperties: Self.frameOptions(submission.refresh, acknowledged: acknowledged), infoFlagsOut: nil
    ) { [weak self] status, flags, sample in
      self?.didEncode(submission, status: status, flags: flags, sample: sample)
    }
    guard status != noErr else { return }

    finish(submission, delivered: false)
    throw ScreenSharingError.codec("Encode frame", status)
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard tile == 0 else { return }

    state.withLock { $0.acknowledged += tokens }
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    let status = VTSessionSetProperty(
      session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
    guard status == noErr else { throw ScreenSharingError.codec("Set encoder bitrate", status) }

    metrics.label("encoderBitrate", String(bitsPerSecond))
  }

  public func stop() {
    let wasRunning = state.withLock { state in
      defer { state.stopped = true; state.output = nil }
      return !state.stopped
    }
    guard wasRunning else { return }

    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
  }

  private func begin(_ request: ScreenSharingTileEncodeRequest) throws -> (Submission, [UInt64], Int64) {
    try state.withLock { state in
      guard !state.stopped else { throw ScreenSharingError.unavailable("Encoder stopped.") }

      let submittedNs = ScreenSharingMetrics.nowNs
      let refresh = Self.stronger(request.refreshes[0], state.carriedRefresh)
      let acknowledged = state.acknowledged
      state.carriedRefresh = nil
      state.acknowledged = []
      state.inFlight += 1
      state.lastPresentationNs = max(state.lastPresentationNs + 1, submittedNs)
      let submission = Submission(request: request, refresh: refresh, submittedNs: submittedNs)
      return (submission, acknowledged, state.lastPresentationNs)
    }
  }

  private func didEncode(_ submission: Submission, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?)
  {
    guard status == noErr, !flags.contains(.frameDropped), let sample else {
      report(dropped: submission, status: status)
      return
    }

    do {
      deliver(try tile(submission, sample: ScreenSharingEncodedSample(sample)))
    } catch {
      metrics.increment("encodeErrors")
      finish(submission, delivered: false)
      emit(.failed(error.localizedDescription))
    }
  }

  private func tile(_ submission: Submission, sample: ScreenSharingEncodedSample) -> ScreenSharingEncodedTile {
    ScreenSharingEncodedTile(
      tile: 0, sourceTimestampNs: submission.request.sourceTimestampNs, capturedNs: submission.request.capturedNs,
      submittedNs: submission.submittedNs, encodedNs: ScreenSharingMetrics.nowNs, isKeyFrame: sample.isKeyFrame,
      refresh: sample.isKeyFrame ? .keyframe : submission.refresh, ltrToken: sample.ltrToken,
      accessUnit: sample.accessUnit)
  }

  private func deliver(_ tile: ScreenSharingEncodedTile) {
    metrics.increment("encodedFrames")
    metrics.increment("encodedBytes", by: tile.accessUnit.count)
    if tile.isKeyFrame { metrics.increment("encodedKeyFrames") }
    if tile.refresh == .longTermReference { metrics.increment("encodedLTRRefreshes") }
    if tile.ltrToken != nil { metrics.increment("encodedLTRFrames") }
    metrics.observe("encode", milliseconds: Double(tile.encodedNs - tile.submittedNs) / 1_000_000)
    state.withLock { $0.inFlight -= 1 }
    emit(.tile(tile))
  }

  private func report(dropped submission: Submission, status: OSStatus) {
    metrics.increment(status == noErr ? "encoderDroppedFrames" : "encodeErrors")
    finish(submission, delivered: false)
    emit(.dropped(sourceTimestampNs: submission.request.sourceTimestampNs))
  }

  private func finish(_ submission: Submission, delivered: Bool) {
    state.withLock { state in
      state.inFlight -= 1
      guard !delivered else { return }

      state.carriedRefresh = Self.stronger(state.carriedRefresh, submission.refresh)
    }
  }

  private func emit(_ output: ScreenSharingTileEncoderOutput) {
    state.withLock { $0.output }?(output)
  }

  private static func stronger(
    _ first: ScreenSharingTileRefresh?, _ second: ScreenSharingTileRefresh?
  ) -> ScreenSharingTileRefresh? {
    if first == .keyframe || second == .keyframe { return .keyframe }
    return first ?? second
  }

  private static func frameOptions(_ refresh: ScreenSharingTileRefresh?, acknowledged: [UInt64]) -> CFDictionary? {
    var options: [CFString: Any] = [:]
    if !acknowledged.isEmpty { options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledged }
    switch refresh {
    case .keyframe: options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
    case .longTermReference: options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true
    case nil: break
    }
    return options.isEmpty ? nil : options as CFDictionary
  }
}
