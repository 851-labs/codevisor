import Darwin
import CoreGraphics
import ScreenSharingBench
import ScreenSharingBenchScenes

struct ShareCommand: BenchCommand {
  static let name = "share"
  static let summary = "Share this Mac's main display through Codevisor engine v2 (the Tier 2 host)"
  static let usage =
    "[--port <port>] [--duration <seconds>] \(VirtualDisplayOption.usage) \(V2EncoderChoice.usage) "
    + BenchSignalFiles.usage

  private static let durations = 1...7200
  private static let ports = 1...65_535

  let presentsWindows = false
  private let port: UInt16
  private let duration: Duration
  private let signals: BenchSignalFiles
  private let virtualDisplay: BenchSceneResolution?
  private let encoder: V2EncoderChoice

  init(options: BenchOptions) throws {
    port = UInt16(try options.integer("port", default: Int(SignalingSocket.defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
    virtualDisplay = try VirtualDisplayOption.read(from: options)
    encoder = try V2EncoderChoice(options: options)
  }

  func run() async throws {
    let deadline = ContinuousClock.now + duration
    let shared = try await SharedDisplay.make(virtualDisplay)
    let connection = try await Self.awaitViewer(port: port, timeout: duration, display: shared.id, signals: signals)
    defer { withExtendedLifetime(shared) {} }

    try await share(on: shared.id, over: connection, until: deadline)
  }

  private func share(
    on displayID: CGDirectDisplayID, over connection: SignalingConnection, until deadline: ContinuousClock.Instant
  )
    async throws
  {
    let control = SignalingControlChannel(connection)
    let host = try await ShareV2Host(displayID: displayID, control: control, encoder: encoder)
    do {
      try connection.send(host.address)
      try await host.accept(until: deadline)
      await BenchSession.hold(connection, until: deadline, signals: signals, control: control)
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
}
