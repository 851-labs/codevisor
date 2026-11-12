import Foundation
import Observation

@MainActor
@Observable
public final class SidebarElapsedClock {
  public static let shared = SidebarElapsedClock()

  public private(set) var now = Date()
  @ObservationIgnored private var watchers = 0
  @ObservationIgnored private var ticker: Task<Void, Never>?

  public func watch() {
    watchers += 1
    guard ticker == nil else { return }

    now = Date()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        self?.now = Date()
      }
    }
  }

  public func unwatch() {
    watchers = max(0, watchers - 1)
    guard watchers == 0 else { return }

    ticker?.cancel()
    ticker = nil
  }
}
