import CoreGraphics
import Foundation

public struct TranscriptMeasurementLedger: Sendable {
  public private(set) var heightsByKey: [String: CGFloat]
  private var staleKeys: Set<String>

  public init() {
    heightsByKey = [:]
    staleKeys = []
  }

  public subscript(key: String) -> CGFloat? {
    heightsByKey[key]
  }

  public mutating func setExact(_ height: CGFloat, for key: String) {
    heightsByKey[key] = height
    staleKeys.remove(key)
  }

  public mutating func setProvisional(_ height: CGFloat, for key: String) {
    heightsByKey[key] = height
    staleKeys.insert(key)
  }

  public mutating func markStale(_ key: String) {
    guard heightsByKey[key] != nil else { return }
    staleKeys.insert(key)
  }

  public func isStale(_ key: String) -> Bool {
    staleKeys.contains(key)
  }

  public func needsCommit(_ height: CGFloat, for key: String) -> Bool {
    staleKeys.contains(key) || abs((heightsByKey[key] ?? 0) - height) > 0.5
  }

  @discardableResult
  public mutating func commit(_ height: CGFloat, for key: String) -> Bool {
    let changed = abs((heightsByKey[key] ?? 0) - height) > 0.5
    heightsByKey[key] = height
    staleKeys.remove(key)
    return changed
  }

  public mutating func removeAll(keepingCapacity: Bool) {
    heightsByKey.removeAll(keepingCapacity: keepingCapacity)
    staleKeys.removeAll(keepingCapacity: keepingCapacity)
  }
}
