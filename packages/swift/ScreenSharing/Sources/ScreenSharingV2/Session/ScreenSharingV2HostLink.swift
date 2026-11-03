import CoreVideo
import Foundation
import ScreenSharing
import Synchronization

@MainActor
public final class ScreenSharingV2HostLink {
  public typealias MakeEncoder =
    @Sendable (ScreenSharingVideoConfiguration, ScreenSharingMetrics) async throws -> any ScreenSharingTileEncoder

  public let metrics: ScreenSharingMetrics
  public let linkChannels: ScreenSharingV2Channels
  public let frameRouter = ScreenSharingV2FrameRouter()
  public nonisolated let sendDatagram: ScreenSharingV2Channels.SendDatagram
  public var onConnectionChanged: ((String) -> Void)?
  public private(set) var sourcePixelFormat: OSType = ScreenSharingV2Profile.capturePixelFormat
  private let makeEncoder: MakeEncoder
  private let feedBox: ScreenSharingV2FeedSlot
  private var connection: (any ScreenSharingV2Connection)?
  private var configuration: ScreenSharingVideoConfiguration
  private var engine: ScreenSharingV2Host?
  private var rebuilding: Task<Void, any Error>?
  private var watcher: Task<Void, Never>?
  private var closed = false

  public init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    makeEncoder: @escaping MakeEncoder = { configuration, metrics in
      try await ScreenSharingV2Encoders.make(.configured(), configuration: configuration, metrics: metrics)
    }
  ) {
    self.configuration = configuration
    self.metrics = metrics
    self.makeEncoder = makeEncoder
    let feedBox = ScreenSharingV2FeedSlot()
    self.feedBox = feedBox
    let sendDatagram: ScreenSharingV2Channels.SendDatagram = { kind, payload in
      feedBox.sendDatagram(kind, payload)
    }
    self.sendDatagram = sendDatagram
    linkChannels = ScreenSharingV2Channels(sendDatagram: sendDatagram)
  }

  public func accept(
    _ connection: any ScreenSharingV2Connection, validate: @MainActor (String) -> String?
  ) async throws {
    try await linkChannels.accept(on: connection, validate: validate)
    guard !closed else { throw CancellationError() }

    self.connection = connection
    let channels = linkChannels
    let feed = ScreenSharingV2MediaFeed(transport: await connection.openMedia()) { kind, payload in
      Task { @MainActor in channels.receiveDatagram(kind, payload) }
    }
    feedBox.set(feed)
    guard !closed else { throw CancellationError() }

    try await rebuild()
    metrics.label("engine", "v2")
    onConnectionChanged?("connected")
    watcher = Task { [weak self, connection] in
      let reason = await connection.closed()
      guard let self, !self.closed else { return }

      self.metrics.label("connectionClosed", reason)
      self.onConnectionChanged?("failed")
    }
  }

  public func updateVideoConfiguration(_ configuration: ScreenSharingVideoConfiguration) {
    guard configuration != self.configuration else { return }

    self.configuration = configuration
    metrics.label("captureSize", "\(configuration.width) × \(configuration.height)")
    guard engine != nil else { return }

    Task { try? await rebuild() }
  }

  public func statistics() async -> [String: String] {
    guard let connection, !closed else { return [:] }

    var statistics = connection.mediaStatistics()
    if let route = connection.route { statistics["v2.route"] = route.isRelay ? "relay" : "direct" }
    return statistics
  }

  public func close() {
    guard !closed else { return }

    closed = true
    watcher?.cancel()
    rebuilding?.cancel()
    linkChannels.close()
    frameRouter.route(to: nil)
    engine?.stop()
    engine = nil
    feedBox.close()
    connection?.close("host closed")
  }

  private func rebuild() async throws {
    let previous = rebuilding
    let task = Task { [weak self] in
      try? await previous?.value
      guard let self else { return }

      try await self.replaceEngine()
    }
    rebuilding = task
    try await task.value
  }

  private func replaceEngine() async throws {
    guard !closed, let feed = feedBox.current else { throw CancellationError() }

    let configuration = configuration
    frameRouter.route(to: nil)
    engine?.stop()
    engine = nil
    let encoder = try await makeEncoder(configuration, metrics)
    guard !closed, configuration == self.configuration else {
      encoder.stop()
      return
    }

    let engine = ScreenSharingV2Host(transport: feed.attach(), encoder: encoder, metrics: metrics)
    self.engine = engine
    sourcePixelFormat = encoder.sourcePixelFormat
    engine.start()
    frameRouter.route(to: engine, size: (configuration.width, configuration.height))
  }
}

public final class ScreenSharingV2FrameRouter: ScreenSharingFrameSink {
  private struct Target {
    let host: ScreenSharingV2Host
    let width: Int
    let height: Int
  }

  private let target = Mutex<Target?>(nil)

  func route(to host: ScreenSharingV2Host?, size: (width: Int, height: Int) = (0, 0)) {
    target.withLock { $0 = host.map { Target(host: $0, width: size.width, height: size.height) } }
  }

  public func push(_ frame: ScreenSharingVideoFrame) {
    guard let target = target.withLock({ $0 }), CVPixelBufferGetWidth(frame.pixelBuffer) == target.width,
      CVPixelBufferGetHeight(frame.pixelBuffer) == target.height
    else { return }

    target.host.push(frame)
  }
}
