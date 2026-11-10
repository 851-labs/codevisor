import AppKit
import SwiftUI

struct WorkspaceInspectorFileSelectionBackground: View {
  struct Look: Equatable {
    let isEmphasized: Bool
    let joinsPrevious: Bool
    let joinsNext: Bool
  }

  let look: Look
  let gap: CGFloat

  private static let cornerRadius: CGFloat = 6
  private static let dividerInset: CGFloat = 8

  var body: some View {
    UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
      .fill(fill)
      .padding(.bottom, look.joinsNext ? -gap : 0)
      .overlay(alignment: .bottom) {
        if look.joinsNext {
          Rectangle()
            .fill(divider)
            .frame(height: gap)
            .offset(y: gap)
            .padding(.horizontal, Self.dividerInset)
        }
      }
  }

  private var radii: RectangleCornerRadii {
    let top = look.joinsPrevious ? 0 : Self.cornerRadius
    let bottom = look.joinsNext ? 0 : Self.cornerRadius
    return RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top)
  }

  private var fill: Color {
    look.isEmphasized
      ? Color(nsColor: .selectedContentBackgroundColor)
      : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  }

  private var divider: Color {
    look.isEmphasized ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)
  }
}
