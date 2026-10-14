import SwiftUI
import UIKit

struct HostWindowReader: UIViewRepresentable {
  let onWindowChange: (UIWindow?) -> Void

  func makeUIView(context _: Context) -> ReaderView {
    let view = ReaderView()
    view.onWindowChange = onWindowChange
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: ReaderView, context _: Context) {
    view.onWindowChange = onWindowChange
  }

  final class ReaderView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      onWindowChange?(window)
    }
  }
}

final class WeakWindow {
  weak var window: UIWindow?
}
