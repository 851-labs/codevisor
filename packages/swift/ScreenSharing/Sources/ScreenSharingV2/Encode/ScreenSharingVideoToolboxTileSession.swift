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
    var suspended = false
    var opened = false
    var openingAttempts = 0
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

  private static let openingAttempts = 3

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
    state = Mutex(State(clock: clock, bitrate: factory.startingBitrate))
    session = try factory.make()
  }

  var bitrate: Int { state.withLock { $0.bitrate } }

  func encode(_ pixels: CVPixelBuffer, request: ScreenSharingTileEncodeRequest, sharing bitsPerSecond: Int) throws {
    try resume()
    try reopenFailedSession()
    if let target = target(sharing: bitsPerSecond) { apply(target) }
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

  private func setBitrate(_ bitsPerSecond: Int) throws {
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

  func suspend() {
    let suspending = state.withLock { state in
      defer { if !state.closed { state.suspended = true } }
      return !state.closed && !state.suspended
    }
    guard suspending else { return }

    close(currentSession)
    metrics.increment("encoderSessionSuspends")
  }

  func resume() throws {
    guard state.withLock({ $0.suspended && !$0.closed }) else { return }

    let replacement = try factory.make()
    sessionLock.withLock { session = replacement }
    state.withLock { state in
      state.suspended = false
      state.sessionFailed = false
      state.acknowledged = []
      state.bitrate = factory.startingBitrate
      state.opened = false
      state.openingAttempts = 0
    }
  }

  private var currentSession: VTCompressionSession { sessionLock.withLock { session } }

  private func target(sharing bitsPerSecond: Int) -> Int? {
    state.withLock { state in
      let target = state.opened ? bitsPerSecond : min(bitsPerSecond, factory.openingBitrate)
      if !state.opened {
        state.openingAttempts += 1
        state.opened = state.openingAttempts >= Self.openingAttempts
      }
      return abs(Double(target - state.bitrate)) > Double(state.bitrate) * 0.1 ? target : nil
    }
  }

  private func apply(_ bitsPerSecond: Int) {
    do { try setBitrate(bitsPerSecond) } catch { metrics.label("lastBitrateError", error.localizedDescription) }
  }

  private func reopenFailedSession() throws {
    guard state.withLock({ $0.sessionFailed && !$0.closed }) else { return }

    let replacement = try factory.make()
    let failed = sessionLock.withLock {
      defer { session = replacement }; return session
    }
    close(failed)
    state.withLock {
      $0.sessionFailed = false; $0.acknowledged = []; $0.bitrate = factory.startingBitrate
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
    state.withLock { $0.opened = true }
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
