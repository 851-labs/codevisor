import Foundation

nonisolated public enum SubscriptionCountdown {
  public static func text(until firesAt: Date, now: Date) -> String {
    let minutes = Int((firesAt.timeIntervalSince(now) / 60).rounded(.up))
    guard minutes > 0 else { return "Now" }

    if minutes < minutesPerHour { return "In \(count(minutes, "min", "mins"))" }
    if minutes < minutesPerDay { return "In \(hoursAndMinutes(minutes))" }
    return "In \(count(minutes / minutesPerDay, "day", "days"))"
  }

  private static func hoursAndMinutes(_ minutes: Int) -> String {
    let hours = count(minutes / minutesPerHour, "hr", "hrs")
    let rest = minutes % minutesPerHour
    guard rest > 0 else { return hours }
    return "\(hours) \(count(rest, "min", "mins"))"
  }

  private static func count(_ value: Int, _ one: String, _ many: String) -> String {
    "\(value) \(value == 1 ? one : many)"
  }

  private static let minutesPerHour = 60
  private static let minutesPerDay = 24 * 60
}
