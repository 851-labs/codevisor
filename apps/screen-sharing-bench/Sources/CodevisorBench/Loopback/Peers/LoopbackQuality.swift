import ScreenSharing
import ScreenSharingWebRTC

@MainActor
final class LoopbackQuality {
  private var task: Task<Void, Never>?
  private(set) var highestLevel = 0

  func start(
    sender: ScreenSharingSender, source: any LoopbackSource, configuration: ScreenSharingVideoConfiguration
  ) {
    task = Task { [weak self] in
      await ScreenSharingQualityLoop.run(
        base: { configuration }, isViewing: { true }, statistics: { await sender.statistics() },
        apply: { adapted, level in
          guard (try? await source.adapt(to: adapted)) != nil else { return false }

          sender.updateVideoConfiguration(adapted)

          self?.highestLevel = max(self?.highestLevel ?? 0, level)
          return true
        })
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}
