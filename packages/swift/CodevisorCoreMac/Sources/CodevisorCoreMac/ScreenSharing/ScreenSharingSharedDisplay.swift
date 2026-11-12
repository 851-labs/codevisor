import CoreGraphics
import ScreenSharing
import Synchronization

final class ScreenSharingSharedDisplay: Sendable {
  private let ids: Mutex<(shared: CGDirectDisplayID, virtual: CGDirectDisplayID?)>
  private let boundsOf: @Sendable (CGDirectDisplayID) -> CGRect

  init(_ id: CGDirectDisplayID, bounds: @escaping @Sendable (CGDirectDisplayID) -> CGRect) {
    ids = Mutex((id, nil))
    boundsOf = bounds
  }

  var displayID: CGDirectDisplayID {
    get { ids.withLock { $0.shared } }
    set { ids.withLock { $0.shared = newValue } }
  }

  var virtualDisplayID: CGDirectDisplayID? {
    get { ids.withLock { $0.virtual } }
    set { ids.withLock { $0.virtual = newValue } }
  }

  var bounds: CGRect { boundsOf(virtualDisplayID ?? displayID) }
  var scale: CGFloat { ScreenSharingCursorPublisher.displayScale(virtualDisplayID ?? displayID) }
}
