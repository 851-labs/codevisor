import AppKit
import Synchronization
import Testing

@testable import ScreenSharing

struct ScreenSharingMouseTapFilterTests {
  @Test func onlyTheUsersMouseEventsOverTheVideosWindowAreDelivered() throws {
    let delivered = Mutex<[CGEventType]>([])
    let filter = ScreenSharingMouseTapFilter(window: 42) { type, _ in delivered.withLock { $0.append(type) } }
    func event(_ type: CGEventType, window: Int64, injected: Bool = false) throws -> CGEvent {
      let event = try #require(
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
      event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
      if injected { event.setIntegerValueField(.eventSourceUserData, value: ScreenSharingInputInjector.eventTag) }
      return event
    }

    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 42))
    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 7))
    filter.observe(.leftMouseDown, try event(.leftMouseDown, window: 42, injected: true))
    filter.observe(.leftMouseDragged, try event(.leftMouseDragged, window: 42))
    filter.observe(.scrollWheel, try event(.leftMouseDown, window: 42))
    filter.set(window: nil)
    filter.observe(.leftMouseUp, try event(.leftMouseUp, window: 42))

    #expect(delivered.withLock { $0 } == [.leftMouseDown, .leftMouseDragged])
  }
}
