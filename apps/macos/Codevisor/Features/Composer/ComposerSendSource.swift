import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class ComposerSendSource {
  weak var textView: NSTextView?

  func stage(controller: SessionController, theme: Theme) {
    SentAttachmentThumbnails.prepare(controller.composerAttachments)
    guard let textView, textView.window != nil else { return }
    let session = ObjectIdentifier(controller)
    TranscriptSendStaging.shared.stage(
      session: session,
      textView: textView,
      textRect: textView.laidOutTextRect,
      lineHeight: textView.firstLineHeight,
      bubble: theme.bubbleBackground,
      theme: theme
    )
    (textView as? SubmittingTextView)?.hideSentText()
  }
}

extension NSTextView {
  fileprivate var laidOutTextRect: CGRect {
    let length = (string as NSString).length
    let start = viewRect(forCharacterAt: 0)
    let end = viewRect(forCharacterAt: length)
    let trailing = bounds.width - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 0)
    let isSingleLine = abs(end.minY - start.minY) < start.height / 2
    return CGRect(
      x: start.minX,
      y: start.minY,
      width: max(0, (isSingleLine ? end.minX : trailing) - start.minX),
      height: max(start.height, end.maxY - start.minY)
    )
  }

  fileprivate var firstLineHeight: CGFloat { viewRect(forCharacterAt: 0).height }

  private func viewRect(forCharacterAt location: Int) -> CGRect {
    let screenRect = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
    guard let window else { return .zero }
    return convert(window.convertFromScreen(screenRect), from: nil)
  }
}
