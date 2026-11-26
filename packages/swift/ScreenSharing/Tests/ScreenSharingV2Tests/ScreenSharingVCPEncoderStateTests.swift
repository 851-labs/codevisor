import CoreMedia
import Testing
import VideoToolbox

@testable import ScreenSharing
@testable import ScreenSharingV2

struct ScreenSharingVCPEncoderStateTests {
  private static let repeatedSkips = 5

  @Test func aSkippedPictureTheSessionNeverEncodedIsAlwaysADrop() throws {
    var state = ScreenSharingVCPEncoderState()
    let request = try Self.request()

    let skips = try (0..<Self.repeatedSkips).map { _ in try Self.skip(request, in: &state).map(Self.describe) }

    #expect(skips == Array(repeating: "dropped", count: Self.repeatedSkips))
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

  @Test func aSmallChangeRightAfterASharpeningPassKeepsTheCapTheSessionHas() throws {
    var state = ScreenSharingVCPEncoderState()

    let sharpening = try Self.begin(try Self.request(refinement: true), in: &state)
    let typed = try Self.begin(try Self.request(small: [0]), in: &state)

    #expect(sharpening.highestQP == ScreenSharingVCPRate.highestRefinementQP)
    #expect(typed.highestQP == ScreenSharingVCPRate.highestRefinementQP)
  }

  @Test func aLargeChangeOrASmallChangeOfAnotherTileGoesBackToTheNormalCap() throws {
    for small in [Set<Int>(), [1]] {
      var state = ScreenSharingVCPEncoderState()
      _ = try Self.begin(try Self.request(refinement: true), in: &state)

      let change = try Self.begin(try Self.request(small: small), in: &state)

      #expect(change.highestQP == ScreenSharingVCPRate.highestFrameQP)
    }
  }

  @Test(arguments: [ScreenSharingTileRefresh.keyframe, .longTermReference])
  func aSmallChangeThatIsAlsoARefreshGoesBackToTheNormalCap(refresh: ScreenSharingTileRefresh) throws {
    var state = ScreenSharingVCPEncoderState()
    _ = try Self.begin(try Self.request(refinement: true), in: &state)

    let change = try Self.begin(try Self.request(small: [0]), refresh: refresh, in: &state)

    #expect(change.highestQP == ScreenSharingVCPRate.highestFrameQP)
  }

  @Test func theSecondSmallChangeInARowGoesBackToTheNormalCap() throws {
    var state = ScreenSharingVCPEncoderState()
    _ = try Self.begin(try Self.request(refinement: true), in: &state)

    let first = try Self.begin(try Self.request(small: [0]), in: &state)
    let second = try Self.begin(try Self.request(small: [0]), in: &state)

    #expect(first.highestQP == ScreenSharingVCPRate.highestRefinementQP)
    #expect(second.highestQP == ScreenSharingVCPRate.highestFrameQP)
  }

  @Test func onceTheBitrateFallsBelowApplesLadderASmallChangeGoesBackToTheNormalCap() throws {
    var state = ScreenSharingVCPEncoderState()
    _ = try Self.begin(try Self.request(refinement: true), in: &state)

    let capBeforeTheBitrateFell = state.highestQP
    state.rate = ScreenSharingVCPRate(bitsPerSecond: ScreenSharingVCPRate.nearLosslessFromBitsPerSecond - 1, tiles: 1)
    let change = try Self.begin(try Self.request(small: [0]), in: &state)

    #expect(capBeforeTheBitrateFell == ScreenSharingVCPRate.highestRefinementQP)
    #expect(change.highestQP == ScreenSharingVCPRate.highestFrameQP)
  }

  private static func begin(
    _ request: ScreenSharingTileEncodeRequest, refresh: ScreenSharingTileRefresh? = nil,
    in state: inout ScreenSharingVCPEncoderState
  ) throws -> ScreenSharingVCPSubmission {
    let submission = try state.begin(request, refresh: refresh, atNs: 1)
    state.highestQP = submission.highestQP
    return submission
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

  private static func request(
    refinement: Bool = false, small: Set<Int> = []
  ) throws -> ScreenSharingTileEncodeRequest {
    let frame = try TestBGRAPixels.frame(width: 64, height: 64, shades: [10], timestampNs: 1)
    return ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: 1, capturedNs: 1,
      update: ScreenSharingTileUpdate(id: 1, tiles: [0], isRefinement: refinement), smallTiles: small)
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
