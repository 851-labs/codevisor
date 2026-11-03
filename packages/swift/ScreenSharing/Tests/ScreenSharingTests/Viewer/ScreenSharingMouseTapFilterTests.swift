import AppKit
import Synchronization
import Testing

@testable import ScreenSharing

struct ScreenSharingMouseTapFilterTests {
  @Test func theUsersMouseEventsOverTheVideosWindowAndAPressDraggedOutOfItAreDelivered() throws {
    let delivered = Mutex<[CGEventType]>([])
    let filter = ScreenSharingMouseTapFilter(window: 42) { type, _ in delivered.withLock { $0.append(type) } }
    func event(
      _ type: CGEventType, window: Int64, injected: Bool = false, button: CGMouseButton = .left
    ) throws -> CGEvent {
      let event = try #require(
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button))
      event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
      if injected { event.setIntegerValueField(.eventSourceUserData, value: ScreenSharingInputInjector.eventTag) }
      return event
    }

    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 7))
    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 42, injected: true))
    filter.observe(.scrollWheel, try event(.leftMouseDown, window: 42))
    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 42))
    filter.observe(.rightMouseDown, try event(.rightMouseDown, window: 42, button: .right))
    filter.observe(.rightMouseUp, try event(.rightMouseUp, window: 42, button: .right))
    filter.observe(.leftMouseDragged, try event(.leftMouseDragged, window: 7))
    filter.observe(.leftMouseUp, try event(.leftMouseUp, window: 7))
    filter.observe(.mouseMoved, try event(.mouseMoved, window: 7))
    filter.set(acceptsInjected: true)
    filter.observe(.mouseMoved, try event(.mouseMoved, window: 42, injected: true))
    filter.set(window: nil)
    filter.observe(.mouseMoved, try event(.mouseMoved, window: 42))

    #expect(
      delivered.withLock { $0 } == [
        .leftMouseDown, .rightMouseDown, .rightMouseUp, .leftMouseDragged, .leftMouseUp, .mouseMoved,
      ])
  }
}
