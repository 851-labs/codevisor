import CoreGraphics
import Foundation
import ScreenSharing
import ScreenSharingV2

struct HostRunCommand: BenchCommand {
  static let name = "host-run"
  static let summary = "Run the engine v2 host pipeline on a display into a null transport (one host-lab variant)"
  static let usage =
    "--display-id <id> --output <file.json> [--seconds <n>] [--variant <name>] [--queue n] [--cursor 0|1] "
    + "[--fps n] [--refine n] [--converge bytes] [--tiles 1|4] [--ltr 0|1]"

  private static let durations = 1...600

  let presentsWindows = false
  private let displayID: CGDirectDisplayID
  private let seconds: Int
  private let output: String
  private let variant: HostLabVariant

  init(options: BenchOptions) throws {
    displayID = CGDirectDisplayID(try options.integer("display-id", default: 0, in: 1...Int(UInt32.max)))
    seconds = try options.integer("seconds", default: 30, in: Self.durations)
    output = try options.requiredString("output")
    variant = try HostLabVariant(options: options)
  }

  func run() async throws {
    let metrics = ScreenSharingMetrics()
    let configuration = try Self.configuration(for: displayID, framesPerSecond: variant.framesPerSecond)
    let layout = variant.tiles.map {
      ScreenSharingV2TileLayout(width: configuration.width, height: configuration.height, count: $0)
    }
    let encoder = try ScreenSharingVideoToolboxTileEncoder(
      configuration: configuration, layout: layout ?? ScreenSharingV2Profile.tileLayout(for: configuration),
      metrics: metrics, longTermReferences: variant.longTermReferences)
    let transport = HostLabNullTransport()
    let host = ScreenSharingV2Host(
      transport: transport, encoder: encoder, metrics: metrics,
      refinement: variant.refinement)
    let capture = ScreenSharingCapture(pixelFormat: encoder.sourcePixelFormat)
    capture.queueDepth = variant.queueDepth
    try await capture.setShowsCursor(variant.showsCursor)
    host.start()
    var captureError: String?
    do {
      try await capture.start(displayID: displayID, configuration: configuration, sink: host, metrics: metrics)
      try await Task.sleep(for: .seconds(seconds))
    } catch {
      captureError = "\(error)"
    }
    try? await capture.stop()
    host.stop()
    let result = HostRunResult(
      variant: variant.name, captureError: captureError, metrics: metrics.snapshot(), passes: transport.passes)
    try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: output))
  }

  private static func configuration(
    for displayID: CGDirectDisplayID, framesPerSecond: Int
  ) throws -> ScreenSharingVideoConfiguration {
    let mode = CGDisplayCopyDisplayMode(displayID)
    let profile = try ScreenSharingV2Profile.captureConfiguration(
      width: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID),
      height: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
    return try ScreenSharingVideoConfiguration(
      width: profile.width, height: profile.height, framesPerSecond: framesPerSecond, bitrate: profile.bitrate)
  }
}

struct HostRunResult: Codable {
  let variant: String
  let captureError: String?
  let counters: [String: Int]
  let timings: [String: ScreenSharingMetrics.Timing]
  let passes: [HostLabTileSizes.Pass]

  init(
    variant: String, captureError: String?, metrics: ScreenSharingMetrics.Snapshot, passes: [HostLabTileSizes.Pass]
  ) {
    self.variant = variant
    self.captureError = captureError
    counters = metrics.counters
    timings = metrics.timings
    self.passes = passes
  }
}
