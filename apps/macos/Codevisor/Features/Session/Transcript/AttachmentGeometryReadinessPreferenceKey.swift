import SwiftUI

/// Aggregates unresolved, layout-affecting attachment geometry through a
/// hosted transcript row. The native presentation gate consumes this before
/// accepting the row's measured height as final.
struct AttachmentGeometryReadinessPreferenceKey: PreferenceKey {
  static var defaultValue = 0

  static func reduce(value: inout Int, nextValue: () -> Int) {
    value += nextValue()
  }
}
