import SwiftUI
import UIKit

/// Reports the window-space frame UIKit actually gives a view. Platform
/// views that ignore safe areas can extend past the frame SwiftUI's
/// geometry reports (the transcript runs under the home indicator while
/// its SwiftUI frame stops above it), so layout that must line up with
/// UIKit content measures a probe carrying the same modifiers instead.
struct WindowFrameProbe: UIViewRepresentable {
  let onChange: (CGRect) -> Void

  func makeUIView(context _: Context) -> WindowFrameProbeView {
    WindowFrameProbeView()
  }

  func updateUIView(_ view: WindowFrameProbeView, context _: Context) {
    view.onChange = onChange
  }
}

final class WindowFrameProbeView: UIView {
  var onChange: ((CGRect) -> Void)?
  private var lastReported: CGRect?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    report()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    report()
  }

  private func report() {
    guard let window else { return }
    let frame = convert(bounds, to: window)
    guard frame != lastReported else { return }
    lastReported = frame
    // Layout can run inside a SwiftUI update; publish on the next turn.
    Task { @MainActor [onChange] in
      onChange?(frame)
    }
  }
}
