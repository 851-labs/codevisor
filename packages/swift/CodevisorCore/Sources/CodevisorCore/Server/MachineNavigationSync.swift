import Foundation
import Observation

@MainActor
@Observable
final class MachineNavigationSync {
  var state: NavigationSyncState?

  @ObservationIgnored var eventStreamTask: Task<Void, Never>?
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var token: UUID?
  @ObservationIgnored var manualRefresh: MachineNavigationRefresh?
  @ObservationIgnored var pendingRefreshTask: Task<Void, Never>?

  var isWaitingForCatchUp: Bool {
    task == nil && state == .catchingUp
  }

  func beginCatchUp() {
    if state == nil || state == .cached {
      state = .catchingUp
    }
  }

  func begin(_ task: Task<Void, Never>) -> UUID {
    self.task?.cancel()
    let token = UUID()
    self.token = token
    self.task = task
    return token
  }

  func isRunning(_ token: UUID) -> Bool {
    self.token == token
  }

  func finish(_ token: UUID) {
    guard isRunning(token) else { return }

    end()
  }

  func end() {
    token = nil
    task = nil
  }

  func markCurrent() {
    state = .current
  }

  func stopEventStream() {
    eventStreamTask?.cancel()
    eventStreamTask = nil
  }

  func stopSyncing() {
    task?.cancel()
    token = nil
    task = nil
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    stopEventStream()
  }

  func cancelAll() {
    manualRefresh?.cancel()
    manualRefresh = nil
    eventStreamTask?.cancel()
    eventStreamTask = nil
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    task?.cancel()
    task = nil
    token = nil
  }
}
