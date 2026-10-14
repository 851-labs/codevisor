import Foundation

public struct RigReconnectPolicy: Equatable, Sendable {
  public let initialSeconds: Double
  public let maximumSeconds: Double
  public private(set) var consecutiveFailures = 0

  public init(initialSeconds: Double = 1, maximumSeconds: Double = 10) {
    self.initialSeconds = initialSeconds
    self.maximumSeconds = maximumSeconds
  }

  public mutating func failed() -> Double {
    let delay = min(maximumSeconds, initialSeconds * pow(2, Double(consecutiveFailures)))
    consecutiveFailures += 1
    return delay
  }

  public mutating func succeeded() { consecutiveFailures = 0 }
}
