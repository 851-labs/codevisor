import UIKit

final class ComposerTextViewContainer: UIView {
  var activation: (() -> Void)?
  var localEditor: HeightReportingTextView?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    activateIfPossible()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    ComposerTextViewHandoffRegistry.layoutEditor(ownedBy: self)
    subviews.forEach { $0.frame = bounds }
  }

  func activateIfPossible() {
    activation?()
  }
}
