import AppKit
import CoreGraphics
import ScreenSharingBench

struct InputFloorCheck: CalibrationCheck {
  private static let eventCounts = 1...2000
  private static let shortestSpacingMs = 150.0
  private static let spacingRangeMs = 200.0
  private static let settle = Duration.milliseconds(500)

  private let events: Int
  private let seed: UInt64
  private let target: InputFloorTarget
  private let displayID: CGDirectDisplayID?
  private let layout: BenchBarcodeLayout

  init(options: BenchOptions) throws {
    events = try options.integer("events", default: 200, in: Self.eventCounts)
    seed = UInt64(try options.integer("seed", default: 7, in: 0...Int.max))
    target = try options.choice("target", default: .window)
    displayID = try DisplayOption.id(from: options)
    layout = try BarcodeOptions.layout(from: options)
  }

  var presentsWindows: Bool {
    target == .window
  }

  func run() async throws {
    try KeyPoster.requireAccess()
    let display = try await ScreenObserver.display(id: displayID)
    let scene = try target == .window ? KeyScene.presented(on: display.displayID, layout: layout) : nil
    defer { scene?.close() }

    try await scene?.waitForFocus()
    let observer = try await ScreenObserver.start(display: display, region: .barcode, layout: layout)
    let posted = try await postEvents(keepingFocusOn: scene)
    try await Task.sleep(for: Self.settle)

    let observations = try await observer.stop()
    if let failure = scene?.failure { throw failure }
    try BenchOutput.print(
      InputFloorResult(target: target, source: observer.source, posted: posted, observations: observations))
    if posted.lostFocus { throw KeySceneError.lostFocus }
  }

  private func postEvents(keepingFocusOn scene: KeyScene?) async throws -> PostedEvents {
    var random = SplitMix64(seed: seed)
    var eventsNs: [Int64] = []
    for _ in 0..<events {
      try await Task.sleep(for: .milliseconds(Self.shortestSpacingMs + random.nextUnitInterval() * Self.spacingRangeMs))
      guard scene?.hasFocus ?? true else { return PostedEvents(timesNs: eventsNs, lostFocus: true) }

      eventsNs.append(try KeyPoster.pressSpace())
    }
    return PostedEvents(timesNs: eventsNs, lostFocus: false)
  }
}
