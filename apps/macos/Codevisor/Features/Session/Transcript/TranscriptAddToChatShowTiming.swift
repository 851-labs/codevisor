import AppKit

@MainActor
final class TranscriptAddToChatShowTiming {
  private static let paragraphClickCount = 3

  private let clock: any Clock<Duration>
  private let multiClickInterval: () -> Duration
  private var pendingShow: Task<Void, Never>?

  init(
    clock: any Clock<Duration> = ContinuousClock(),
    multiClickInterval: @escaping () -> Duration = { .seconds(NSEvent.doubleClickInterval) }
  ) {
    self.clock = clock
    self.multiClickInterval = multiClickInterval
  }

  func show(afterClickCount clickCount: Int, draggedSelection: Bool, _ show: @escaping @MainActor () -> Void) {
    cancel()
    guard Self.mayBeFollowedByAnotherClick(clickCount: clickCount, draggedSelection: draggedSelection) else {
      return show()
    }

    pendingShow = Task { [clock, interval = multiClickInterval()] in
      do { try await clock.sleep(for: interval) } catch { return }
      guard !Task.isCancelled else { return }
      show()
    }
  }

  func cancel() {
    pendingShow?.cancel()
    pendingShow = nil
  }

  private static func mayBeFollowedByAnotherClick(clickCount: Int, draggedSelection: Bool) -> Bool {
    !draggedSelection && clickCount < paragraphClickCount
  }
}
