import SwiftUI

nonisolated enum SetupRequestCardMetrics {
  static let bubbleTrailingInset: CGFloat = 40
  static let resolvedVerticalPadding: CGFloat = 8
  static let actionSpacing: CGFloat = 12

  #if os(iOS)
    static let maxWidth: CGFloat = 560
  #else
    static let maxWidth: CGFloat = 520
  #endif
}
