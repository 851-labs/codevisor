import CoreGraphics
import ScreenSharing
import Synchronization

final class ScreenSharingSharedDisplay: Sendable {
  private let id: Mutex<CGDirectDisplayID>
  private let boundsOf: @Sendable (CGDirectDisplayID) -> CGRect

  init(_ id: CGDirectDisplayID, bounds: @escaping @Sendable (CGDirectDisplayID) -> CGRect) {
    self.id = Mutex(id)
    boundsOf = bounds
  }

  var displayID: CGDirectDisplayID {
    get { id.withLock { $0 } }
    set { id.withLock { $0 = newValue } }
  }

  var bounds: CGRect { boundsOf(displayID) }
  var scale: CGFloat { ScreenSharingCursorPublisher.displayScale(displayID) }
}
