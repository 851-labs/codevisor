import UIKit

@MainActor
final class TranscriptQuoteHighlightView: UIView {
  static let holdDuration: Duration = .milliseconds(1600)
  static let fadeDuration: TimeInterval = 0.9

  private let shape = CAShapeLayer()
  private var fadeTask: Task<Void, Never>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isHidden = true
    layer.addSublayer(shape)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(_ canvasRects: [CGRect]) {
    fadeTask?.cancel()
    layer.removeAllAnimations()
    alpha = 1
    isHidden = false
    place(canvasRects)
    fadeTask = Task { [weak self] in
      try? await Task.sleep(for: Self.holdDuration)
      guard !Task.isCancelled else { return }
      self?.fadeOut()
    }
  }

  func place(_ canvasRects: [CGRect]) {
    guard let first = canvasRects.first else { return clear() }
    frame = canvasRects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -Self.outset, dy: -Self.outset)
    let path = UIBezierPath()
    for rect in canvasRects {
      let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -1, dy: 0)
      path.append(UIBezierPath(roundedRect: local, cornerRadius: 3))
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.frame = bounds
    shape.path = path.cgPath
    shape.fillColor = tintColor.withAlphaComponent(Self.fillAlpha).cgColor
    CATransaction.commit()
  }

  func clear() {
    fadeTask?.cancel()
    fadeTask = nil
    isHidden = true
  }

  private func fadeOut() {
    UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.alpha = 0
    } completion: { [weak self] finished in
      guard finished, let self, self.alpha == 0 else { return }
      self.clear()
    }
  }

  private static let outset: CGFloat = 2
  private static let fillAlpha: CGFloat = 0.3
}
