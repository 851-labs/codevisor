import CoreVideo
import Dispatch
import ScreenSharing
import Synchronization

public final class ScreenSharingRateSwitchedTileEncoder: ScreenSharingTileEncoder, @unchecked Sendable {
  typealias Choice = ScreenSharingV2EncoderRoute.Choice

  private struct State {
    var route: ScreenSharingV2EncoderRoute
    var owners: ScreenSharingV2TileOwners
    var output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?
    var wakeNs: Int64?
    var stopped = false
  }

  public let layout: ScreenSharingV2TileLayout
  public let sourcePixelFormat: OSType
  private let fast: any ScreenSharingTileEncoder
  private let slow: any ScreenSharingTileEncoder
  private let metrics: ScreenSharingMetrics
  private let scheduler: any ScreenSharingV2Scheduler
  private let queue = DispatchQueue(label: "ScreenSharingRateSwitchedTileEncoder")
  private let state: Mutex<State>

  public convenience init(
    fast: any ScreenSharingTileEncoder, slow: any ScreenSharingTileEncoder, bitrate: Int,
    metrics: ScreenSharingMetrics
  ) throws {
    try self.init(
      fast: fast, slow: slow, bitrate: bitrate, metrics: metrics, scheduler: ScreenSharingV2SystemScheduler())
  }

  init(
    fast: any ScreenSharingTileEncoder, slow: any ScreenSharingTileEncoder, bitrate: Int,
    metrics: ScreenSharingMetrics, scheduler: any ScreenSharingV2Scheduler
  ) throws {
    guard fast.layout == slow.layout else { throw ScreenSharingError.invalid("The encoders have other tile layouts.") }

    layout = fast.layout
    sourcePixelFormat = fast.sourcePixelFormat
    self.fast = fast
    self.slow = slow
    self.metrics = metrics
    self.scheduler = scheduler
    let route = ScreenSharingV2EncoderRoute(bitrate: bitrate, atNs: scheduler.nowNs)
    state = Mutex(State(route: route, owners: ScreenSharingV2TileOwners(tiles: layout.tiles, owner: route.choice)))
    fast.onOutput { [weak self] output in self?.relay(output, from: .fast) }
    slow.onOutput { [weak self] output in self?.relay(output, from: .slow) }
    metrics.label("encoderRoute", route.choice.rawValue)
    scheduleSwitch()
  }

  deinit { stop() }

  public var refinementPolicy: ScreenSharingV2RefinementPolicy {
    encoder(state.withLock { $0.route.choice }).refinementPolicy
  }

  public func onOutput(_ handler: @escaping @Sendable (ScreenSharingTileEncoderOutput) -> Void) {
    state.withLock { $0.output = handler }
  }

  public func encode(_ request: ScreenSharingTileEncodeRequest) throws {
    switchIfDue()
    let (choice, claimed) = state.withLock { state in
      (state.route.choice, state.owners.claim(request.update.tiles, for: state.route.choice))
    }
    do {
      try encoder(choice).encode(Self.forcingKeyframes(on: claimed, of: request))
    } catch {
      state.withLock { $0.owners.release(claimed, from: choice) }
      throw error
    }
  }

  public func acknowledge(_ tokens: [UInt64], tile: Int) {
    let acknowledgements = state.withLock { $0.owners.acknowledgements(of: tokens, tile: tile) }
    for (owner, issued) in acknowledgements where !issued.isEmpty { encoder(owner).acknowledge(issued, tile: tile) }
  }

  public func observeNetwork(_ feedback: ScreenSharingTileNetworkFeedback) {
    state.withLock { $0.route.observe(feedback, atNs: scheduler.nowNs) }
    switchIfDue()
    fast.observeNetwork(feedback)
    slow.observeNetwork(feedback)
  }

  public func setBitrate(_ bitsPerSecond: Int) throws {
    state.withLock { $0.route.observe(bitrate: bitsPerSecond, atNs: scheduler.nowNs) }
    switchIfDue()
    let results = [fast, slow].map { encoder in Result { try encoder.setBitrate(bitsPerSecond) } }
    for result in results { try result.get() }
  }

