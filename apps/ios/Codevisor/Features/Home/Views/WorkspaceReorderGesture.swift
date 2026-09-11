import SwiftUI
import UIKit

/// One continuous recognizer owns the hold and subsequent drag. A swipe fails
/// the hold as soon as it moves, leaving the List's pan recognizer free to
/// scroll. A SwiftUI sequence containing DragGesture can claim that pan while
/// its long press is still pending, even when installed as simultaneous.
struct WorkspaceReorderGesture: UIGestureRecognizerRepresentable {
  var onBegan: (CGPoint) -> Void
  var onChanged: (CGPoint) -> Void
  var onEnded: () -> Void

  func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
    let recognizer = UILongPressGestureRecognizer()
    recognizer.minimumPressDuration = 0.35
    recognizer.allowableMovement = 10
    return recognizer
  }

  func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
    switch recognizer.state {
    case .began:
      onBegan(context.converter.location(in: .global))
    case .changed:
      onChanged(context.converter.location(in: .global))
    case .ended, .cancelled:
      onEnded()
    default:
      break
    }
  }
}
