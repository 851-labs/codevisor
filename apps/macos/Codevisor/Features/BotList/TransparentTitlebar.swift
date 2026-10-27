import AppKit
import SwiftUI

struct TransparentTitlebar: NSViewRepresentable {
  let isTransparent: Bool

  final class Probe: NSView {
    var isTransparent = false {
      didSet { apply() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    private func apply() {
      guard let window, window.titlebarAppearsTransparent != isTransparent else { return }
      window.titlebarAppearsTransparent = isTransparent
    }
  }

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.isTransparent = isTransparent
    return probe
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.isTransparent = isTransparent
  }
}
