import Foundation

/// Only replay an uncommitted, read-only navigation, once. Connection
/// recovery must never resubmit a form or repeatedly reload a broken page.
public struct WebConnectionRecovery {
  private var retried = false
  public init() {}
  public mutating func reset() { retried = false }
  public mutating func claimRetry() -> Bool {
    guard !retried else { return false }
    retried = true
    return true
  }
  public var canRetry: Bool { !retried }

  public static func accepts(_ error: any Error, method: String?, provisional: Bool) -> Bool {
    let error = error as NSError
    guard provisional, ["GET", "HEAD"].contains(method?.uppercased() ?? "GET"),
      error.domain == NSURLErrorDomain
    else { return false }
    return [
      NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
      NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
    ].contains(error.code)
  }
}
