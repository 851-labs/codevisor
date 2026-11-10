import Foundation

public struct TypeSelectBuffer: Equatable, Sendable {
  public static let resetInterval: TimeInterval = 1

  private var typed = ""
  private var lastKeyAt: Date?

  public init() {}

  public mutating func type(_ characters: String, at now: Date) -> String {
    if let lastKeyAt, now.timeIntervalSince(lastKeyAt) >= Self.resetInterval { typed = "" }
    typed += characters
    lastKeyAt = now
    return typed
  }

  public static func match(_ typed: String, in names: [(id: String, name: String)]) -> String? {
    let needle = typed.lowercased()
    guard !needle.isEmpty else { return nil }
    return names.first { $0.name.lowercased().hasPrefix(needle) }?.id
  }
}
