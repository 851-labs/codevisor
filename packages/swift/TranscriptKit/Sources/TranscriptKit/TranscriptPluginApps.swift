import ACPKit
import Foundation

public enum TranscriptPluginApps {
  public static func apps(of call: ToolCall) -> [CodevisorExecutionApp] {
    guard call.status == .completed, let execution = call.codevisorExecution, execution.state != .failed
    else { return [] }
    return execution.apps
  }

  public static func apps(in items: [WorkedItem]) -> [CodevisorExecutionApp] {
    var seen: Set<String> = []
    return items.flatMap(calls(of:)).flatMap(apps(of:)).filter { seen.insert($0.viewId).inserted }
  }

  private static func calls(of item: WorkedItem) -> [ToolCall] {
    guard case let .toolGroup(group) = item else { return [] }
    return group.calls
  }
}
