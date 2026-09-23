import SwiftUI
import UIKit

/// Reports the UIKit window hosting this view, so window-level decisions
/// (is this the window the user is working in?) can be made per window.
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

/// A weak window box so views can hold their host window in state without
/// retaining it.
final class WeakWindow {
  weak var window: UIWindow?
}
