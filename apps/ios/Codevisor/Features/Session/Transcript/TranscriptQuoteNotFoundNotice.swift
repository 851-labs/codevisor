import UIKit

@MainActor
final class TranscriptQuoteNotFoundNotice: UIVisualEffectView {
  private static let visibleDuration: Duration = .seconds(2)
  private static let insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
  private let label = UILabel()
  private var dismissTask: Task<Void, Never>?

  init() {
    super.init(effect: UIGlassEffect(style: .regular))
    isUserInteractionEnabled = false
    isHidden = true
    label.text = "Original message not found"
    label.font = .preferredFont(forTextStyle: .callout)
    label.adjustsFontForContentSizeCategory = true
    contentView.addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(centeredAtTopOf region: CGRect) {
    let size = label.intrinsicContentSize
    let width = size.width + Self.insets.left + Self.insets.right
    let height = size.height + Self.insets.top + Self.insets.bottom
    frame = CGRect(x: region.midX - width / 2, y: region.minY + 12, width: width, height: height)
    label.frame = bounds.inset(by: Self.insets)
    layer.cornerRadius = height / 2
    clipsToBounds = true
    isHidden = false
    dismissTask?.cancel()
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: Self.visibleDuration)
      guard !Task.isCancelled else { return }
      self?.isHidden = true
    }
  }
}
