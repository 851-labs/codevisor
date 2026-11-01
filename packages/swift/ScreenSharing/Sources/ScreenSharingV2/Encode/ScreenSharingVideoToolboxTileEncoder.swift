import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

public final class ScreenSharingVideoToolboxTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  private struct State {
    var output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
    var inFlight: Set<UInt64> = []
    var nextSubmission: UInt64 = 0
    var acknowledged: [UInt64] = []
    var lastPresentationNs: Int64 = 0
    var sessionFailed = false
    var stopped = false
  }

  private struct Submission: Sendable {
    let id: UInt64
    let request: ScreenSharingTileEncodeRequest
    let refresh: ScreenSharingTileRefresh?
    let submittedNs: Int64
  }

  private static let sessionFailures: Set<OSStatus> = [
    kVTVideoEncoderMalfunctionErr, kVTVideoEncoderNotAvailableNowErr, kVTInvalidSessionErr,
  ]

  public let tileCount = 1
  private let factory: ScreenSharingVideoToolboxSessionFactory
  private let sessionLock = NSLock()
  private var session: VTCompressionSession
  private let metrics: ScreenSharingMetrics
  private let state = Mutex(State())

  public init(configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics) throws {
    factory = ScreenSharingVideoToolboxSessionFactory(
      width: configuration.width, height: configuration.height, framesPerSecond: configuration.framesPerSecond,
      bitrate: configuration.bitrate)
    session = try factory.make()
    self.metrics = metrics
    metrics.label("encoder", "VideoToolbox HEVC Main, low-latency rate control, LTR, no periodic keyframe")
    metrics.label("encoderSize", "\(configuration.width)x\(configuration.height)")
  }

  deinit { stop() }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    state.withLock { $0.output = handler }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    try reopenFailedSession()
    let (submission, acknowledged, presentationNs) = try begin(request)
    let status = VTCompressionSessionEncodeFrame(
      currentSession, imageBuffer: request.pixelBuffer,
      presentationTimeStamp: CMTime(value: presentationNs, timescale: 1_000_000_000), duration: .invalid,
      frameProperties: Self.frameOptions(submission.refresh, acknowledged: acknowledged), infoFlagsOut: nil
    ) { [weak self] status, flags, sample in
      self?.didEncode(submission, status: status, flags: flags, sample: sample)
    }
    guard status != noErr else { return }

    _ = release(submission)
    noteSessionFailure(status)
    throw ScreenSharingError.codec("Encode frame", status)
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard tile == 0 else { return }

    state.withLock { $0.acknowledged += tokens }
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    let status = VTSessionSetProperty(
      currentSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
    guard status == noErr else { throw ScreenSharingError.codec("Set encoder bitrate", status) }

    metrics.label("encoderBitrate", String(bitsPerSecond))
  }

  public func stop() {
    let wasRunning = state.withLock { state in
      defer { state.stopped = true; state.output = nil }
      return !state.stopped
    }
    guard wasRunning else { return }

    close(currentSession)
  }

  private var currentSession: VTCompressionSession { sessionLock.withLock { session } }

  private func reopenFailedSession() throws {
    guard state.withLock({ $0.sessionFailed && !$0.stopped }) else { return }

    let replacement = try factory.make()
    let failed = sessionLock.withLock {
      defer { session = replacement }; return session
    }
    close(failed)
    state.withLock {
      $0.sessionFailed = false; $0.acknowledged = []
    }
    metrics.increment("encoderSessionReopens")
  }

  private func close(_ session: VTCompressionSession) {
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
  }

  private func noteSessionFailure(_ status: OSStatus) {
    guard Self.sessionFailures.contains(status) else { return }

    state.withLock { $0.sessionFailed = true }
  }

  private func begin(_ request: ScreenSharingTileEncodeRequest) throws -> (Submission, [UInt64], Int64) {
    try state.withLock { state in
      guard !state.stopped else { throw ScreenSharingError.unavailable("Encoder stopped.") }

      let submittedNs = ScreenSharingMetrics.nowNs
      let acknowledged = state.acknowledged
      state.acknowledged = []
      state.nextSubmission += 1
      state.inFlight.insert(state.nextSubmission)
      state.lastPresentationNs = max(state.lastPresentationNs + 1, submittedNs)
      let submission = Submission(
        id: state.nextSubmission, request: request, refresh: request.refreshes[0], submittedNs: submittedNs)
      return (submission, acknowledged, state.lastPresentationNs)
    }
  }

  private func didEncode(_ submission: Submission, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?)
  {
    guard release(submission) else { return }
    guard status == noErr else { return failed(submission, "VideoToolbox status \(status)", status: status) }
    guard !flags.contains(.frameDropped), let sample else { return dropped(submission) }

    do {
      deliver(try tile(submission, sample: ScreenSharingEncodedSample(sample)))
    } catch {
      failed(submission, error.localizedDescription, status: noErr)
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
    emit(.tile(tile))
  }

  private func dropped(_ submission: Submission) {
    metrics.increment("encoderDroppedFrames")
    emit(.dropped(tile: 0, refresh: submission.refresh))
  }

  private func failed(_ submission: Submission, _ message: String, status: OSStatus) {
    metrics.increment("encodeErrors")
    noteSessionFailure(status)
    emit(.failed(tile: 0, refresh: submission.refresh, message: message))
  }

  private func release(_ submission: Submission) -> Bool {
    state.withLock { $0.inFlight.remove(submission.id) != nil }
  }

  private func emit(_ output: ScreenSharingTileEncoderOutput) {
    state.withLock { $0.output }?(output)
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
