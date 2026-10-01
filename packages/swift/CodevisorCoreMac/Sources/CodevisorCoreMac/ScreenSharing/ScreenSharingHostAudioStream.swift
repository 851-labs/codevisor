import Foundation
import ScreenSharing

/// Owns the subscribed audio encoder and capture hand-off for one host session.
@MainActor
final class ScreenSharingHostAudioStream {
  private var encoder: ScreenSharingAudioEncoder?
  private let tap: ScreenSharingCaptureAudioTap
  private let metrics: ScreenSharingMetrics
  private let isStopping: () -> Bool
  private let setCapturesAudio: (Bool) -> Void

  /// `sendPacket` is called on the capture's audio queue for every 20 ms packet: the native
  /// channel's send is thread-safe and never waits for WebRTC, so packets don't hop through main.
  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingAudioMessage>,
    sendPacket: @escaping @Sendable (ScreenSharingAudioMessage) -> Bool,
    tap: ScreenSharingCaptureAudioTap, metrics: ScreenSharingMetrics,
    isStopping: @escaping () -> Bool, setCapturesAudio: @escaping (Bool) -> Void
  ) {
    self.tap = tap; self.metrics = metrics
    self.isStopping = isStopping; self.setCapturesAudio = setCapturesAudio
    channel.onMessage = { [weak self] message in
      guard let self, !isStopping() else { return }
      switch message {
      case .subscribe:
        guard encoder == nil else { return }
        do {
          let encoder = try ScreenSharingAudioEncoder { [metrics] packet in
            metrics.increment("audioPacketsEncoded")
            _ = sendPacket(.packet(packet))
          }
          self.encoder = encoder
          tap.set { encoder.append(sampleBuffer: $0) }
          metrics.label("audioStream", "on")
          setCapturesAudio(true)
        } catch {
          metrics.label("audioStream", error.localizedDescription)
        }
      case .unsubscribe:
        stop()
      case .packet:
        return
      }
    }
    channel.onAvailabilityChanged = { [weak self] available in
      guard !available else { return }
      self?.stop()
    }
  }

  /// Detach before closing the peer; the channel-close callback still releases the encoder.
  func detachCapture() { tap.set(nil) }

  private func stop() {
    guard encoder != nil else { return }
    tap.set(nil)
    encoder = nil
    metrics.label("audioStream", "off")
    guard !isStopping() else { return }
    setCapturesAudio(false)
  }
}
