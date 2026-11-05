import ScreenSharing

@MainActor
final class TimelineCollector {
  private static let interval = Duration.seconds(1)

  private let timeline: ScreenSharingFrameTimeline
  private var lastSequence: UInt64 = 0
  private var task: Task<Void, Never>?
  private(set) var records: [ScreenSharingFrameRecord] = []

  init(_ timeline: ScreenSharingFrameTimeline) {
    self.timeline = timeline
  }

  func start() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: Self.interval) } catch { return }
        self?.collect()
      }
    }
  }

  func stop() -> [ScreenSharingFrameRecord] {
    task?.cancel()
    task = nil
    collect()
    return records
  }

  private func collect() {
    let fresh = timeline.records(after: lastSequence)
    records += fresh
    lastSequence = fresh.last?.sequence ?? lastSequence
  }
}
