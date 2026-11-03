import CoreMedia
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingVCPEncoderStateTests {
  @Test func aNewPictureSkippedAgainAndAgainIsRetriedThenLeftUnchanged() throws {
    var state = ScreenSharingVCPEncoderState()
    let request = try Self.request()
    let attempts = ScreenSharingVCPEncoderState.retriesOfANewCapture + 1

    let skips = try (0..<attempts).map { _ in try Self.skip(request, in: &state).map(Self.describe) }

    #expect(skips == Array(repeating: "dropped", count: attempts - 1) + ["unchanged"])
  }

  @Test func aSkippedRepeatOfTheLastEncodedPictureIsUnchanged() throws {
    var state = ScreenSharingVCPEncoderState()
    let request = try Self.request()
    let encoded = try state.begin(request, refresh: nil, atNs: 1)
    let first = state.receive(try Self.output(encoded, encoded: true))

    let repeated = try Self.skip(request, in: &state)

    #expect(first.map(Self.describe) == "encoded")
    #expect(repeated.map(Self.describe) == "unchanged")
  }

  @Test func anErrorFailsTheFrameAndLaterOutputsForItAreIgnored() throws {
    var state = ScreenSharingVCPEncoderState()
    let submission = try state.begin(try Self.request(), refresh: .keyframe, atNs: 1)

    let failed = state.receive(try Self.output(submission, encoded: false, status: kVTVideoEncoderMalfunctionErr))
    let late = state.receive(try Self.output(submission, encoded: true))

    #expect(failed.map(Self.describe) == "failed")
    #expect(late == nil)
  }

  @Test func presentationTimesStayAtLeastA240thOfASecondApart() throws {
    var state = ScreenSharingVCPEncoderState()
    let request = try Self.request()

    let first = try state.begin(request, refresh: nil, atNs: 1_000)
    let second = try state.begin(request, refresh: nil, atNs: 1_001)

    #expect(second.presentationNs - first.presentationNs == ScreenSharingVCPRate.shortestFrameGapNs)
  }

  private static func skip(
    _ request: ScreenSharingTileEncodeRequest, in state: inout ScreenSharingVCPEncoderState
  )
    throws -> ScreenSharingVCPReceipt?
  {
    let submission = try state.begin(request, refresh: nil, atNs: 1)
    return state.receive(try output(submission, encoded: false))
  }

  private static func describe(_ receipt: ScreenSharingVCPReceipt) -> String {
    switch receipt {
    case .encoded: "encoded"
    case .skipped(_, let unchanged): unchanged ? "unchanged" : "dropped"
    case .failed: "failed"
    }
  }

  private static func request() throws -> ScreenSharingTileEncodeRequest {
    let frame = try TestBGRAPixels.frame(width: 64, height: 64, shades: [10], timestampNs: 1)
    return ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: 1, capturedNs: 1,
      update: ScreenSharingTileUpdate(id: 1, tiles: [0]))
  }

  private static func output(
    _ submission: ScreenSharingVCPSubmission, encoded: Bool, status: OSStatus = noErr
  ) throws
    -> ScreenSharingVCPOutput
  {
    ScreenSharingVCPOutput(
      submission: submission.id, status: status, flags: encoded ? [] : .frameDropped,
      sample: encoded ? try sample() : nil)
  }

  private static func sample() throws -> CMSampleBuffer {
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreate(
      allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
      formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw ScreenSharingError.codec("Create test sample", status) }

    return sample
  }
}
