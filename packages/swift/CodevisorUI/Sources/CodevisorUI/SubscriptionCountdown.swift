import Foundation

nonisolated public enum SubscriptionCountdown {
  public static func text(until firesAt: Date, now: Date) -> String {
    phrase(until: firesAt, now: now, units: .abbreviated)
  }

  public static func spokenText(until firesAt: Date, now: Date) -> String {
    phrase(until: firesAt, now: now, units: .spoken)
  }

  private static func phrase(until firesAt: Date, now: Date, units: Units) -> String {
    let minutes = Int((firesAt.timeIntervalSince(now) / 60).rounded(.up))
    guard minutes > 0 else { return units.now }

    return "\(units.in) \(duration(minutes, units))"
  }

  private static func duration(_ minutes: Int, _ units: Units) -> String {
    if minutes < minutesPerHour { return count(minutes, units.minute) }
    if minutes < minutesPerDay { return hoursAndMinutes(minutes, units) }
    return count(minutes / minutesPerDay, units.day)
  }

  private static func hoursAndMinutes(_ minutes: Int, _ units: Units) -> String {
    let hours = count(minutes / minutesPerHour, units.hour)
    let rest = minutes % minutesPerHour
    guard rest > 0 else { return hours }
    return "\(hours) \(count(rest, units.minute))"
  }

  private static func count(_ value: Int, _ unit: Unit) -> String {
    "\(value) \(value == 1 ? unit.one : unit.many)"
  }

  private static let minutesPerHour = 60
  private static let minutesPerDay = 24 * 60
}

nonisolated private struct Unit {
  let one: String
  let many: String
}

nonisolated private struct Units {
  let now: String
  let `in`: String
  let minute: Unit
  let hour: Unit
  let day: Unit

  static let abbreviated = Units(
    now: "Now", in: "In", minute: Unit(one: "min", many: "mins"), hour: Unit(one: "hr", many: "hrs"),
    day: Unit(one: "day", many: "days"))

  static let spoken = Units(
    now: "now", in: "in", minute: Unit(one: "minute", many: "minutes"), hour: Unit(one: "hour", many: "hours"),
    day: Unit(one: "day", many: "days"))
}
