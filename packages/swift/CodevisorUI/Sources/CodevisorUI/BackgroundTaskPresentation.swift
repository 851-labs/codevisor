import Foundation

public enum BackgroundTaskPresentation {
  private static let secondsPerMinute = 60
  private static let secondsPerHour = 3600

  public static func symbol(forTaskType taskType: String) -> String {
    switch taskType {
    case "shell", "local_bash": "terminal"
    case "monitor", "monitor_mcp": "eye"
    case "subagent", "local_agent", "remote_agent", "in_process_teammate": "wand.and.sparkles"
    case "workflow", "local_workflow": "flowchart"
    default: "gearshape.2"
    }
  }

  public static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < secondsPerMinute { return "\(seconds)s" }
    if seconds < secondsPerHour { return "\(seconds / secondsPerMinute)m" }

    let hours = seconds / secondsPerHour
    let minutes = seconds % secondsPerHour / secondsPerMinute
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }
}
