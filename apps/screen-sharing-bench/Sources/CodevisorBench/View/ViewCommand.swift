import ScreenSharingBench

struct ViewCommand: BenchCommand {
  enum Source: String, CaseIterable {
    case codevisor
    case null
  }

  static let name = "view"
  static let summary =
    "Show the Codevisor stream from the host full screen, or (--source null) the floor: barcodes drawn from UDP"
  static let usage = """
    --source codevisor --host <ipv4> [--port <port>] [--engine v1|v2] [--present arrival|display-link] \
      [--duration <seconds>] \(BenchSignalFiles.usage)
      view --source null [--port <udp port>] [--duration <seconds>] \(BenchSignalFiles.usage)
    """

  static let defaultFloorPort: UInt16 = 47_594
  private static let durations = 1...7200
  private static let ports = 1...65_535

  let presentsWindows = true
  private let source: Source
  private let engine: BenchEngine
  private let presentation: V2Presentation
  private let host: String?
  private let port: UInt16
  private let duration: Duration
  private let signals: BenchSignalFiles

  init(options: BenchOptions) throws {
    source = try options.choice("source", default: Source.codevisor)
    engine = try options.choice("engine", default: BenchEngine.v1)
    presentation = try options.choice("present", default: V2Presentation.arrival)
    host = try options.string("host")
    let defaultPort = source == .codevisor ? SignalingSocket.defaultPort : Self.defaultFloorPort
    port = UInt16(try options.integer("port", default: Int(defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
    guard (source == .codevisor) == (host != nil) else {
      throw BenchUsageError(message: "--host is required with --source codevisor and only then")
    }
  }

  func run() async throws {
    let deadline = ContinuousClock.now + duration
    let window = try ViewerWindow.presented()
    defer { window.close() }

    switch source {
    case .codevisor where engine == .v2:
      try BenchOutput.print(
        try await CodevisorV2Viewer.run(
          in: window, host: host ?? "", port: port, presentation: presentation, until: deadline, signals: signals))
    case .codevisor:
      try BenchOutput.print(
        try await CodevisorViewer.run(in: window, host: host ?? "", port: port, until: deadline, signals: signals))
    case .null:
      try BenchOutput.print(try await FloorViewer.run(in: window, port: port, until: deadline, signals: signals))
    }
  }
}
