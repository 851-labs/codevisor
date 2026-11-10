import Foundation

enum ServerTimestamp {
  private static let styles = [
    Date.ISO8601FormatStyle(includingFractionalSeconds: true),
    Date.ISO8601FormatStyle(),
  ]

  static func date(from value: String) -> Date? {
    styles.lazy.compactMap { try? $0.parse(value) }.first
  }
}
