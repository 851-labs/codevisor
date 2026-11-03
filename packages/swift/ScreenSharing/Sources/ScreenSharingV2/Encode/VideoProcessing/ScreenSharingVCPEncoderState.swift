import CoreMedia
import ScreenSharing

struct ScreenSharingVCPEncoderState {
  var acknowledged: [UInt64] = []
  var feedback: ScreenSharingTileNetworkFeedback?
  var failure: String?
  var stopped = false
  private var inFlight: [UInt64: ScreenSharingVCPSubmission] = [:]
  private var lastEncodedCapture: Int64?
  private var nextSubmission: UInt64 = 0
  private var lastPresentationNs: Int64 = 0

  mutating func begin(
    _ request: ScreenSharingTileEncodeRequest, refresh: ScreenSharingTileRefresh?, atNs nowNs: Int64
  )
    throws -> ScreenSharingVCPSubmission
  {
    guard !stopped else { throw ScreenSharingError.unavailable("Encoder stopped.") }
    if let failure { throw ScreenSharingError.unavailable("VCP failed: \(failure)") }

    nextSubmission += 1
    lastPresentationNs = max(lastPresentationNs + ScreenSharingVCPRate.shortestFrameGapNs, nowNs)
    let submission = ScreenSharingVCPSubmission(
      id: nextSubmission, update: request.update, sourceTimestampNs: request.sourceTimestampNs,
      capturedNs: request.capturedNs, refresh: refresh, submittedNs: nowNs, presentationNs: lastPresentationNs)
    inFlight[submission.id] = submission
    return submission
  }

  mutating func takeAcknowledged() -> [UInt64] {
    defer { acknowledged = [] }
    return acknowledged
  }

  mutating func abandon(_ submission: ScreenSharingVCPSubmission) {
    inFlight[submission.id] = nil
  }

  mutating func receive(_ output: ScreenSharingVCPOutput) -> ScreenSharingVCPReceipt? {
    guard let submission = inFlight.removeValue(forKey: output.submission) else { return nil }
    guard output.status == noErr else { return .failed(submission) }

    let capture = submission.sourceTimestampNs
    guard output.sample == nil else {
      lastEncodedCapture = capture
      return .encoded(submission)
    }
    return .skipped(submission, unchanged: lastEncodedCapture == capture)
  }

  mutating func unfinished() -> [ScreenSharingVCPSubmission] {
    defer { inFlight = [:] }
    return inFlight.values.sorted { $0.id < $1.id }
  }
}
