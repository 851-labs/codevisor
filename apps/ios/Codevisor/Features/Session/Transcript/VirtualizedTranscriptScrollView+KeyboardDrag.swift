import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  var isKeyboardShown: Bool {
    isKeyboardUp && heightWithoutKeyboard > 0 && bounds.height < heightWithoutKeyboard - 2
  }

  func setKeyboardDismissPadding(_ padding: CGFloat) {
    keyboardLayoutGuide.keyboardDismissPadding = padding
    window?.keyboardLayoutGuide.keyboardDismissPadding = padding
  }

  var heightBehindKeyboard: CGFloat {
    guard let window, let keyboardScreenFrame else { return 0 }
    let keyboardTop = window.convert(keyboardScreenFrame, from: window.screen.coordinateSpace).minY
    return max(0, convert(bounds, to: window).maxY - keyboardTop)
  }

  func beginKeyboardDrag() {
    setKeyboardDismissPadding(max(0, verticalScrollIndicatorInsets.bottom - heightBehindKeyboard))
    holdsForKeyboardDrag = isKeyboardShown && currentDistanceFromBottom() <= Self.atBottomThreshold
  }

  func holdForKeyboardDrag() {
    guard holdsForKeyboardDrag, !isHoldingForKeyboardDrag else { return }
    guard isKeyboardShown else {
      holdsForKeyboardDrag = false
      return
    }
    let pinned = viewportGeometry.boundedOffsetY(viewportGeometry.offsetY(distanceFromBottom: 0))
    guard abs(contentOffset.y - pinned) > 0.25 else { return }
    isHoldingForKeyboardDrag = true
    contentOffset.y = pinned
    panGestureRecognizer.setTranslation(.zero, in: self)
    isHoldingForKeyboardDrag = false
  }

  func endKeyboardDrag(targetContentOffset: UnsafeMutablePointer<CGPoint>) {
    guard holdsForKeyboardDrag else { return }
    targetContentOffset.pointee.y = contentOffset.y
  }
}
