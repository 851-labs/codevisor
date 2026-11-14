import Foundation
import Observation
import ScreenSharing

@MainActor
@Observable
final class ScreenSharingViewedSession {
  let control: ScreenSharingControlSession?
  let diagnostics = ScreenSharingViewerDiagnostics()

  @ObservationIgnored let session: any ScreenSharingViewingSession
  @ObservationIgnored private var statistics: Task<Void, Never>?

  static let statisticsInterval: Duration = .seconds(1)

  init(
    _ session: any ScreenSharingViewingSession, clock: any Clock<Duration> = ContinuousClock(),
    isLive: @escaping @MainActor () -> Bool
  ) {
    self.session = session
    control = session.control.map { ScreenSharingControlSession(channel: $0, clock: clock) }
    statistics = Task { [weak self] in
      while (try? await clock.sleep(for: Self.statisticsInterval)) != nil {
        guard let self else { return }

        if isLive() { await self.readStatistics() }
      }
    }
  }

  func close() {
    statistics?.cancel()
    statistics = nil
    control?.close()
  }

  private func readStatistics() async {
    let statistics = await session.statistics()
    guard !Task.isCancelled else { return }

    diagnostics.update(
      metrics: session.metrics.snapshot(), timeline: session.metrics.timeline, statistics: statistics,
      now: ProcessInfo.processInfo.systemUptime)
  }
}
