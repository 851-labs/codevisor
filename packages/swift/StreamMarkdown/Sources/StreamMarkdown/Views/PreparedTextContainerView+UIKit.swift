#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class PreparedTextContainerView: UIView {
    private var textView: SelectableTextKitView?

    func configure(layout: PreparedNativeTextLayout, delegate: UITextViewDelegate) {
      guard textView?.layoutManager !== layout.manager else { return }
      let selection = textView?.selectedRange
      let wasFirstResponder = textView?.isFirstResponder == true
      textView?.removeFromSuperview()
      let view = SelectableTextKitView(preparedLayout: layout)
      view.delegate = delegate
      view.frame = CGRect(origin: .zero, size: layout.size)
      addSubview(view)
      textView = view
      if let selection, NSMaxRange(selection) <= layout.text.length { view.selectedRange = selection }
      if wasFirstResponder { view.becomeFirstResponder() }
    }
  }
#endif
