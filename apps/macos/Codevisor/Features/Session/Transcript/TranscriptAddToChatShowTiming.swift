import AppKit

@MainActor
final class TranscriptAddToChatShowTiming {
  private static let paragraphClickCount = 3
  private static let longestWait = Duration.milliseconds(250)

  private let clock: any Clock<Duration>
  private let doubleClickInterval: () -> Duration
  private var pendingShow: Task<Void, Never>?

  init(
    clock: any Clock<Duration> = ContinuousClock(),
    doubleClickInterval: @escaping () -> Duration = { .seconds(NSEvent.doubleClickInterval) }
  ) {
    self.clock = clock
    self.doubleClickInterval = doubleClickInterval
  }

  func show(afterClickCount clickCount: Int, draggedSelection: Bool, _ show: @escaping @MainActor () -> Void) {
    cancel()
    guard Self.mayBeFollowedByAnotherClick(clickCount: clickCount, draggedSelection: draggedSelection) else {
      return show()
    }

    pendingShow = Task { [clock, wait = multiClickWait] in
      do { try await clock.sleep(for: wait) } catch { return }
      guard !Task.isCancelled else { return }
      show()
    }
  }

  func cancel() {
    pendingShow?.cancel()
    pendingShow = nil
  }

  private var multiClickWait: Duration {
    min(doubleClickInterval(), Self.longestWait)
  }

  private static func mayBeFollowedByAnotherClick(clickCount: Int, draggedSelection: Bool) -> Bool {
    !draggedSelection && clickCount < paragraphClickCount
  }
}
