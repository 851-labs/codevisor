import Foundation

public enum SetupDuration {
  public static func text(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }

  public static func completed(_ title: String, after duration: TimeInterval?) -> String {
    guard let duration, duration >= 1 else { return "\(title) in a moment" }
    return "\(title) in \(text(Int(duration.rounded())))"
  }

  public static func elapsed(since start: Date, to now: Date) -> String {
    text(max(0, Int(now.timeIntervalSince(start))))
  }
}
