import AppKit
import CoreGraphics
import ScreenSharingBench

struct OnGlassCheck: CalibrationCheck {
  private static let durations = 1...600
  private static let settle = Duration.milliseconds(250)

  let presentsWindows = true
  private let duration: Int
  private let displayID: CGDirectDisplayID?

  init(options: BenchOptions) throws {
    duration = try options.integer("duration", default: 30, in: Self.durations)
    displayID = try DisplayOption.id(from: options)
  }

  func run() async throws {
    let display = try await ScreenObserver.display(id: displayID)
    let window = try BarcodeWindow.presented(on: display.displayID)
    defer { window.close() }

    let presenter = try BarcodePresenter(window: window, layout: .standard)
    let driver = RefreshDriver(presenter: presenter)
    let observers = try await ObserverPair.start(display: display, layout: .standard)
    driver.start(on: window.view)
    try await Task.sleep(for: .seconds(duration))
    driver.stop()
    try await Task.sleep(for: Self.settle)
    presenter.drainRecords()

    let logs = try await observers.stop()
    if let failure = driver.failure { throw failure }
    try BenchOutput.print(
      OnGlassResult(
        fed: presenter.versionsBySourceTimestamp, records: presenter.records, logs: logs, sources: observers.sources))
  }
}
