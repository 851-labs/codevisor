import Foundation
import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  /// A viewer that draws the pointer itself subscribes on the cursor channel (851-2377): the
  /// capture leaves the pointer out and the publisher streams it. If the channel goes, the
  /// pointer goes back into the video. An older viewer never subscribes.
  func configureCursor(_ session: Session) {
    let displayID = session.displayID
    let channel = session.peer.cursorChannel
    channel.onMessage = { [weak session, weak channel] message in
      guard case .subscribe = message, let session, let channel, !session.stopping, session.cursor == nil else {
        return
      }
      let publisher = ScreenSharingCursorPublisher(
        bounds: { ScreenSharingCursorPublisher.displayArea(displayID) },
        scale: { ScreenSharingCursorPublisher.displayScale(displayID) },
        send: { [weak channel] in channel?.send($0) ?? false })
      session.cursor = publisher
      session.metrics.label("cursorStream", "on")
      publisher.start()
      Task { try? await session.capture.setShowsCursor(false) }
    }
    channel.onAvailabilityChanged = { [weak session] available in
      guard !available, let session, let publisher = session.cursor else { return }
      publisher.stop()
      session.cursor = nil
      session.metrics.label("cursorStream", "closed")
      guard !session.stopping else { return }
      Task { try? await session.capture.setShowsCursor(true) }
    }
  }
}
