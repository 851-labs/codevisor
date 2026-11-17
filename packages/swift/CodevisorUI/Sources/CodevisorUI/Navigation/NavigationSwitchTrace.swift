import Foundation
import TranscriptKit

@MainActor
public final class NavigationSwitchTrace {
  public static let shared = NavigationSwitchTrace()

  private var observer: MainThreadSettleObserver?
  private var values: [String: Double] = [:]
  private var awaitsSwitch = false

  public func beginCommand() {
    guard TranscriptPerformanceTrace.isEnabled else { return }

    start(["fromCommand": 1])
    awaitsSwitch = true
  }

  public func begin(workspaceChanged: Bool) {
    guard TranscriptPerformanceTrace.isEnabled else { return }

    if awaitsSwitch {
      awaitsSwitch = false
      values["workspaceChanged"] = workspaceChanged ? 1 : 0
    } else {
      start(["workspaceChanged": workspaceChanged ? 1 : 0])
    }
  }

  private func start(_ values: [String: Double]) {
    observer?.cancel()
    self.values = values
    observer = MainThreadSettleObserver { [weak self] result in self?.record(result) }
  }

  public func note(_ name: String) {
    guard observer != nil else { return }

    values[name] = 1
  }

  private func record(_ result: MainThreadSettle.Result) {
    observer = nil
    guard !awaitsSwitch else {
      awaitsSwitch = false
      return
    }

    values["firstPassMS"] = Double(result.firstPassNanoseconds) / 1_000_000
    values["settleMS"] = Double(result.settleNanoseconds) / 1_000_000
    values["settled"] = result.settled ? 1 : 0
    TranscriptPerformanceTrace.record(
      "navigation.switch", durationMS: Double(result.busyNanoseconds) / 1_000_000, values: values)
  }
}
