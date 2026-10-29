import CoreGraphics
import ScreenSharingBench

struct ObserverAgreementCheck: CalibrationCheck {
  private static let durations = 1...3600

  let presentsWindows = false
  private let duration: Int
  private let displayID: CGDirectDisplayID?
  private let layout: BenchBarcodeLayout

  init(options: BenchOptions) throws {
    duration = try options.integer("duration", default: 30, in: Self.durations)
    displayID = try DisplayOption.id(from: options)
    layout = try BarcodeOptions.layout(from: options)
  }

  func run() async throws {
    let display = try await ScreenObserver.display(id: displayID)
    let observers = try await ObserverPair.start(display: display, layout: layout)
    try await Task.sleep(for: .seconds(duration))

    let logs = try await observers.stop()
    let result = ObserverAgreementResult(sources: observers.sources, logs: logs)
    try BenchOutput.print(result)
    guard result.passed else { throw CalibrationFailed(check: result.check) }
  }
}
