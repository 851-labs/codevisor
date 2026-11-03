import CoreVideo
import ScreenSharing
import Synchronization

public final class ScreenSharingFallbackTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  private struct State {
    var output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
    var fellBackNs: Int64?
    var recoveredFromFallback = false
    var bitrate: Int?
    var fallbackTokens: [Int: [UInt64]] = [:]
    var stopped = false

    mutating func remember(_ token: UInt64, tile: Int) {
      let issued = fallbackTokens[tile, default: []] + [token]
      fallbackTokens[tile] = Array(issued.suffix(ScreenSharingFallbackTileEncoder.rememberedTokens))
    }
  }

  private static let rememberedTokens = 64

  public let layout: ScreenSharingV2TileLayout
  public let sourcePixelFormat: OSType
  private let primary: any ScreenSharingTileEncoder
  private let fallback: any ScreenSharingTileEncoder
  private let metrics: ScreenSharingMetrics
  private let state = Mutex(State())

  public init(
    primary: any ScreenSharingTileEncoder, fallback: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics
  ) throws {
    guard primary.layout == fallback.layout else {
      throw ScreenSharingError.invalid("The fallback encoder has another tile layout.")
    }

    layout = primary.layout
    sourcePixelFormat = primary.sourcePixelFormat
    self.primary = primary
    self.fallback = fallback
    self.metrics = metrics
    primary.onOutput { [weak self] output in self?.primaryOutput(output) }
    fallback.onOutput { [weak self] output in self?.fallbackOutput(output) }
  }

  public var hasFallenBack: Bool { state.withLock { $0.fellBackNs != nil } }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    state.withLock { $0.output = handler }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    guard !hasFallenBack else { return try fallback.encode(request) }

    do {
      try primary.encode(request)
    } catch {
      fallBack(error.localizedDescription)
      try fallback.encode(request)
    }
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard hasFallenBack else { return primary.acknowledge(tokens, tile: tile) }

    let issued = state.withLock { Set($0.fallbackTokens[tile, default: []]) }
    fallback.acknowledge(tokens.filter(issued.contains), tile: tile)
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    state.withLock { $0.bitrate = bitsPerSecond }
    try active.setBitrate(bitsPerSecond)
  }

  public func stop() {
    state.withLock {
      $0.output = nil
      $0.stopped = true
    }
    primary.stop()
    fallback.stop()
  }

  private var active: any ScreenSharingTileEncoder { hasFallenBack ? fallback : primary }

  private func primaryOutput(_ output: ScreenSharingTileEncoderOutput) {
    guard !state.withLock({ $0.stopped }) else { return }
    guard !hasFallenBack else { return emit(Self.abandoned(output)) }
    if case .failed(_, _, let message) = output { fallBack(message) }

    emit(output)
  }

  private static func abandoned(_ output: ScreenSharingTileEncoderOutput) -> ScreenSharingTileEncoderOutput {
    switch output {
    case .tile(let tile): .failed(tile: tile.tile, refresh: .keyframe, message: "Encoded after the fallback")
    case .dropped(let tile, let refresh), .failed(let tile, let refresh, _):
      .failed(tile: tile, refresh: refresh, message: "Encoded after the fallback")
    case .unchanged(let tile, _): .failed(tile: tile, refresh: nil, message: "Encoded after the fallback")
    }
  }

  private func fallbackOutput(_ output: ScreenSharingTileEncoderOutput) {
    if case .tile(let tile) = output { noteFallback(tile) }
    emit(output)
  }

  private func noteFallback(_ tile: ScreenSharingEncodedTile) {
    if let token = tile.ltrToken { state.withLock { $0.remember(token, tile: tile.tile) } }
    noteRecovery(tile)
  }

  private func fallBack(_ reason: String) {
    let (first, bitrate) = state.withLock { state in
      defer { state.fellBackNs = state.fellBackNs ?? ScreenSharingMetrics.nowNs }
      return (state.fellBackNs == nil, state.bitrate)
    }
    guard first else { return }

    metrics.increment("encoderFallbacks")
    metrics.label("encoderFallbackReason", reason)
    metrics.label("encoder", "VideoToolbox fallback")
    if let bitrate { try? fallback.setBitrate(bitrate) }
    Task { [primary] in primary.stop() }
  }

  private func noteRecovery(_ tile: ScreenSharingEncodedTile) {
    let fellBackNs = state.withLock { state -> Int64? in
      guard !state.recoveredFromFallback, let fellBackNs = state.fellBackNs else { return nil }

      state.recoveredFromFallback = true
      return fellBackNs
    }
    guard let fellBackNs else { return }

    metrics.observe("encoderFallbackToKeyframe", milliseconds: Double(tile.encodedNs - fellBackNs) / 1_000_000)
  }

  private func emit(_ output: ScreenSharingTileEncoderOutput) {
    state.withLock { $0.output }?(output)
  }
}