  public func stop() {
    let wasRunning = state.withLock { state in
      defer { state.stopped = true; state.output = nil }
      return !state.stopped
    }
    guard wasRunning else { return }

    fast.stop()
    slow.stop()
  }

  private func encoder(_ choice: Choice) -> any ScreenSharingTileEncoder {
    switch choice {
    case .fast: fast
    case .slow: slow
    }
  }

  private func switchIfDue() {
    guard updateRoute() == .fast else { return }

    let frameNs = Int64(ScreenSharingV2Profile.frameIntervalUs) * 1_000
    scheduler.run(afterNs: frameNs, on: queue) { [weak self] in self?.requestKeyframes() }
  }

  private func updateRoute() -> Choice? {
    let switched = state.withLock { state -> Choice? in
      guard !state.stopped, state.route.update(atNs: scheduler.nowNs) else { return nil }

      return state.route.choice
    }
    scheduleSwitch()
    guard let switched else { return nil }

    metrics.increment("encoderSwitches")
    metrics.label("encoderRoute", switched.rawValue)
    return switched
  }

  private func requestKeyframes() {
    let (handler, tiles) = state.withLock { state in
      let unclaimed = state.route.choice == .fast ? layout.tiles.filter { !state.owners.owns($0, .fast) } : []
      return (state.output, unclaimed.sorted())
    }
    for tile in tiles { handler?(.keyframeNeeded(tile: tile)) }
  }

  private func scheduleSwitch() {
    let nowNs = scheduler.nowNs
    let dueNs = state.withLock { state -> Int64? in
      guard !state.stopped, let dueNs = state.route.switchDueNs, dueNs > nowNs,
        state.wakeNs.map({ dueNs < $0 }) ?? true
      else { return nil }

      state.wakeNs = dueNs
      return dueNs
    }
    guard let dueNs else { return }

    scheduler.run(afterNs: dueNs - nowNs, on: queue) { [weak self] in self?.wake(dueNs) }
  }

  private func wake(_ dueNs: Int64) {
    let due = state.withLock { state in
      defer { if state.wakeNs == dueNs { state.wakeNs = nil } }
      return state.wakeNs == dueNs
    }
    guard due else { return }

    switchIfDue()
  }

  private func relay(_ output: ScreenSharingTileEncoderOutput, from source: Choice) {
    let (handler, forwarded) = state.withLock { state in
      (state.output, Self.forwarded(output, from: source, owners: &state.owners))
    }
    if case .dropped = forwarded, !Self.isDropped(output) { metrics.increment("encoderSwitchAbandonedTiles") }
    handler?(forwarded)
  }

  private static func forwarded(
    _ output: ScreenSharingTileEncoderOutput, from source: Choice, owners: inout ScreenSharingV2TileOwners
  ) -> ScreenSharingTileEncoderOutput {
    switch output {
    case .tile(let tile):
      guard owners.owns(tile.tile, source) else { return .dropped(tile: tile.tile, refresh: nil) }

      if let token = tile.ltrToken { owners.remember(token, tile: tile.tile, issuedBy: source) }
      return output
    case .unchanged(let tile, _), .failed(let tile, _, _):
      return owners.owns(tile, source) ? output : .dropped(tile: tile, refresh: nil)
    case .dropped, .keyframeNeeded:
      return output
    }
  }

  private static func isDropped(_ output: ScreenSharingTileEncoderOutput) -> Bool {
    if case .dropped = output { return true }
    return false
  }

  private static func forcingKeyframes(
    on tiles: Set<Int>, of request: ScreenSharingTileEncodeRequest
  ) -> ScreenSharingTileEncodeRequest {
    guard !tiles.isEmpty else { return request }

    var refreshes = request.refreshes
    for tile in tiles { refreshes[tile] = .keyframe }
    return ScreenSharingTileEncodeRequest(
      pixelBuffer: request.pixelBuffer, sourceTimestampNs: request.sourceTimestampNs, capturedNs: request.capturedNs,
      update: request.update, refreshes: refreshes)
  }
}
