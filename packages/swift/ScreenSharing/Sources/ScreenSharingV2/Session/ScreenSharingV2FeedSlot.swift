import Foundation
import Synchronization

final class ScreenSharingV2FeedSlot: Sendable {
  private let feed = Mutex<ScreenSharingV2MediaFeed?>(nil)

  var current: ScreenSharingV2MediaFeed? { feed.withLock { $0 } }

  func set(_ next: ScreenSharingV2MediaFeed) {
    feed.withLock { $0 = next }
  }

  func close() {
    feed.withLock { feed in
      feed?.close()
      feed = nil
    }
  }

  func sendDatagram(_ kind: ScreenSharingDatagramKind, _ payload: Data) -> Bool {
    current?.sendDatagram(kind, payload) ?? false
  }
}
