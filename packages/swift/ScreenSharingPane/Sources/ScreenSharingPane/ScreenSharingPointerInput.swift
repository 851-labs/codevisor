import CoreGraphics
import Foundation
import ScreenSharing

struct ScreenSharingPointerInput {
  static let multiClickInterval: TimeInterval = 0.35
  static let multiClickDistance: CGFloat = 24

  private var lastClick: (time: TimeInterval, location: CGPoint, count: UInt8)?
  private var scroll = ScreenSharingScrollAccumulator()
  private var dragging = false

  mutating func tap(
    at pointer: ScreenSharingPointer, location: CGPoint, time: TimeInterval
  ) -> [ScreenSharingInputEvent] {
    let count: UInt8
    if let lastClick, time - lastClick.time <= Self.multiClickInterval,
      hypot(location.x - lastClick.location.x, location.y - lastClick.location.y) <= Self.multiClickDistance
    {
      count = lastClick.count % 3 + 1
    } else {
      count = 1
    }
    lastClick = (time, location, count)
    return Self.click(at: pointer, button: 0, count: count)
  }

  mutating func secondaryClick(at pointer: ScreenSharingPointer) -> [ScreenSharingInputEvent] {
    lastClick = nil
    return Self.click(at: pointer, button: 1, count: 1)
  }

  mutating func dragBegan(at pointer: ScreenSharingPointer) -> [ScreenSharingInputEvent] {
    lastClick = nil
    dragging = true
    return [.move(pointer, modifiers: 0), .button(pointer, button: 0, down: true, clicks: 1, modifiers: 0)]
  }

  func dragMoved(to pointer: ScreenSharingPointer) -> [ScreenSharingInputEvent] {
    dragging ? [.move(pointer, modifiers: 0)] : []
  }

  mutating func dragEnded(at pointer: ScreenSharingPointer) -> [ScreenSharingInputEvent] {
    guard dragging else { return [] }
    dragging = false
    return [.move(pointer, modifiers: 0), .button(pointer, button: 0, down: false, clicks: 1, modifiers: 0)]
  }

  mutating func scrolled(at pointer: ScreenSharingPointer, dx: Double, dy: Double) -> [ScreenSharingInputEvent] {
    let delta = scroll.add(x: dx, y: dy)
    guard delta.x != 0 || delta.y != 0 else { return [] }
    return [.scroll(pointer, x: delta.x, y: delta.y, modifiers: 0)]
  }

  private static func click(at pointer: ScreenSharingPointer, button: UInt8, count: UInt8) -> [ScreenSharingInputEvent]
  {
    [
      .move(pointer, modifiers: 0),
      .button(pointer, button: button, down: true, clicks: count, modifiers: 0),
      .button(pointer, button: button, down: false, clicks: count, modifiers: 0),
    ]
  }
}
