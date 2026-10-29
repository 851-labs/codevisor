import ScreenSharingBench
import ScreenSharingWebRTC

@MainActor
final class TimingFrameSampler {
  private static let interval = Duration.milliseconds(500)
  private static let statistic = "googTimingFrameInfo"

  private(set) var frames: Set<BenchTimingFrame> = []
  private var task: Task<Void, Never>?

  func start(_ receiver: ScreenSharingReceiver, after delay: Duration) {
    task = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      while !Task.isCancelled {
        let statistics = await receiver.statistics(including: [Self.statistic])
        self?.record(statistics)
        do { try await Task.sleep(for: Self.interval) } catch { return }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func record(_ statistics: [String: String]) {
    for (key, value) in statistics where key.hasSuffix("." + Self.statistic) {
      if let frame = BenchTimingFrame(statisticsValue: value) { frames.insert(frame) }
    }
  }
}
