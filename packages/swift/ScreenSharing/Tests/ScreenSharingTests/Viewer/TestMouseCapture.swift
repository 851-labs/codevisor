import AppKit

@testable import ScreenSharing

@MainActor
final class TestMouseCapture: ScreenSharingMouseCapture {
  let starts: Bool
  private(set) var window: Int?
  private(set) var stops = 0
  private var handle: (@MainActor (CGEventType, CGEvent) -> Void)?

  init(starts: Bool) { self.starts = starts }

  func start(handle: @escaping @MainActor (CGEventType, CGEvent) -> Void) -> Bool {
    guard starts else { return false }
    self.handle = handle
    return true
  }

  func setWindow(_ windowNumber: Int?) { window = windowNumber }

  func stop() { stops += 1; handle = nil }

  func send(_ event: CGEvent) { handle?(event.type, event) }
}
