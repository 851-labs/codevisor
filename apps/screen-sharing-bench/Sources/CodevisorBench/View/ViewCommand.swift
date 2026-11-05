import ScreenSharingBench
import ScreenSharingBenchScenes

struct ViewCommand: BenchCommand {
  enum Source: String, CaseIterable {
    case codevisor
    case null
  }

  static let name = "view"
  static let summary =
    "Show the Codevisor stream from the host full screen, or (--source null) the floor: barcodes drawn from UDP"
  static let usage = """
    --source codevisor --host <ipv4> [--port <port>] [--present arrival|display-link] [--tiles on|off] \
      [--control] [--duration <seconds>] \(VirtualDisplayOption.usage) \(BenchSignalFiles.usage)
      view --source null [--port <udp port>] [--duration <seconds>] \(VirtualDisplayOption.usage) \(BenchSignalFiles.usage)
    """

  static let defaultFloorPort: UInt16 = 47_594
  private static let durations = 1...7200
  private static let ports = 1...65_535

  let presentsWindows = true
  private let source: Source
  private let presentation: V2Presentation
  private let presentsTiles: Bool
  private let takesControl: Bool
  private let host: String?
  private let port: UInt16
  private let duration: Duration
  private let signals: BenchSignalFiles
  private let virtualDisplay: BenchSceneResolution?

  init(options: BenchOptions) throws {
    source = try options.choice("source", default: Source.codevisor)
    presentation = try options.choice("present", default: V2Presentation.arrival)
    presentsTiles = try options.choice("tiles", default: V2Tiles.on) == .on
    takesControl = try options.flag("control")
    host = try options.string("host")
    let defaultPort = source == .codevisor ? SignalingSocket.defaultPort : Self.defaultFloorPort
    port = UInt16(try options.integer("port", default: Int(defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 120, in: Self.durations))
    signals = try BenchSignalFiles(options: options)
    virtualDisplay = try VirtualDisplayOption.read(from: options)
    guard (source == .codevisor) == (host != nil) else {
      throw BenchUsageError(message: "--host is required with --source codevisor and only then")
    }
    guard !takesControl || source == .codevisor else {
      throw BenchUsageError(message: "--control needs --source codevisor")
    }
    guard !takesControl || presentation == .arrival else {
      throw BenchUsageError(message: "--control needs --present arrival")
    }
  }

  func run() async throws {
    let deadline = ContinuousClock.now + duration
    let display = try await SharedDisplay.make(virtualDisplay)
    defer { withExtendedLifetime(display) {} }
    let window = ViewerWindow.presented(on: try display.screen())
    defer { window.close() }
    let signals = signals.describing(display.readyDetail)

    switch source {
    case .codevisor:
      try BenchOutput.print(
        try await CodevisorV2Viewer.run(
          in: window, host: host ?? "", port: port, presentation: presentation, presentsTiles: presentsTiles,
          takesControl: takesControl,
          until: deadline, signals: signals))
    case .null:
      try BenchOutput.print(try await FloorViewer.run(in: window, port: port, until: deadline, signals: signals))
    }
  }
}
