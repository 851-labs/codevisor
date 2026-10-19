import SwiftUI

public struct TranscriptBotTimestampRow: View {
  let date: Date

  public init(date: Date) {
    self.date = date
  }

  public var body: some View {
    Text(Self.label(for: date))
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
  }

  static func label(for date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return "Today \(time)" }
    if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}
