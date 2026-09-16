import UIKit

/// The editor's text lifts in glass, then either becomes a queue summary or
/// compresses into the existing queue's count. It never resembles a sent row.
final class IOSQueueSendProxy: UIView {
  private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let message = UILabel()
  private let summary = UILabel()
  private let icon = UIImageView(image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"))
  private var hasLanded = false
  private var formsQueue = false
  private var sourceTextSize: CGSize = .zero

  init(text: String) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    glass.cornerConfiguration = .capsule(maximumRadius: 28)
    addSubview(glass)
    message.text = text
    message.font = .preferredFont(forTextStyle: .body)
    message.textColor = .label
    message.numberOfLines = 0
    message.lineBreakMode = .byClipping
    glass.contentView.addSubview(message)
    summary.text = text
    summary.font = .preferredFont(forTextStyle: .caption1)
    summary.textColor = .secondaryLabel
    summary.lineBreakMode = .byTruncatingTail
    summary.alpha = 0
    glass.contentView.addSubview(summary)
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold
    )
    icon.tintColor = .secondaryLabel
    icon.contentMode = .scaleAspectFit
    icon.alpha = 0
    glass.contentView.addSubview(icon)
    clipsToBounds = true
    layer.cornerRadius = 28
    layer.cornerCurve = .continuous
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func land(formingQueue: Bool) {
    hasLanded = true
    formsQueue = formingQueue
    glass.cornerConfiguration = .capsule(maximumRadius: formingQueue ? 28 : 18)
    layer.cornerRadius = formingQueue ? 28 : 18
    setNeedsLayout()
  }

  func transitionContent(formingQueue: Bool) {
    // Different font sizes and baselines must not crossfade on top of one
    // another. The editor glyphs leave before the compact summary appears.
    UIView.animate(withDuration: 0.12, delay: 0, options: .curveEaseOut) {
      self.message.alpha = 0
    }
    UIView.animate(withDuration: 0.22, delay: 0.18, options: .curveEaseOut) {
      self.summary.alpha = formingQueue ? 1 : 0
      self.icon.alpha = 1
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    if !hasLanded {
      sourceTextSize = CGSize(width: max(1, bounds.width - 26), height: max(1, bounds.height - 18))
      // Match the editor's 4pt top inset without centering short drafts in
      // the taller multiline composer.
      let textHeight = min(sourceTextSize.height, message.sizeThatFits(sourceTextSize).height)
      message.frame = CGRect(x: 13, y: 13, width: sourceTextSize.width, height: textHeight)
    } else {
      // Scale existing glyphs instead of rewrapping a long message into a
      // tiny box on the way into the queue.
      let scale: CGFloat = formsQueue ? 0.76 : 0.15
      message.transform = CGAffineTransform(scaleX: scale, y: scale)
      message.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    icon.frame = CGRect(x: formsQueue ? 13 : bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
    summary.frame = CGRect(x: 36, y: 0, width: max(0, bounds.width - 49), height: bounds.height)
  }
}
