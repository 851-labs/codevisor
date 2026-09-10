import SwiftUI

/// Counts unresolved layout preparation inside a native transcript row.
/// Geometry becomes authoritative only when every contributing child is ready.
public struct ContentLayoutReadinessPreferenceKey: PreferenceKey {
  public static let defaultValue = 0

  public static func reduce(value: inout Int, nextValue: () -> Int) {
    value += nextValue()
  }
}
