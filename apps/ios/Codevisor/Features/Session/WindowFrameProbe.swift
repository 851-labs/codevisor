import SwiftUI
import UIKit

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
    Task { @MainActor [onChange] in
      onChange?(frame)
    }
  }
}
