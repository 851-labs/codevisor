import Foundation

public struct HandlerIdentity: Equatable, Sendable {
  private let source: any Equatable & Sendable

  public init(_ source: some Equatable & Sendable) {
    self.source = source
  }

  public static var unique: HandlerIdentity { HandlerIdentity(UUID()) }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source.matches(rhs.source)
  }
}

extension Equatable {
  fileprivate func matches(_ other: any Equatable) -> Bool {
    guard let other = other as? Self else { return false }

    return self == other
  }
}
