import ACPKit
import CodevisorProtocol
import Foundation

public enum ServerDateCoding {
  private final class Formatters: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter
    }()
    private let wholeSeconds: ISO8601DateFormatter = {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      return formatter
    }()

    func string(from date: Date) -> String {
      lock.withLock { fractional.string(from: date) }
    }

    func date(from string: String) -> Date? {
      lock.withLock {
        fractional.date(from: string) ?? wholeSeconds.date(from: string)
      }
    }
  }

  private static let formatters = Formatters()

  public static func string(from date: Date) -> String {
    formatters.string(from: date)
  }

  public static func date(from string: String) throws -> Date {
    if let date = formatters.date(from: string) { return date }
    throw CodevisorServerClientError.invalidDate(string)
  }
}
