import AppKit
import QuartzCore

@MainActor
final class RefreshDriver: NSObject {
  private let presenter: BarcodePresenter
  private var link: CADisplayLink?
  private(set) var failure: (any Error)?

  init(presenter: BarcodePresenter) {
    self.presenter = presenter
  }

  func start(on view: NSView) {
    let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func refresh(_ link: CADisplayLink) {
    do {
      try presenter.presentNextVersion()
    } catch {
      failure = failure ?? error
    }
  }
}
