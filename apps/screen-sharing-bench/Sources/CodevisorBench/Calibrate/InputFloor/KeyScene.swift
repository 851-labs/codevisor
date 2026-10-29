import AppKit
import CoreGraphics
import ScreenSharingBench

@MainActor
final class KeyScene {
  private static let focusTimeout = Duration.seconds(5)
  private static let focusCheckInterval = Duration.milliseconds(50)

  private let window: BarcodeWindow
  private let presenter: BarcodePresenter
  private(set) var failure: (any Error)?

  static func presented(on displayID: CGDirectDisplayID, layout: BenchBarcodeLayout) throws -> KeyScene {
    let window = try BarcodeWindow.presented(on: displayID)
    let scene = KeyScene(window: window, presenter: try BarcodePresenter(window: window, layout: layout))
    try scene.presenter.presentNextVersion()
    return scene
  }

  private init(window: BarcodeWindow, presenter: BarcodePresenter) {
    self.window = window
    self.presenter = presenter
    window.onKeyDown = { [weak self] in self?.advance() }
  }

  func waitForFocus() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + Self.focusTimeout
    while !hasFocus {
      guard clock.now < deadline else { throw KeySceneError.neverFocused }

      window.makeKeyAndOrderFront(nil)
      try await clock.sleep(for: Self.focusCheckInterval)
    }
  }

  func close() {
    window.close()
  }

  var hasFocus: Bool {
    NSApplication.shared.isActive && window.isKeyWindow
  }

  private func advance() {
    do {
      try presenter.presentNextVersion()
    } catch {
      failure = failure ?? error
    }
  }
}

enum KeySceneError: Error {
  case neverFocused
  case lostFocus
}
