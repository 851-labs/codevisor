import SwiftUI

public struct TranscriptDisclosureChevron: View {
  static let side: CGFloat = 10

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let expanded: Bool

  public init(expanded: Bool) {
    self.expanded = expanded
  }

  @ViewBuilder
  public var body: some View {
    Image(systemName: "chevron.right")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.tertiary)
      .frame(width: Self.side, height: Self.side)
      .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
        chevron.rotationEffect(.degrees(expanded ? 90 : 0))
      }
  }
}
