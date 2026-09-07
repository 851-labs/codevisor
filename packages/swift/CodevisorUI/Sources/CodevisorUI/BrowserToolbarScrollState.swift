import Foundation

/// Tracks deliberate reading gestures without reacting to page layout, restored
/// scroll positions, or rubber-banding at either end of the document.
struct BrowserToolbarScrollState {
  private(set) var isCollapsed = false
  private var previousOffset: CGFloat?
  private var travel: CGFloat = 0

  mutating func setCollapsed(_ collapsed: Bool) {
    guard isCollapsed != collapsed else { return }
    isCollapsed = collapsed
    previousOffset = nil
    travel = 0
  }

  mutating func update(offset: CGFloat, maximumOffset: CGFloat, isUserScrolling: Bool, keepExpanded: Bool) {
    guard !keepExpanded else {
      setCollapsed(false)
      previousOffset = nil
      travel = 0
      return
    }
    guard isUserScrolling, maximumOffset > 80 else {
      previousOffset = nil
      travel = 0
      if maximumOffset <= 80 { setCollapsed(false) }
      return
    }
    let position = min(max(0, offset), maximumOffset)
    defer { previousOffset = position }
    guard position > 8 else {
      setCollapsed(false)
      travel = 0
      return
    }
    guard let previousOffset else { return }
    let delta = position - previousOffset
    guard delta != 0 else { return }
    if (delta > 0) != (travel > 0) { travel = 0 }
    travel += delta
    if !isCollapsed, position > 80, travel >= 48 {
      setCollapsed(true)
    } else if isCollapsed, travel <= -24 {
      setCollapsed(false)
    }
  }
}
