import SwiftUI

nonisolated enum RowSelectionStyle {
  static let cornerRadius: CGFloat = 8.5
  static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

  static func fill(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return Color.primary.opacity(0.14) }
    return isHovered ? Color.secondary.opacity(0.12) : .clear
  }
}
