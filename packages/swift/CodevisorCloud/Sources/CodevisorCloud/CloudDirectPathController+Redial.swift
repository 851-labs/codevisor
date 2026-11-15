import CodevisorClient
import Foundation

struct CloudQuickRedialWindow: Equatable, Sendable {
  static let waits: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
  static let length: Duration = .seconds(30)

  let openedAt: ContinuousClock.Instant
  private(set) var used = 0

  init(openedAt: ContinuousClock.Instant) {
    self.openedAt = openedAt
  }

  mutating func nextWait(at now: ContinuousClock.Instant) -> Duration? {
    guard openedAt.duration(to: now) < Self.length, Self.waits.indices.contains(used) else { return nil }

    defer { used += 1 }
    return Self.waits[used]
  }
}

extension CloudDirectPathController {
  static let shortLivedPipe: Duration = .seconds(10)

  public func redialNow(_ deviceId: String) {
    guard known[deviceId] != nil, connections[deviceId] == nil else { return }

    resetFailures(deviceId)
    quickWindows[deviceId] = nil
    guard probeTasks[deviceId] == nil else { return }

    Log.cloud.log("Tunnel to machine \(deviceId, privacy: .public) redialed on request")
    startProbe(deviceId)
  }

  func afterLiveDrop(_ deviceId: String) {
    if let lived = liveSince.removeValue(forKey: deviceId)?.duration(to: now()), lived < Self.shortLivedPipe {
      Log.cloud.notice(
        "Tunnel to machine \(deviceId, privacy: .public) dropped \(String(describing: lived), privacy: .public) after it came up"
      )
      return retryLater(deviceId)
    }
    resetFailures(deviceId)
    quickWindows[deviceId] = CloudQuickRedialWindow(openedAt: now())
    guard probeTasks[deviceId] == nil else { return }

    startProbe(deviceId)
  }

  func retryQuickly(_ deviceId: String) -> Bool {
    guard let wait = quickWindows[deviceId]?.nextWait(at: now()) else { return false }

    retry(deviceId, after: wait)
    return true
  }

  func retryLater(_ deviceId: String) {
    guard !retryQuickly(deviceId) else { return }

    scheduleRetry(deviceId)
  }
}
