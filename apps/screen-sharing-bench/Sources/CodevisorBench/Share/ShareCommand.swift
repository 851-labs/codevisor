import Darwin
import CoreGraphics
import ScreenSharingBench
import ScreenSharingBenchScenes

struct ShareCommand: BenchCommand {
  static let name = "share"
  static let summary = "Share this Mac's main display through the Codevisor engine (the Tier 2 host)"
  static let usage =
    "[--port <port>] [--duration <seconds>] [--virtual-display R1|R1x2|R2|R3] [--engine v1|v2] "
    + BenchSignalFiles.usage

  private static let durations = 1...7200
  private static let ports = 1...65_535

  let presentsWindows = false
  private let port: UInt16
  private let duration: Duration
  private let signals: BenchSignalFiles
  private let virtualDisplay: BenchSceneResolution?
  private let engine: BenchEngine

  init(options: BenchOptions) throws {
    port = UInt16(try options.integer("port", default: Int(SignalingSocket.defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
    virtualDisplay = try options.string("virtual-display").map(Self.resolution)
    engine = try options.choice("engine", default: BenchEngine.v1)
  }

  func run() async throws {
    let deadline = ContinuousClock.now + duration
    let shared = try await SharedDisplay.make(virtualDisplay)
    let connection = try await Self.awaitViewer(port: port, timeout: duration, display: shared.id, signals: signals)
    defer { withExtendedLifetime(shared) {} }

    switch engine {
    case .v1: try await share(try await ShareHost(displayID: shared.id), over: connection, until: deadline)
    case .v2: try await share(try await ShareV2Host(displayID: shared.id), over: connection, until: deadline)
    }
  }

  private func share(
    _ host: ShareV2Host, over connection: SignalingConnection, until deadline: ContinuousClock.Instant
  )
    async throws
  {
    do {
      try connection.send(host.address)
      try await host.accept(until: deadline)
      await BenchSession.hold(connection, until: deadline, signals: signals)
      try BenchOutput.print(await host.finish(viewer: connection.peerIPv4))
    } catch {
      _ = await host.finish(viewer: connection.peerIPv4)
      throw error
    }
  }

  private func share(
    _ host: ShareHost, over connection: SignalingConnection, until deadline: ContinuousClock.Instant
  )
    async throws
  {
    do {
      try connection.send(SignalingMessage(sdp: try await host.answer(try await Self.receive(connection).sdp)))
      await BenchSession.hold(connection, until: deadline, signals: signals)
      try BenchOutput.print(await host.finish(viewer: connection.peerIPv4))
    } catch {
      _ = await host.finish(viewer: connection.peerIPv4)
      throw error
    }
  }

  @concurrent
  private static func awaitViewer(
    port: UInt16, timeout: Duration, display: CGDirectDisplayID, signals: BenchSignalFiles
  ) async throws
    -> SignalingConnection
  {
    let listener = try SignalingSocket.listen(port: port)
    defer { close(listener) }

    try signals.markReady("listening display \(display)")
    return try SignalingSocket.accept(on: listener, timeout: timeout)
  }

  private static func resolution(_ text: String) throws -> BenchSceneResolution {
    guard let resolution = BenchSceneResolution(rawValue: text) else {
      throw BenchUsageError(message: "--virtual-display takes R1, R1x2, R2 or R3, not \(text)")
    }

    return resolution
  }

  @concurrent
  private static func receive(_ connection: SignalingConnection) async throws -> SignalingMessage {
    try connection.receive(SignalingMessage.self)
  }
}
