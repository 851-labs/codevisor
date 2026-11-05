import QuartzCore

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@MainActor
final class BotMascotTicker: NSObject {
  private let onTick: @MainActor (CFTimeInterval) -> Void
  private var link: CADisplayLink?

  init(onTick: @escaping @MainActor (CFTimeInterval) -> Void) {
    self.onTick = onTick
  }

  #if os(macOS)
    func start(on view: NSView) {
      stop()
      let link = view.displayLink(target: self, selector: #selector(step(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }
  #else
    func start(on view: UIView) {
      stop()
      let link = CADisplayLink(target: self, selector: #selector(step(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }
  #endif

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func step(_ link: CADisplayLink) {
    onTick(link.timestamp)
  }
}
