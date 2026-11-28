import Foundation

enum UnreachableSend {
  static let limit: Duration = .seconds(30)
  static let reason = "Couldn't reach the machine."

  struct Error: LocalizedError {
    var errorDescription: String? { UnreachableSend.reason }
  }
}
