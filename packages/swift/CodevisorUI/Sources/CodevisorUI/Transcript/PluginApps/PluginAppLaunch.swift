import Foundation

public struct PluginAppLaunch: Equatable, Sendable {
  public static let lifetime: TimeInterval = 10 * 60

  public var path: String
  public var issuedAt: Date

  public init(path: String, issuedAt: Date) {
    self.path = path
    self.issuedAt = issuedAt
  }

  public func isFresh(at now: Date) -> Bool {
    now.timeIntervalSince(issuedAt) < Self.lifetime
  }
}
