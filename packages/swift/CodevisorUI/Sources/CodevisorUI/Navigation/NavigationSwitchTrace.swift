import Foundation
import TranscriptKit

@MainActor
public final class NavigationSwitchTrace {
  public static let shared = NavigationSwitchTrace()

  private var observer: MainThreadSettleObserver?
  private var command: MainThreadSettleObserver?
  private var values: [String: Double] = [:]

  public func timingCommand(_ body: () -> Void) {
    guard TranscriptPerformanceTrace.isEnabled else { return body() }

    command = MainThreadSettleObserver { [weak self] result in self?.record(result) }
    body()
    command?.cancel()
    command = nil
  }

  public func begin(workspaceChanged: Bool) {
    guard TranscriptPerformanceTrace.isEnabled else { return }

    observer?.cancel()
    values = ["workspaceChanged": workspaceChanged ? 1 : 0]
    if let command {
      values["fromCommand"] = 1
      observer = command
      self.command = nil
    } else {
      observer = MainThreadSettleObserver { [weak self] result in self?.record(result) }
    }
  }

  public func note(_ name: String) {
    guard observer != nil else { return }

    values[name] = 1
  }

  private func record(_ result: MainThreadSettle.Result) {
    observer = nil
    values["firstPassMS"] = Double(result.firstPassNanoseconds) / 1_000_000
    values["settleMS"] = Double(result.settleNanoseconds) / 1_000_000
    values["settled"] = result.settled ? 1 : 0
    TranscriptPerformanceTrace.record(
      "navigation.switch", durationMS: Double(result.busyNanoseconds) / 1_000_000, values: values)
  }
}
