import Foundation
import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  /// A viewer that plays the host's sound subscribes on the audio channel (851-2379): the capture
  /// adds the system's audio (this app's own excluded) and each 20 ms Opus packet goes out as it's
  /// encoded. Unsubscribing (mute) or losing the channel stops the audio capture again.
  func configureAudio(_ session: Session) {
    let channel = session.peer.audioChannel
    channel.onMessage = { [weak session, weak channel] message in
      guard let session, let channel, !session.stopping else { return }
      switch message {
      case .subscribe:
        guard session.audioEncoder == nil else { return }
        do {
          let encoder = try ScreenSharingAudioEncoder { [weak channel, metrics = session.metrics] packet in
            metrics.increment("audioPacketsEncoded")
            DispatchQueue.main.async {
              MainActor.assumeIsolated { _ = channel?.send(.packet(packet)) }
            }
          }
          session.audioEncoder = encoder
          session.capture.audio.set { encoder.append(sampleBuffer: $0) }
          session.metrics.label("audioStream", "on")
          Task { try? await session.capture.setCapturesAudio(true) }
        } catch {
          session.metrics.label("audioStream", error.localizedDescription)
        }
      case .unsubscribe:
        Self.stopAudio(session)
      case .packet:
        return
      }
    }
    channel.onAvailabilityChanged = { [weak session] available in
      guard !available, let session else { return }
      Self.stopAudio(session)
    }
  }

  private static func stopAudio(_ session: Session) {
    guard session.audioEncoder != nil else { return }
    session.capture.audio.set(nil)
    session.audioEncoder = nil
    session.metrics.label("audioStream", "off")
    guard !session.stopping else { return }
    Task { try? await session.capture.setCapturesAudio(false) }
  }
}
