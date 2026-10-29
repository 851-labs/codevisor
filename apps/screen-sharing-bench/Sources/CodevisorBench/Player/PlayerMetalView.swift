import AppKit

final class PlayerMetalView: NSView {
  init(metalLayer: CAMetalLayer) {
    super.init(frame: .zero)
    layer = metalLayer
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }
}
