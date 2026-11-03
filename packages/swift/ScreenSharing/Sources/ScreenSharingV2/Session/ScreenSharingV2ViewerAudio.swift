import Foundation
import ScreenSharing
import Synchronization

@MainActor
final class ScreenSharingV2ViewerAudio {
  final class Sink: Sendable {
    private let player = Mutex<ScreenSharingAudioPlayer?>(nil)
    private let packets = Atomic(0)

    var packetsReceived: Int { packets.load(ordering: .relaxed) }

    func set(_ player: ScreenSharingAudioPlayer?) {
      self.player.withLock { $0 = player }
    }

    func receive(_ packet: ScreenSharingAudioPacket) {
      packets.add(1, ordering: .relaxed)
      player.withLock { $0 }?.receive(packet)
    }
  }

  static let baseDelay = 0.04
  static let maximumMargin = 0.12

  let sink = Sink()
  private let channel: ScreenSharingV2Channel<ScreenSharingAudioMessage>
  private let metrics: ScreenSharingMetrics
  private var player: ScreenSharingAudioPlayer?
  private var wanted = false
  private var subscribed = false
  private var volume: Float = 1
  private var tuning: Task<Void, Never>?

  init(channel: ScreenSharingV2Channel<ScreenSharingAudioMessage>, metrics: ScreenSharingMetrics) {
    self.channel = channel
    self.metrics = metrics
    channel.onAvailabilityChanged = { [weak self] available in
      if available { self?.subscribe() } else { self?.subscribed = false }
    }
  }

  func setEnabled(_ enabled: Bool) {
    wanted = enabled
    guard enabled else { return stop() }

    if player == nil {
      do {
        let player = try ScreenSharingAudioPlayer(targetDelay: Self.baseDelay)
        player.setVolume(volume)
        player.start { [weak self, metrics] error in
          metrics.label("audioError", error.localizedDescription)
          Task { @MainActor in self?.outputFailed(player) }
        }
        self.player = player
        sink.set(player)
      } catch {
        metrics.label("audioError", error.localizedDescription)
        return
      }
    }
    subscribe()
    tuning = tuning ?? Task { [weak self] in await self?.tune() }
  }

  func setVolume(_ volume: Float) {
    self.volume = min(1, max(0, volume))
    player?.setVolume(self.volume)
  }

  func stop() {
    if subscribed { channel.send(.unsubscribe) }
    subscribed = false
    tuning?.cancel()
    tuning = nil
    sink.set(nil)
    player?.stop()
    player = nil
  }

  static func margin(_ margin: Double, newUnderruns: Int) -> Double {
    newUnderruns > 0 ? min(maximumMargin, margin + 0.01 * Double(newUnderruns)) : max(0, margin - 0.002)
  }

  private func subscribe() {
    guard wanted, !subscribed, channel.isAvailable else { return }

    subscribed = channel.send(.subscribe)
  }

  private func outputFailed(_ failed: ScreenSharingAudioPlayer) {
    guard player === failed else { return }

    wanted = false
    stop()
  }

  private func tune() async {
    var margin = 0.0
    var underruns = 0
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let player else { return }

      let buffer = player.statistics
      margin = Self.margin(margin, newUnderruns: buffer.underruns - underruns)
      underruns = buffer.underruns
      player.setTargetDelay(Self.baseDelay + margin)
      guard sink.packetsReceived > 0 else { continue }

      metrics.label("audioTargetDelayMs", String(Int((Self.baseDelay + margin) * 1000)))
      metrics.label(
        "audio",
        "buffered \(buffer.buffered) frames, underruns \(buffer.underruns), lost \(buffer.lost), dropped \(buffer.dropped)"
      )
    }
  }
}
