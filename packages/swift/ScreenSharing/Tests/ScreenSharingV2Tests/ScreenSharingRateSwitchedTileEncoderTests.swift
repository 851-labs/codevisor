import Synchronization
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingRateSwitchedTileEncoderTests {
  private static let tiled = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)
  private static let fastBitrate = 40_000_000
  private static let slowBitrate = 1_000_000
  private static let fastLink = 100_000_000

  private let fast = RecordingTileEncoder(layout: Self.tiled)
  private let slow = RecordingTileEncoder(layout: Self.tiled)
  private let scheduler = ManualScheduler()
  private let metrics = ScreenSharingMetrics()
  private let outputs = OutputLog()

  @Test func encodesGoToTheSlowEncoderUntilAFastLinkHasHeld() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)

    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    feedback(encoder, roundTripMs: 20)
    scheduler.step(byNs: ScreenSharingV2EncoderRoute.fastAfterNs - 1)
    try encoder.encode(try Self.request(id: 2, tiles: [0]))

    #expect(slow.requests.map(\.update.id) == [1, 2])
    #expect(fast.requests.isEmpty)
  }

  @Test func aFrameAfterTheSwitchToTheFastEncoderItAsksForAKeyframeOfEveryTileItHasNotEncoded() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))

    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [0, 1]))
    let beforeAFrame = keyframesAskedFor
    scheduler.step(byNs: Int64(ScreenSharingV2Profile.frameIntervalUs) * 1_000)

    #expect(beforeAFrame.isEmpty)
    #expect(keyframesAskedFor == [2, 3])
    #expect(metrics.counter("encoderSwitches") == 1)
  }

  @Test func eachTilesFirstEncodeOnTheFastEncoderIsAKeyframeWhateverRefreshTheHostAskedFor() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))

    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [1], refreshes: [1: .longTermReference]))
    try encoder.encode(try Self.request(id: 3, tiles: [1, 2]))

    #expect(fast.requests.map(\.refreshes) == [[1: .keyframe], [2: .keyframe]])
  }

  @Test func aTileWhoseFirstEncodeOnTheFastEncoderFailedIsStillAKeyframeOnTheNextTry() throws {
    let failing = FailingTileEncoder(fast)
    let encoder = try switched(bitrate: Self.fastBitrate, fast: failing)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    switchToFast(encoder)

    failing.fail(.throwsOnEncode)
    #expect(throws: ScreenSharingError.self) { try encoder.encode(try Self.request(id: 2, tiles: [1])) }
    failing.fail(.none)
    try encoder.encode(try Self.request(id: 3, tiles: [1]))

    #expect(fast.requests.map(\.refreshes) == [[1: .keyframe]])
  }

  @Test func aLateTileFromTheEncoderThatLostTheTileIsDroppedAndOthersPass() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    let first = try Self.request(id: 1, tiles: [0, 1, 2, 3])
    try encoder.encode(first)
    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [0]))

    slow.emitTile(of: first, tile: 0, keyframe: false, token: nil)
    slow.emitTile(of: first, tile: 1, keyframe: false, token: nil)

    #expect(tileOutputs == ["dropped 0", "tile 1"])
  }

  @Test func aLateUnchangedOrFailedTileFromTheEncoderThatLostItIsDroppedToo() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [0, 1]))

    slow.emit(.unchanged(tile: 0, update: 1))
    slow.emit(.failed(tile: 1, refresh: nil, message: "late"))
    slow.emit(.unchanged(tile: 2, update: 1))

    #expect(tileOutputs == ["dropped 0", "dropped 1", "unchanged 2"])
  }

  @Test func theSlowEncoderIsSuspendedOnceTheFastEncoderOwnsEveryTile() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    switchToFast(encoder)

    try encoder.encode(try Self.request(id: 2, tiles: [0, 1]))
    let partly = slow.suspends
    try encoder.encode(try Self.request(id: 3, tiles: [2, 3]))
    try encoder.encode(try Self.request(id: 4, tiles: [0]))

    #expect(partly == 0)
    #expect(slow.suspends == 1)
  }

  @Test func aMoveBackToTheSuspendedSlowEncoderResumesItFirst() throws {
    let encoder = try suspendedSlow()

    try moveToSlow(encoder)
    try encoder.encode(try Self.request(id: 3, tiles: [0]))

    #expect(slow.resumes == 1)
    #expect(slow.requests.last?.update.id == 3)
  }

  @Test func aSlowEncoderThatCannotResumeKeepsTheFastEncoder() throws {
    let encoder = try suspendedSlow()
    slow.resumeFails.withLock { $0 = true }

    try moveToSlow(encoder)
    try encoder.encode(try Self.request(id: 3, tiles: [0]))

    #expect(fast.requests.last?.update.id == 3)
    #expect(metrics.counter("encoderSlowResumeFailures") == 1)
    #expect(metrics.counter("encoderSwitches") == 1)
  }

  @Test func referenceAcknowledgementsGoToTheEncoderThatIssuedTheToken() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    let first = try Self.request(id: 1, tiles: [0])
    try encoder.encode(first)
    slow.emitTile(of: first, keyframe: true, token: 7)
    switchToFast(encoder)
    let second = try Self.request(id: 2, tiles: [0])
    try encoder.encode(second)
    fast.emitTile(of: second, keyframe: true, token: 9)

    encoder.acknowledge([7, 9, 11], tile: 0)

    #expect(slow.acknowledgedTokens == [7])
    #expect(fast.acknowledgedTokens == [9])
  }

  @Test func aSlowLinkMovesBackToTheSlowEncoderWithoutAskingForKeyframes() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [3]))
    scheduler.step(byNs: Int64(ScreenSharingV2Profile.frameIntervalUs) * 1_000)
    clearOutputs()

    try encoder.setBitrate(Self.slowBitrate)
    scheduler.step(byNs: ScreenSharingV2EncoderRoute.slowAfterNs)
    feedback(encoder, roundTripMs: 20, estimate: Self.slowBitrate, loss: ScreenSharingV2EncoderRoute.heavyLoss)
    try encoder.encode(try Self.request(id: 3, tiles: [3]))

    #expect(slow.requests.last?.update.id == 3)
    #expect(slow.requests.last?.refreshes == [3: .keyframe])
    #expect(keyframesAskedFor.isEmpty)
    #expect(metrics.counter("encoderSwitches") == 2)
  }

  private func switched(
    bitrate: Int, fast: (any ScreenSharingTileEncoder)? = nil
  ) throws -> ScreenSharingRateSwitchedTileEncoder {
    let encoder = try ScreenSharingRateSwitchedTileEncoder(
      fast: fast ?? self.fast, slow: slow, bitrate: bitrate, metrics: metrics, scheduler: scheduler)
    encoder.onOutput { [outputs] output in outputs.append(output) }
    return encoder
  }

  private func suspendedSlow() throws -> ScreenSharingRateSwitchedTileEncoder {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [0, 1, 2, 3]))
    return encoder
  }

  private func moveToSlow(_ encoder: ScreenSharingRateSwitchedTileEncoder) throws {
    try encoder.setBitrate(Self.slowBitrate)
    scheduler.step(byNs: ScreenSharingV2EncoderRoute.slowAfterNs)
    feedback(encoder, roundTripMs: 20, estimate: Self.slowBitrate, loss: ScreenSharingV2EncoderRoute.heavyLoss)
  }

  private func switchToFast(_ encoder: ScreenSharingRateSwitchedTileEncoder) {
    scheduler.step(byNs: ScreenSharingV2EncoderRoute.fastAfterNs)
    feedback(encoder, roundTripMs: 20)
  }

  private func feedback(
    _ encoder: ScreenSharingRateSwitchedTileEncoder, roundTripMs: Double, estimate: Int = fastLink, loss: Double = 0
  ) {
    encoder.observeNetwork(
      ScreenSharingTileNetworkFeedback(
        packetErrorRate: loss, roundTripDelayMs: roundTripMs, transmissionBitsPerSecond: estimate,
        transmissionMeasured: true))
  }

  private func clearOutputs() {
    outputs.clear()
  }

  private var keyframesAskedFor: [Int] {
    outputs.all.compactMap { output in
      guard case .keyframeNeeded(let tile) = output else { return nil }

      return tile
    }
  }

  private var tileOutputs: [String] {
    outputs.all.compactMap { output in
      switch output {
      case .tile(let tile): "tile \(tile.tile)"
      case .dropped(let tile, _): "dropped \(tile)"
      case .unchanged(let tile, _): "unchanged \(tile)"
      default: nil
      }
    }
  }

  private static func request(
    id: UInt32, tiles: Set<Int>, refreshes: [Int: ScreenSharingTileRefresh] = [:]
  ) throws -> ScreenSharingTileEncodeRequest {
    let frame = try TestPixels.frame(shade: 100, timestampNs: Int64(id))
    return ScreenSharingTileEncodeRequest(
      pixelBuffer: frame.pixelBuffer, sourceTimestampNs: frame.timestampNs, capturedNs: frame.timestampNs,
      update: ScreenSharingTileUpdate(id: id, tiles: tiles), refreshes: refreshes)
  }
}

private final class OutputLog: Sendable {
  private let outputs = Mutex<[ScreenSharingTileEncoderOutput]>([])

  var all: [ScreenSharingTileEncoderOutput] { outputs.withLock { $0 } }

  func append(_ output: ScreenSharingTileEncoderOutput) {
    outputs.withLock { $0.append(output) }
  }

  func clear() {
    outputs.withLock { $0 = [] }
  }
}
