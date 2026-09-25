import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The composer editor a send lifts its glyphs from. A reference, so the
/// SwiftUI composer can hand the live text view to the send action.
@MainActor
final class ComposerSendSource {
  weak var textView: NSTextView?

  /// Holds the editor's current glyphs above the composer before the send
  /// clears it, for the transcript to fly into the new bubble.
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
  }
}

extension NSTextView {
  /// The laid-out glyphs, from the first line's leading edge to the last
  /// line's bottom, in this (flipped) view's coordinates. Uses the text
  /// input client geometry, which works for TextKit 1 and 2 alike.
  fileprivate var laidOutTextRect: CGRect {
    let length = (string as NSString).length
    let start = viewRect(forCharacterAt: 0)
    let end = viewRect(forCharacterAt: length)
    let trailing = bounds.width - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 0)
    // A single line is exactly as wide as its glyphs; wrapped text spans
    // the editor.
    let isSingleLine = abs(end.minY - start.minY) < start.height / 2
    return CGRect(
      x: start.minX,
      y: start.minY,
      width: max(0, (isSingleLine ? end.minX : trailing) - start.minX),
      height: max(start.height, end.maxY - start.minY)
    )
  }

  /// One line of text, from the caret geometry at the start of the draft.
  fileprivate var firstLineHeight: CGFloat { viewRect(forCharacterAt: 0).height }

  private func viewRect(forCharacterAt location: Int) -> CGRect {
    let screenRect = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
    guard let window else { return .zero }
    return convert(window.convertFromScreen(screenRect), from: nil)
  }
}
