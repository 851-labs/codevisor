import Foundation
import Testing

@testable import CodevisorUI

@Suite("Usage limit resume text")
struct UsageLimitResumeTextTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }()
  private let locale = Locale(identifier: "en_US")
  private let now = Date(timeIntervalSince1970: 1_792_515_600)

  @Test("Says when the chat resumes, relative to today")
  func knownResetTimes() {
    #expect(detail(hoursFromNow: 5) == "Resumes automatically at 3:00 PM")
    #expect(detail(hoursFromNow: 23) == "Resumes automatically tomorrow at 9:00 AM")
    #expect(detail(hoursFromNow: 99) == "Resumes automatically on Oct 24 at 1:00 PM")
  }

  @Test("Stays calm when the reset time is unknown or already passed")
  func unknownOrPassedResetTimes() {
    #expect(
      UsageLimitResumeText.detail(resumesAt: nil, now: now, calendar: calendar, locale: locale)
        == "Resumes automatically when your limit resets")
    #expect(detail(hoursFromNow: -1) == "Resuming shortly")
  }

  private func detail(hoursFromNow hours: Double) -> String {
    UsageLimitResumeText.detail(
      resumesAt: now.addingTimeInterval(hours * 3_600),
      now: now,
      calendar: calendar,
      locale: locale
    )
    .replacingOccurrences(of: "\u{202F}", with: " ")
  }
}
