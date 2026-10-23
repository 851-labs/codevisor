import Foundation

public enum UsageLimitResumeText {
  public static func detail(
    resumesAt: Date?,
    now: Date = .now,
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    guard let resumesAt else { return "Resumes automatically when your limit resets." }
    guard resumesAt > now else { return "Resuming shortly." }

    let time = resumesAt.formatted(timeStyle(calendar: calendar, locale: locale))
    if calendar.isDate(resumesAt, inSameDayAs: now) { return "Resumes automatically at \(time)." }
    if isTomorrow(resumesAt, now: now, calendar: calendar) {
      return "Resumes automatically tomorrow at \(time)."
    }
    let day = resumesAt.formatted(dayStyle(calendar: calendar, locale: locale))
    return "Resumes automatically on \(day) at \(time)."
  }

  private static func isTomorrow(_ date: Date, now: Date, calendar: Calendar) -> Bool {
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return false }
    return calendar.isDate(date, inSameDayAs: tomorrow)
  }

  private static func timeStyle(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
    Date.FormatStyle(
      date: .omitted,
      time: .shortened,
      locale: locale,
      calendar: calendar,
      timeZone: calendar.timeZone
    )
  }

  private static func dayStyle(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
      .month(.abbreviated)
      .day()
  }
}
