import CodevisorUI
import SwiftUI
import UIKit

@MainActor
enum ComposerSendStaging {
  static func stage(session: ObjectIdentifier, sourceFrame: CGRect, theme: Theme) {
    guard !sourceFrame.isEmpty, let window = UIWindow.codevisorKeyWindow,
      let editor = editor(in: window, overlapping: sourceFrame)
    else { return }
    TranscriptSendStaging.shared.stage(
      session: session,
      textView: editor,
      textRect: editor.laidOutTextRect,
      lineHeight: editor.caretRect(for: editor.beginningOfDocument).height,
      bubble: theme.bubbleBackground,
      theme: theme
    )
  }

  private static func editor(in window: UIWindow, overlapping frame: CGRect) -> UITextView? {
    var best: (view: UITextView, area: CGFloat)?
    func visit(_ view: UIView) {
      if let editor = view as? HeightReportingTextView, !editor.isHidden, editor.alpha > 0.01 {
        let overlap = editor.convert(editor.bounds, to: nil).intersection(frame)
        let area = overlap.isNull ? 0 : overlap.width * overlap.height
        if area > (best?.area ?? 0) { best = (editor, area) }
        return
      }
      for subview in view.subviews { visit(subview) }
    }
    visit(window)
    return best?.view
  }
}

extension UITextView {
  fileprivate var laidOutTextRect: CGRect {
    let start = caretRect(for: beginningOfDocument)
    let end = caretRect(for: endOfDocument)
    let trailing = bounds.width - textContainerInset.right - textContainer.lineFragmentPadding
    let isSingleLine = abs(end.minY - start.minY) < start.height / 2
    return CGRect(
      x: start.minX,
      y: start.minY,
      width: max(0, (isSingleLine ? end.minX : trailing) - start.minX),
      height: max(start.height, end.maxY - start.minY)
    )
  }
}
