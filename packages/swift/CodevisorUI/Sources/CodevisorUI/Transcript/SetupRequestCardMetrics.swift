import SwiftUI

nonisolated enum SetupRequestCardMetrics {
  static let bubbleTrailingInset: CGFloat = 40
  static let actionSpacing: CGFloat = 12
  static let resolvedVerticalPadding: CGFloat = 8

  #if os(iOS)
    static let maxWidth: CGFloat = 560
    static let controlSize: ControlSize = .large
  #else
    static let maxWidth: CGFloat = 520
    static let controlSize: ControlSize = .regular
  #endif
}
