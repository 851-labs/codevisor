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
  private let fallbackBuilds = TestSignal()

  @Test func theFallbackIsBuiltOnceAndOnlyWhenThePrimaryFails() throws {
    let failing = FailingTileEncoder(primary)
    let encoder = fallingBack(from: failing)

    try encoder.encode(try Self.request(id: 1))
    let beforeFailure = fallbackBuilds.value
    failing.fail(.throwsOnEncode)
    try encoder.encode(try Self.request(id: 2))
    try encoder.encode(try Self.request(id: 3))

    #expect(beforeFailure == 0)
    #expect(fallbackBuilds.value == 1)
    #expect(fallback.requests.map(\.update.id) == [2, 3])
  }

  @Test func aFailedOutputReachesTheHostAtOnceAndStartsBuildingTheFallback() async throws {
    let encoder = fallingBack(from: primary)
    let reported = TestSignal()
    encoder.onOutput { _ in reported.signal() }

    try encoder.encode(try Self.request(id: 1))
    primary.emit(.failed(tile: 0, refresh: nil, message: "broken"))
    await fallbackBuilds.cancellableWait(for: 1)

    #expect(reported.value == 1)
    #expect(fallbackBuilds.value == 1)
  }

  @Test func aFallbackThatCannotBeBuiltIsTriedAgainOnALaterEncode() throws {
    let attempts = TestSignal()
    let encoder = failingOver(retryingBuildsAfterNs: 0, attempts: attempts) { attempts.value < 2 }

    #expect(throws: ScreenSharingError.self) { try encoder.encode(try Self.request(id: 1)) }
    try encoder.encode(try Self.request(id: 2))

    #expect(attempts.value == 2)
    #expect(fallback.requests.map(\.update.id) == [2])
    #expect(metrics.label("encoderFallbackBuildError") != nil)
  }

  @Test func aFailedBuildIsNotRetriedBeforeItsRetryInterval() throws {
    let attempts = TestSignal()
    let encoder = failingOver(retryingBuildsAfterNs: 60_000_000_000, attempts: attempts) { true }

    #expect(throws: ScreenSharingError.self) { try encoder.encode(try Self.request(id: 1)) }
    #expect(throws: ScreenSharingError.self) { try encoder.encode(try Self.request(id: 2)) }

    #expect(attempts.value == 1)
    #expect(fallback.requests.isEmpty)
  }

  @Test func anEncodeThePrimaryRefusesGoesToTheFallbackAtOnce() throws {
    let failing = FailingTileEncoder(primary)
    let encoder = fallingBack(from: failing)
    let request = try Self.request(id: 1)

    failing.fail(.throwsOnEncode)
    try encoder.encode(request)

    #expect(primary.requests.isEmpty)
    #expect(fallback.requests.map(\.update.id) == [1])
    #expect(metrics.counter("encoderFallbacks") == 1)
  }

  @Test func aFailedOutputIsReportedOnceAndLaterEncodesUseTheFallback() throws {
    let encoder = fallingBack(from: primary)
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

  @Test func theRefinementPolicyFollowsTheEncoderInUse() throws {
    let converging = RecordingTileEncoder(refinementPolicy: ScreenSharingV2RefinementPolicy(convergedBelowBytes: 200))
    let failing = FailingTileEncoder(converging)
    let encoder = fallingBack(from: failing)
    let before = encoder.refinementPolicy

    failing.fail(.throwsOnEncode)
    try encoder.encode(try Self.request(id: 1))

    #expect(before.convergedBelowBytes == 200)
    #expect(encoder.refinementPolicy == .standard)
  }

  @Test func afterTheFallbackOnlyTokensTheFallbackIssuedAreAcknowledged() throws {
    let failing = FailingTileEncoder(primary)
    let encoder = fallingBack(from: failing)
    failing.fail(.throwsOnEncode)
    let request = try Self.request(id: 1)
    try encoder.encode(request)

    fallback.emitTile(of: request, keyframe: true, token: 9)
    encoder.acknowledge([3, 9], tile: 0)

    #expect(fallback.acknowledgedTokens == [9])
    #expect(primary.acknowledgedTokens.isEmpty)
  }

  @Test func failuresThePrimaryReportsWhileStoppingAreNotAFallback() throws {
    let encoder = fallingBack(from: primary)

    encoder.stop()
    primary.emit(.failed(tile: 0, refresh: nil, message: "VCP stopped"))

    #expect(metrics.counter("encoderFallbacks") == 0)
  }

  @Test func aFallbackWithAnotherTileLayoutIsRefused() throws {
    let tiled = RecordingTileEncoder(layout: ScreenSharingV2TileLayout(width: 640, height: 360, count: 4))
    let failing = FailingTileEncoder(primary)
    let encoder = ScreenSharingFallbackTileEncoder(primary: failing, metrics: metrics) { _ in tiled }

    failing.fail(.throwsOnEncode)

    #expect(throws: ScreenSharingError.self) { try encoder.encode(try Self.request(id: 1)) }
    #expect(tiled.requests.isEmpty)
  }

  private func failingOver(
    retryingBuildsAfterNs retryNs: Int64, attempts: TestSignal, buildFails: @escaping @Sendable () -> Bool
  ) -> ScreenSharingFallbackTileEncoder {
    let failing = FailingTileEncoder(primary)
    failing.fail(.throwsOnEncode)
    return ScreenSharingFallbackTileEncoder(primary: failing, metrics: metrics, buildRetryNs: retryNs) {
      [fallback] _ in
      attempts.signal()
      guard !buildFails() else { throw ScreenSharingError.unavailable("No hardware encoder.") }

      return fallback
    }
  }

  private func fallingBack(from primary: any ScreenSharingTileEncoder) -> ScreenSharingFallbackTileEncoder {
    ScreenSharingFallbackTileEncoder(primary: primary, metrics: metrics) { [fallback, fallbackBuilds] _ in
      fallbackBuilds.signal()
      return fallback
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
