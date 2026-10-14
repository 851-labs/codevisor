import SwiftUI

private struct StreamMarkdownTextLayoutWidthKey: EnvironmentKey {
  static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
  public var streamMarkdownTextLayoutWidth: CGFloat? {
    get { self[StreamMarkdownTextLayoutWidthKey.self] }
    set { self[StreamMarkdownTextLayoutWidthKey.self] = newValue }
  }
}

enum StreamMarkdownTextLayout {
  static func resolvedWidth(
    proposalWidth: CGFloat?,
    rowLayoutWidth: CGFloat?,
    fillsWidth: Bool,
    naturalWidth: @autoclosure () -> CGFloat
  ) -> CGFloat {
    var availableWidth: CGFloat?
    for candidate in [proposalWidth, rowLayoutWidth] {
      guard let candidate, candidate.isFinite, candidate > 0 else { continue }
      availableWidth = availableWidth.map { min($0, candidate) } ?? candidate
    }
    if fillsWidth, let availableWidth {
      return max(1, availableWidth)
    }
    let naturalWidth = naturalWidth()
    return min(max(1, availableWidth ?? naturalWidth), naturalWidth)
  }
}
