@MainActor
final class ScreenSharingAttemptDeadline {
  private let clock: ScreenSharingConnectionClock
  private let isLinkReconnecting: @MainActor () -> Bool
  private let isHostRestartingCapture: @MainActor () -> Bool
  private let onHint: @MainActor () -> Void
  private var timer: Task<Void, any Error>?
  private var isMet = false

  init(
    clock: ScreenSharingConnectionClock, isLinkReconnecting: @escaping @MainActor () -> Bool,
    isHostRestartingCapture: @escaping @MainActor () -> Bool, onHint: @escaping @MainActor () -> Void
  ) {
    self.clock = clock
    self.isLinkReconnecting = isLinkReconnecting
    self.isHostRestartingCapture = isHostRestartingCapture
    self.onHint = onHint
  }

  func pass() async throws {
    let timer = Task { @MainActor in try await self.run() }
    self.timer = timer
    if isMet { timer.cancel() }
    try await withTaskCancellationHandler {
      try await timer.value
    } onCancel: {
      timer.cancel()
    }
    if isMet { throw CancellationError() }
  }

  func meet() {
    isMet = true
    timer?.cancel()
  }

  private func run() async throws {
    let hint = ScreenSharingConnectionDeadlines.stillConnectingHint
    try await clock.sleep(hint)
    onHint()
    try await waitForFirstFrame(ScreenSharingConnectionDeadlines.firstFrame - hint)
    while isHostRestartingCapture() {
      while isHostRestartingCapture() { try await clock.sleep(ScreenSharingConnectionDeadlines.heartbeatInterval) }
      try await waitForFirstFrame(ScreenSharingConnectionDeadlines.firstFrame)
    }
  }

  private func waitForFirstFrame(_ wait: Duration) async throws {
    try await clock.sleep(wait)
    guard isLinkReconnecting() else { return }

    try await clock.sleep(ScreenSharingConnectionDeadlines.reconnectingLinkGrace)
  }
}
