import CoreMedia
import ScreenSharing
import Synchronization
import VideoToolbox

final class ScreenSharingVideoToolboxTileSession: @unchecked Sendable {
  private struct State {
    var inFlight: Set<UInt64> = []
    var nextSubmission: UInt64 = 0
    var acknowledged: [UInt64] = []
    var clock: ScreenSharingEncoderPresentationClock
    var sessionFailed = false
    var closed = false
    var bitrate: Int
  }

  private struct Submission: Sendable {
    let id: UInt64
    let update: ScreenSharingTileUpdate
    let sourceTimestampNs: Int64
    let capturedNs: Int64
    let refresh: ScreenSharingTileRefresh?
    let submittedNs: Int64
  }

  private static let sessionFailures: Set<OSStatus> = [
    kVTVideoEncoderMalfunctionErr, kVTVideoEncoderNotAvailableNowErr, kVTInvalidSessionErr,
  ]

  let tile: Int
  private let factory: ScreenSharingVideoToolboxSessionFactory
  private let sessionLock = NSLock()
  private var session: VTCompressionSession
  private let metrics: ScreenSharingMetrics
  private let relay: ScreenSharingTileOutputRelay
  private let state: Mutex<State>

  init(
    tile: Int, factory: ScreenSharingVideoToolboxSessionFactory, metrics: ScreenSharingMetrics,
    relay: ScreenSharingTileOutputRelay
  ) throws {
    self.tile = tile
    self.factory = factory
    self.metrics = metrics
    self.relay = relay
    let clock = ScreenSharingEncoderPresentationClock(framesPerSecond: factory.framesPerSecond)
    state = Mutex(State(clock: clock, bitrate: factory.bitrate))
    session = try factory.make()
  }

  var bitrate: Int { state.withLock { $0.bitrate } }

  var hasEncoded: Bool { state.withLock { $0.nextSubmission > 0 } }

  func share(_ bitsPerSecond: Int) throws {
    let applied = bitrate
    guard abs(Double(bitsPerSecond - applied)) > Double(applied) * 0.1 else { return }

    try setBitrate(bitsPerSecond)
  }

  func encode(_ pixels: CVPixelBuffer, request: ScreenSharingTileEncodeRequest) throws {
    try reopenFailedSession()
    let (submission, acknowledged, presentationNs) = try begin(request)
    defer {
      metrics.observe("encodeCall", milliseconds: Double(ScreenSharingMetrics.nowNs - submission.submittedNs) / 1e6)
    }
    let status = VTCompressionSessionEncodeFrame(
      currentSession, imageBuffer: pixels,
      presentationTimeStamp: CMTime(value: presentationNs, timescale: 1_000_000_000), duration: .invalid,
      frameProperties: Self.frameOptions(submission.refresh, acknowledged: acknowledged), infoFlagsOut: nil
    ) { [weak self] status, flags, sample in
      self?.didEncode(submission, status: status, flags: flags, sample: sample)
    }
    guard status != noErr else { return }

    _ = release(submission)
    noteSessionFailure(status)
    throw ScreenSharingError.codec("Encode tile \(tile)", status)
  }

  func acknowledge(_ tokens: [UInt64]) {
    state.withLock { $0.acknowledged += tokens }
  }

  func setBitrate(_ bitsPerSecond: Int) throws {
    let status = VTSessionSetProperty(
      currentSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
    guard status == noErr else { throw ScreenSharingError.codec("Set encoder bitrate", status) }

    state.withLock { $0.bitrate = bitsPerSecond }
  }

  func close() {
    let wasOpen = state.withLock { state in
      defer { state.closed = true }
      return !state.closed
    }
    guard wasOpen else { return }

    close(currentSession)
  }

  private var currentSession: VTCompressionSession { sessionLock.withLock { session } }

  private func reopenFailedSession() throws {
    guard state.withLock({ $0.sessionFailed && !$0.closed }) else { return }

    let replacement = try factory.make()
    let failed = sessionLock.withLock {
      defer { session = replacement }; return session
    }
    close(failed)
    state.withLock {
      $0.sessionFailed = false; $0.acknowledged = []; $0.bitrate = factory.bitrate
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
      guard !state.closed else { throw ScreenSharingError.unavailable("Encoder stopped.") }

      let submittedNs = ScreenSharingMetrics.nowNs
      let acknowledged = state.acknowledged
      state.acknowledged = []
      state.nextSubmission += 1
      state.inFlight.insert(state.nextSubmission)
      let presentationNs = state.clock.presentationNs(submittedAtNs: submittedNs)
      let submission = Submission(
        id: state.nextSubmission, update: request.update, sourceTimestampNs: request.sourceTimestampNs,
        capturedNs: request.capturedNs, refresh: request.refreshes[tile], submittedNs: submittedNs)
      return (submission, acknowledged, presentationNs)
    }
  }

  private func didEncode(_ submission: Submission, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?)
  {
    guard release(submission) else { return }
    guard status == noErr else { return failed(submission, "VideoToolbox status \(status)", status: status) }
    guard !flags.contains(.frameDropped), let sample else { return dropped(submission) }

    do {
      deliver(try encodedTile(submission, sample: ScreenSharingEncodedSample(sample)))
    } catch {
      failed(submission, error.localizedDescription, status: noErr)
    }
  }

  private func encodedTile(_ submission: Submission, sample: ScreenSharingEncodedSample) -> ScreenSharingEncodedTile {
    ScreenSharingEncodedTile(
      tile: tile, update: submission.update, sourceTimestampNs: submission.sourceTimestampNs,
      capturedNs: submission.capturedNs, submittedNs: submission.submittedNs, encodedNs: ScreenSharingMetrics.nowNs,
      isKeyFrame: sample.isKeyFrame, refresh: sample.isKeyFrame ? .keyframe : submission.refresh,
      ltrToken: sample.ltrToken, accessUnit: sample.accessUnit)
  }

  private func deliver(_ encoded: ScreenSharingEncodedTile) {
    ScreenSharingTileMetrics(metrics).record(encoded)
    relay.emit(.tile(encoded))
  }

  private func dropped(_ submission: Submission) {
    metrics.increment("encoderDroppedFrames")
    relay.emit(.dropped(tile: tile, refresh: submission.refresh))
  }

  private func failed(_ submission: Submission, _ message: String, status: OSStatus) {
    metrics.increment("encodeErrors")
    noteSessionFailure(status)
    relay.emit(.failed(tile: tile, refresh: submission.refresh, message: message))
  }

  private func release(_ submission: Submission) -> Bool {
    state.withLock { $0.inFlight.remove(submission.id) != nil }
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
