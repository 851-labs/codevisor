import CoreVideo
import Foundation
import ScreenSharing
import Synchronization

public final class ScreenSharingFallbackTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  public typealias MakeFallback = @Sendable (ScreenSharingV2TileLayout) throws -> any ScreenSharingTileEncoder

  private struct State {
    var output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
    var fellBackNs: Int64?
    var recoveredFromFallback = false
    var bitrate: Int?
    var fallbackTokens: [Int: [UInt64]] = [:]
    var failedBuild: (atNs: Int64, message: String)?
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
  private let makeFallback: MakeFallback
  private let buildRetryNs: Int64
  private let builds = DispatchQueue(label: "ScreenSharingFallbackTileEncoder.builds")
  private let buildLock = NSLock()
  private let fallback = Mutex<(any ScreenSharingTileEncoder)?>(nil)
  private let metrics: ScreenSharingMetrics
  private let state = Mutex(State())

  public convenience init(
    primary: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics, makeFallback: @escaping MakeFallback
  ) {
    self.init(primary: primary, metrics: metrics, buildRetryNs: 1_000_000_000, makeFallback: makeFallback)
  }

  init(
    primary: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics, buildRetryNs: Int64,
    makeFallback: @escaping MakeFallback
  ) {
    layout = primary.layout
    sourcePixelFormat = primary.sourcePixelFormat
    self.primary = primary
    self.makeFallback = makeFallback
    self.buildRetryNs = buildRetryNs
    self.metrics = metrics
    primary.onOutput { [weak self] output in self?.primaryOutput(output) }
  }

  public var hasFallenBack: Bool { state.withLock { $0.fellBackNs != nil } }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    state.withLock { $0.output = handler }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    guard !hasFallenBack else { return try builtFallback().encode(request) }

    do {
      try primary.encode(request)
    } catch {
      fallBack(error.localizedDescription)
      try builtFallback().encode(request)
    }
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    guard hasFallenBack else { return primary.acknowledge(tokens, tile: tile) }

    let issued = state.withLock { Set($0.fallbackTokens[tile, default: []]) }
    fallback.withLock { $0 }?.acknowledge(tokens.filter(issued.contains), tile: tile)
  }

  public func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {
    guard hasFallenBack else { return primary.observeNetwork(feedback) }

    fallback.withLock { $0 }?.observeNetwork(feedback)
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    state.withLock { $0.bitrate = bitsPerSecond }
    guard hasFallenBack else { return try primary.setBitrate(bitsPerSecond) }

    try fallback.withLock { $0 }?.setBitrate(bitsPerSecond)
  }

  public func stop() {
    state.withLock {
      $0.output = nil
      $0.stopped = true
    }
    primary.stop()
    fallback.withLock { $0 }?.stop()
  }

  public var refinementPolicy: ScreenSharingV2RefinementPolicy {
    guard hasFallenBack else { return primary.refinementPolicy }

    return fallback.withLock { $0 }?.refinementPolicy ?? .standard
  }

  private func primaryOutput(_ output: ScreenSharingTileEncoderOutput) {
    guard !state.withLock({ $0.stopped }) else { return }
    guard !hasFallenBack else { return emit(Self.abandoned(output)) }
    if case .failed(_, _, let message) = output {
      fallBack(message)
      builds.async { [weak self] in _ = try? self?.builtFallback() }
    }

    emit(output)
  }

  private static func abandoned(_ output: ScreenSharingTileEncoderOutput) -> ScreenSharingTileEncoderOutput {
    switch output {
    case .tile(let tile): .failed(tile: tile.tile, refresh: .keyframe, message: "Encoded after the fallback")
    case .dropped(let tile, let refresh), .failed(let tile, let refresh, _):
      .failed(tile: tile, refresh: refresh, message: "Encoded after the fallback")
    case .unchanged(let tile, _): .failed(tile: tile, refresh: nil, message: "Encoded after the fallback")
    case .keyframeNeeded: output
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
    let first = state.withLock { state in
      defer { state.fellBackNs = state.fellBackNs ?? ScreenSharingMetrics.nowNs }
      return state.fellBackNs == nil
    }
    guard first else { return }

    metrics.increment("encoderFallbacks")
    metrics.label("encoderFallbackReason", reason)
    Task { [primary] in primary.stop() }
  }

  private func builtFallback() throws -> any ScreenSharingTileEncoder {
    if let built = fallback.withLock({ $0 }) { return built }

    buildLock.lock()
    defer { buildLock.unlock() }
    if let built = fallback.withLock({ $0 }) { return built }

    try checkBuildAllowed()
    do {
      let encoder = try buildFallback()
      fallback.withLock { $0 = encoder }
      if state.withLock({ $0.stopped }) { encoder.stop() }
      return encoder
    } catch {
      state.withLock { $0.failedBuild = (ScreenSharingMetrics.nowNs, error.localizedDescription) }
      metrics.label("encoderFallbackBuildError", error.localizedDescription)
      throw error
    }
  }

  private func checkBuildAllowed() throws {
    let (stopped, failedBuild) = state.withLock { ($0.stopped, $0.failedBuild) }
    if stopped { throw ScreenSharingError.unavailable("Encoder stopped.") }
    if let failedBuild, ScreenSharingMetrics.nowNs - failedBuild.atNs < buildRetryNs {
      throw ScreenSharingError.unavailable("No VideoToolbox fallback yet: \(failedBuild.message)")
    }
  }

  private func buildFallback() throws -> any ScreenSharingTileEncoder {
    let startedNs = ScreenSharingMetrics.nowNs
    let encoder = try makeFallback(layout)
    guard encoder.layout == layout else {
      encoder.stop()
      throw ScreenSharingError.invalid("The fallback encoder has another tile layout.")
    }

    encoder.onOutput { [weak self] output in self?.fallbackOutput(output) }
    if let bitrate = state.withLock({ $0.bitrate }) { try? encoder.setBitrate(bitrate) }
    metrics.observe("encoderFallbackBuild", milliseconds: Double(ScreenSharingMetrics.nowNs - startedNs) / 1_000_000)
    metrics.label("encoder", "VideoToolbox fallback")
    return encoder
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
