import CodevisorUI
import SwiftUI

enum ComposerCircleActionEmphasis {
  case primary
  case secondary
  case neutral
}

private struct ComposerCircleActionLabelModifier: ViewModifier {
  let emphasis: ComposerCircleActionEmphasis
  let isEnabled: Bool

  private static let diameter: CGFloat = 30

  private var glyphStyle: Font.TextStyle {
    emphasis == .secondary ? .caption : .subheadline
  }

  private var foreground: AnyShapeStyle {
    guard emphasis == .primary else { return AnyShapeStyle(.secondary) }
    return isEnabled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary.opacity(0.75))
  }

  private var fill: AnyShapeStyle {
    guard emphasis == .primary, isEnabled else { return AnyShapeStyle(Color.secondary.opacity(0.16)) }
    return AnyShapeStyle(Color.accentColor)
  }

  func body(content: Content) -> some View {
    content
      .font(.system(glyphStyle, weight: .bold))
      .scaledFrame(width: Self.diameter, height: Self.diameter, relativeTo: glyphStyle)
      .foregroundStyle(foreground)
      .background(Circle().fill(fill))
      .expandedHitTarget(base: Self.diameter)
  }
}

extension View {
  func composerCircleActionLabel(
    _ emphasis: ComposerCircleActionEmphasis,
    isEnabled: Bool = true
  ) -> some View {
    modifier(ComposerCircleActionLabelModifier(emphasis: emphasis, isEnabled: isEnabled))
  }
}
