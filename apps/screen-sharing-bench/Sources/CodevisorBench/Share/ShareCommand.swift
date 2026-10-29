import Darwin
import ScreenSharingBench

struct ShareCommand: BenchCommand {
  static let name = "share"
  static let summary = "Share this Mac's main display through the Codevisor engine (the Tier 2 host)"
  static let usage = "[--port <port>] [--duration <seconds>] \(BenchSignalFiles.usage)"

  private static let durations = 1...7200
  private static let ports = 1...65_535

  let presentsWindows = false
  private let port: UInt16
  private let duration: Duration
  private let signals: BenchSignalFiles

  init(options: BenchOptions) throws {
    port = UInt16(try options.integer("port", default: Int(SignalingSocket.defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
  }

  func run() async throws {
    let deadline = ContinuousClock.now + duration
    let connection = try await Self.awaitViewer(port: port, timeout: duration, signals: signals)
    let host = try await ShareHost()
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
    port: UInt16, timeout: Duration, signals: BenchSignalFiles
  ) async throws
    -> SignalingConnection
  {
    let listener = try SignalingSocket.listen(port: port)
    defer { close(listener) }

    try signals.markReady("listening")
    return try SignalingSocket.accept(on: listener, timeout: timeout)
  }

  @concurrent
  private static func receive(_ connection: SignalingConnection) async throws -> SignalingMessage {
    try connection.receive(SignalingMessage.self)
  }
}
