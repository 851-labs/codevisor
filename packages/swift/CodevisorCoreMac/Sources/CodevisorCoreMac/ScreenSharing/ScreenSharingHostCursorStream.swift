import Foundation
import ScreenSharing

@MainActor
final class ScreenSharingHostCursorStream {
  private var publisher: ScreenSharingCursorPublisher?
  private let metrics: ScreenSharingMetrics
  private let isStopping: () -> Bool
  private let setShowsCursor: (Bool) -> Void

  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingCursorMessage>,
    displayID: UInt32, metrics: ScreenSharingMetrics,
    isStopping: @escaping () -> Bool, setShowsCursor: @escaping (Bool) -> Void
  ) {
    self.metrics = metrics
    self.isStopping = isStopping; self.setShowsCursor = setShowsCursor
    channel.onMessage = { [weak self, weak channel] message in
      guard case .subscribe = message, let self, let channel, !isStopping(), publisher == nil else {
        return
      }
      let publisher = ScreenSharingCursorPublisher(
        bounds: { ScreenSharingCursorPublisher.displayArea(displayID) },
        scale: { ScreenSharingCursorPublisher.displayScale(displayID) }, metrics: metrics,
        send: { [weak channel] in channel?.send($0) ?? false })
      self.publisher = publisher
      metrics.label("cursorStream", "on")
      publisher.start()
      setShowsCursor(false)
    }
    channel.onAvailabilityChanged = { [weak self] available in
      guard !available else { return }
      self?.channelClosed()
    }
  }

  private func channelClosed() {
    guard let publisher else { return }
    publisher.stop()
    self.publisher = nil
    metrics.label("cursorStream", "closed")
    guard !isStopping() else { return }
    setShowsCursor(true)
  }

  func stopPublishing() { publisher?.stop() }
}
