import CoreGraphics
import Foundation
import ScreenSharingBench

struct ObserveCommand: BenchCommand {
  static let name = "observe"
  static let summary = "Record when each barcode version reaches this Mac's compositor (ScreenCaptureKit)"
  static let usage =
    "[--duration <seconds>] [--region barcode|full] [--display <id>] [--output <file.jsonl>] [--relay <ipv4>:<port>] "
    + BarcodeOptions.usage

  private static let durations = 1...3600

  let presentsWindows = false
  private let duration: Int
  private let region: ObserverRegion
  private let displayID: CGDirectDisplayID?
  private let layout: BenchBarcodeLayout
  private let output: String?
  private let relay: BenchUDPAddress?

  init(options: BenchOptions) throws {
    duration = try options.integer("duration", default: 10, in: Self.durations)
    region = try options.choice("region", default: .barcode)
    displayID = try DisplayOption.id(from: options)
    layout = try BarcodeOptions.layout(from: options)
    output = try options.string("output")
    relay = try VersionRelay.target(from: options)
  }

  func run() async throws {
    let display = try await ScreenObserver.display(id: displayID)
    let meter = ProcessUsageMeter()
    let observer = try await ScreenObserver.start(
      display: display, region: region, layout: layout, relay: try relay.map(VersionRelay.init(target:)))
    try await Task.sleep(for: .seconds(duration))

    let observations = try await observer.stop()
    let log = BenchObserverLog(header: header(observer, meter: meter), observations: observations)
    if let output { try log.jsonLines().write(to: URL(fileURLWithPath: output)) }
    try BenchOutput.print(ObserveSummary(log, output: output))
  }

  private func header(_ observer: ScreenObserver, meter: ProcessUsageMeter) -> BenchObserverHeader {
    let load = meter.loadSinceStart()
    return BenchObserverHeader(
      machine: BenchHostName.current, source: observer.source,
      continuousMinusAbsoluteNs: observer.continuousMinusAbsoluteNs, observerCpuPct: load?.cpuPercent,
      observerPowerMw: load?.powerMw)
  }
}
