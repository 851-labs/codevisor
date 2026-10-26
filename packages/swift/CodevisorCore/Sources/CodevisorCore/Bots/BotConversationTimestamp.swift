import Foundation

public enum BotConversationTimestamp {
  private static let daysShownAsWeekday = 6

  public static func text(
    for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(style.hour().minute())
    }
    if isYesterday(date, now: now, calendar: calendar) {
      return String(localized: "Yesterday")
    }
    if isWithinLastWeek(date, now: now, calendar: calendar) {
      return date.formatted(style.weekday(.wide))
    }
    return date.formatted(style.year(.twoDigits).month(.defaultDigits).day())
  }

  private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }

    return calendar.isDate(date, inSameDayAs: yesterday)
  }

  private static func isWithinLastWeek(_ date: Date, now: Date, calendar: Calendar) -> Bool {
    let start = calendar.startOfDay(for: now)
    guard let cutoff = calendar.date(byAdding: .day, value: -daysShownAsWeekday, to: start) else { return false }

    return date >= cutoff && date < start
  }
}
