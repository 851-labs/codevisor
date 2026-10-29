import ScreenSharing

@MainActor
final class FirstPresentation {
  private static let pollInterval = Duration.milliseconds(20)

  private(set) var presentedNs: Int64?

  func record() {
    guard presentedNs == nil else { return }

    presentedNs = ScreenSharingMetrics.nowNs
  }

  func wait(timeout: Duration) async throws {
    let limit = ContinuousClock.now + timeout
    while presentedNs == nil {
      guard ContinuousClock.now < limit else { throw SignalingError.timedOut("waiting for the first frame") }

      try await Task.sleep(for: Self.pollInterval)
    }
  }
}
