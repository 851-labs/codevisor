import CoreMedia
import Foundation
import ScreenSharing
import Synchronization
import VideoToolbox

final class ScreenSharingVCPTileSession: @unchecked Sendable {
  let tile: Int
  private let width: Int
  private let height: Int
  private let session: ScreenSharingVCPSession
  private let metrics: ScreenSharingMetrics
  private let relay: ScreenSharingTileOutputRelay
  private let state: Mutex<ScreenSharingVCPEncoderState>
  private let sessionLock = NSLock()

  init(
    tile: Int, factory: ScreenSharingVCPSessionFactory, metrics: ScreenSharingMetrics,
    relay: ScreenSharingTileOutputRelay
  ) throws {
    self.tile = tile
    width = factory.width
    height = factory.height
    self.metrics = metrics
    self.relay = relay
    state = Mutex(ScreenSharingVCPEncoderState(rate: factory.rate))
    session = try factory.make()
    session.sink.onOutput { [weak self] output in self?.didEncode(output) }
  }

  func encode(_ pixels: CVPixelBuffer, request: ScreenSharingTileEncodeRequest) throws {
    try sessionLock.withLock { try submit(pixels, request: request) }
  }

  private func submit(_ pixels: CVPixelBuffer, request: ScreenSharingTileEncodeRequest) throws {
    let submission = try state.withLock {
      try $0.begin(request, refresh: request.refreshes[tile], atNs: ScreenSharingMetrics.nowNs)
    }
    do {
      try capQP(refining: request.update.isRefinement)
    } catch {
      state.withLock { $0.abandon(submission) }
      throw error
    }
    let status = session.encode(
      pixels, submission: submission.id, presentationNs: submission.presentationNs,
      options: options(refresh: submission.refresh).dictionary)
    guard status != noErr else { return }

    state.withLock {
      $0.abandon(submission)
      $0.failure = $0.failure ?? "encode status \(status)"
    }
    throw ScreenSharingError.codec("Encode VCP tile \(tile)", status)
  }

  private func capQP(refining: Bool) throws {
    let change = state.withLock { state -> Int? in
      let wanted = state.rate.highestQP(refining: refining)
      return wanted == state.highestQP ? nil : wanted
    }
    guard let change else { return }

    try session.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, change as CFNumber)
    state.withLock { $0.highestQP = change }
  }

  func acknowledge(_ tokens: [UInt64]) {
    state.withLock { $0.acknowledged += tokens }
  }

  func setRate(_ rate: ScreenSharingVCPRate) throws {
    try session.setBitrate(rate.tileBitsPerSecond)
    state.withLock { $0.rate = rate }
  }

  func setNetworkFeedback(_ feedback: ScreenSharingTileNetworkFeedback) {
    state.withLock { $0.feedback = feedback }
  }

  func close() {
    let wasRunning = sessionLock.withLock { closeSession() }
    guard wasRunning else { return }

    for submission in state.withLock({ $0.unfinished() }) {
      relay.emit(.failed(tile: tile, refresh: submission.refresh, message: "VCP stopped"))
    }
  }

  private func closeSession() -> Bool {
    let wasRunning = state.withLock { state in
      defer { state.stopped = true }
      return !state.stopped
    }
    if wasRunning { session.close() }
    return wasRunning
  }

  private func options(refresh: ScreenSharingTileRefresh?) -> ScreenSharingVCPFrameOptions {
    state.withLock { state in
      ScreenSharingVCPFrameOptions(
        keys: session.api.keys, refresh: refresh, acknowledged: state.takeAcknowledged(), feedback: state.feedback)
    }
  }

  private func didEncode(_ output: ScreenSharingVCPOutput) {
    guard let receipt = state.withLock({ $0.receive(output) }) else { return }

    switch receipt {
    case .encoded(let submission): encoded(output, submission: submission)
    case .skipped(let submission, let unchanged): skipped(submission, unchanged: unchanged)
    case .failed(let submission): failed(submission.refresh, "VCP status \(output.status)")
    }
  }

  private func encoded(_ output: ScreenSharingVCPOutput, submission: ScreenSharingVCPSubmission) {
    guard let sample = output.sample, fits(output) else {
      return failed(submission.refresh, "VCP tile \(tile) has an unexpected size")
    }

    do {
      deliver(try encodedTile(submission, sample: sample), requested: submission.refresh)
    } catch {
      failed(submission.refresh, error.localizedDescription)
    }
  }

  private func fits(_ output: ScreenSharingVCPOutput) -> Bool {
    guard let dimensions = output.dimensions else { return false }

    return Int(dimensions.width) == width && Int(dimensions.height) == height
  }

  private func encodedTile(
    _ submission: ScreenSharingVCPSubmission, sample: CMSampleBuffer
  ) throws
    -> ScreenSharingEncodedTile
  {
    let encoded = try ScreenSharingEncodedSample(sample, tokenKey: session.api.keys.requireToken)
    return ScreenSharingEncodedTile(
      tile: tile, update: submission.update, sourceTimestampNs: submission.sourceTimestampNs,
      capturedNs: submission.capturedNs, submittedNs: submission.submittedNs, encodedNs: ScreenSharingMetrics.nowNs,
      isKeyFrame: encoded.isKeyFrame, refresh: encoded.isKeyFrame ? .keyframe : submission.refresh,
      ltrToken: encoded.ltrToken, accessUnit: encoded.accessUnit)
  }

  private func deliver(_ tile: ScreenSharingEncodedTile, requested: ScreenSharingTileRefresh?) {
    ScreenSharingTileMetrics(metrics).record(tile, requested: requested)
    relay.emit(.tile(tile))
  }

  private func skipped(_ submission: ScreenSharingVCPSubmission, unchanged: Bool) {
    if unchanged, submission.refresh == nil {
      relay.emit(.unchanged(tile: tile, update: submission.update.id))
    } else {
      metrics.increment("encoderDroppedFrames")
      relay.emit(.dropped(tile: tile, refresh: submission.refresh))
    }
  }

  private func failed(_ refresh: ScreenSharingTileRefresh?, _ message: String) {
    metrics.increment("encodeErrors")
    state.withLock { $0.failure = $0.failure ?? message }
    relay.emit(.failed(tile: tile, refresh: refresh, message: message))
  }
}
