import SwiftUI

public struct ContentLayoutReadinessPreferenceKey: PreferenceKey {
  public static let defaultValue = 0

  public static func reduce(value: inout Int, nextValue: () -> Int) {
    value += nextValue()
  }
}
