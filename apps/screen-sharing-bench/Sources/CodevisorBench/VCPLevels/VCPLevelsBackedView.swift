import AppKit

final class VCPLevelsBackedView: NSView {
  private let backing: CALayer

  init(backing: CALayer) {
    self.backing = backing
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { backing }
}
