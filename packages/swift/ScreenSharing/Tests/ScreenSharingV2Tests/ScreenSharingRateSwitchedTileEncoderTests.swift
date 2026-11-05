import Synchronization
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingRateSwitchedTileEncoderTests {
  private static let tiled = ScreenSharingV2TileLayout(width: 640, height: 360, count: 4)
  private static let fastBitrate = 20_000_000
  private static let slowBitrate = 1_000_000

  private let fast = RecordingTileEncoder(layout: Self.tiled)
  private let slow = RecordingTileEncoder(layout: Self.tiled)
  private let scheduler = SteppedScheduler()
  private let metrics = ScreenSharingMetrics()
  private let outputs = OutputLog()

  @Test func encodesGoToTheSlowEncoderUntilAFastLinkHasHeld() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)

    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))
    feedback(encoder, roundTripMs: 20)
    scheduler.advance(byNs: ScreenSharingV2EncoderRoute.fastAfterNs - 1)
    try encoder.encode(try Self.request(id: 2, tiles: [0]))

    #expect(slow.requests.map(\.update.id) == [1, 2])
    #expect(fast.requests.isEmpty)
  }

  @Test func theSwitchToTheFastEncoderAsksForAKeyframeOfEveryTileAndForcesOneOnEachTileItFirstEncodes() throws {
    let encoder = try switched(bitrate: Self.fastBitrate)
    try encoder.encode(try Self.request(id: 1, tiles: [0, 1, 2, 3]))

    switchToFast(encoder)
    try encoder.encode(try Self.request(id: 2, tiles: [1], refreshes: [1: .longTermReference]))
    try encoder.encode(try Self.request(id: 3, tiles: [1, 2]))

    #expect(keyframesAskedFor == [0, 1, 2, 3])
    #expect(fast.requests.map(\.refreshes) == [[1: .keyframe], [2: .keyframe]])
    #expect(metrics.counter("encoderSwitches") == 1)
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
    clearOutputs()

    try encoder.setBitrate(Self.slowBitrate)
    scheduler.advance(byNs: ScreenSharingV2EncoderRoute.slowAfterNs)
    try encoder.encode(try Self.request(id: 3, tiles: [3]))

    #expect(slow.requests.last?.update.id == 3)
    #expect(slow.requests.last?.refreshes == [3: .keyframe])
    #expect(keyframesAskedFor.isEmpty)
    #expect(metrics.counter("encoderSwitches") == 2)
  }

  private func switched(bitrate: Int) throws -> ScreenSharingRateSwitchedTileEncoder {
    let encoder = try ScreenSharingRateSwitchedTileEncoder(
      fast: fast, slow: slow, bitrate: bitrate, metrics: metrics, scheduler: scheduler)
    encoder.onOutput { [outputs] output in outputs.append(output) }
    return encoder
  }

  private func switchToFast(_ encoder: ScreenSharingRateSwitchedTileEncoder) {
    scheduler.advance(byNs: ScreenSharingV2EncoderRoute.fastAfterNs)
    feedback(encoder, roundTripMs: 20)
  }

  private func feedback(_ encoder: ScreenSharingRateSwitchedTileEncoder, roundTripMs: Double) {
    encoder.observeNetwork(
      ScreenSharingTileNetworkFeedback(
        packetErrorRate: 0, roundTripDelayMs: roundTripMs, transmissionBitsPerSecond: Self.fastBitrate))
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
