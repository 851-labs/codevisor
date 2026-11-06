import AppKit

final class TopBandPointerWatcher {
  private static let pollInterval: TimeInterval = 0.1

  var bandHeight: CGFloat
  private let onChange: @MainActor (Bool) -> Void
  private weak var window: NSWindow?
  private var timer: Timer?
  private var isInside = false

  init(bandHeight: CGFloat, onChange: @escaping @MainActor (Bool) -> Void) {
    self.bandHeight = bandHeight
    self.onChange = onChange
  }

  isolated deinit {
    timer?.invalidate()
  }

  nonisolated static func isPointerInBand(_ pointer: CGPoint, windowFrame: CGRect, bandHeight: CGFloat) -> Bool {
    windowFrame.contains(pointer) && pointer.y >= windowFrame.maxY - bandHeight
  }

  func isWatching(_ window: NSWindow?) -> Bool {
    timer != nil && self.window === window
  }

  func watch(_ window: NSWindow?) {
    stop()
    guard let window else { return }

    self.window = window
    timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    window = nil
    report(false)
  }

  private func poll() {
    guard let window else { return report(false) }

    report(Self.isPointerInBand(NSEvent.mouseLocation, windowFrame: window.frame, bandHeight: bandHeight))
  }

  private func report(_ inside: Bool) {
    guard inside != isInside else { return }

    isInside = inside
    onChange(inside)
  }
}
