import CodevisorTestSupport
import CoreVideo
import Synchronization
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingFallbackTileEncoderTests {
  private let primary = RecordingTileEncoder()
  private let fallback = RecordingTileEncoder()
  private let metrics = ScreenSharingMetrics()

  @Test func anEncodeThePrimaryRefusesGoesToTheFallbackAtOnce() throws {
    let failing = FailingTileEncoder(primary)
    let encoder = try ScreenSharingFallbackTileEncoder(primary: failing, fallback: fallback, metrics: metrics)
    let request = try Self.request(id: 1)

    failing.fail(.throwsOnEncode)
    try encoder.encode(request)

    #expect(primary.requests.isEmpty)
    #expect(fallback.requests.map(\.update.id) == [1])
    #expect(metrics.counter("encoderFallbacks") == 1)
  }

  @Test func aFailedOutputIsReportedOnceAndLaterEncodesUseTheFallback() throws {
    let encoder = try ScreenSharingFallbackTileEncoder(primary: primary, fallback: fallback, metrics: metrics)
    let outputs = Mutex<[ScreenSharingTileEncoderOutput]>([])
    encoder.onOutput { output in outputs.withLock { $0.append(output) } }
    try encoder.setBitrate(8_000_000)
    let first = try Self.request(id: 1)

    try encoder.encode(first)
    primary.emit(.failed(tile: 0, refresh: nil, message: "broken"))
    primary.emitTile(of: first, keyframe: false, token: nil)
    try encoder.encode(try Self.request(id: 2))

    #expect(primary.requests.map(\.update.id) == [1])
    #expect(fallback.requests.map(\.update.id) == [2])
    #expect(outputs.withLock { $0 }.allSatisfy(Self.isFailure))
    #expect(outputs.withLock { $0.count } == 2)
    #expect(metrics.label("encoderFallbackReason") == "broken")
  }

  @Test func afterTheFallbackOnlyTokensTheFallbackIssuedAreAcknowledged() throws {
    let failing = FailingTileEncoder(primary)
    let encoder = try ScreenSharingFallbackTileEncoder(primary: failing, fallback: fallback, metrics: metrics)
    failing.fail(.throwsOnEncode)
    let request = try Self.request(id: 1)
    try encoder.encode(request)

    fallback.emitTile(of: request, keyframe: true, token: 9)
    encoder.acknowledge([3, 9], tile: 0)

    #expect(fallback.acknowledgedTokens == [9])
    #expect(primary.acknowledgedTokens.isEmpty)
  }

  @Test func failuresThePrimaryReportsWhileStoppingAreNotAFallback() throws {
    let encoder = try ScreenSharingFallbackTileEncoder(primary: primary, fallback: fallback, metrics: metrics)

    encoder.stop()
    primary.emit(.failed(tile: 0, refresh: nil, message: "VCP stopped"))

    #expect(metrics.counter("encoderFallbacks") == 0)
  }

  @Test func aFallbackWithAnotherTileLayoutIsRefused() {
    let tiled = RecordingTileEncoder(layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 4))

    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingFallbackTileEncoder(primary: primary, fallback: tiled, metrics: metrics)
    }
  }

  private static func isFailure(_ output: ScreenSharingTileEncoderOutput) -> Bool {
    guard case .failed = output else { return false }

    return true
  }

  private static func request(id: UInt32) throws -> ScreenSharingTileEncodeRequest {
    let frame = try TestPixels.frame(shade: 100, timestampNs: Int64(id))
    return ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: frame.timestampNs, capturedNs: frame.timestampNs,
      update: ScreenSharingTileUpdate(id: id, tiles: [0]))
  }
}
