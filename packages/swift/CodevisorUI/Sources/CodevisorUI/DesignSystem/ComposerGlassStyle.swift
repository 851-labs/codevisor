import SwiftUI

public enum ComposerGlassStyle {
  public static let clusterSpacing: CGFloat = 8
}

public enum ComposerGlassElement: String, Hashable {
  case composer
  case todos
  case goal
  case queue
  case commandPalette
  case scrollToBottom
  case newChatConfiguration
}

extension View {
  public func composerGlassSurface(
    cornerRadius: CGFloat,
    id: ComposerGlassElement? = nil,
    in namespace: Namespace.ID? = nil,
    transition: GlassEffectTransition = .matchedGeometry
  ) -> some View {
    composerGlassSurface(
      shape: RoundedRectangle(cornerRadius: cornerRadius),
      id: id,
      in: namespace,
      transition: transition
    )
  }

  public func composerGlassSurface<S: Shape>(
    shape: S,
    id: ComposerGlassElement? = nil,
    in namespace: Namespace.ID? = nil,
    transition: GlassEffectTransition = .matchedGeometry
  ) -> some View {
    modifier(
      ComposerGlassSurfaceModifier(
        shape: shape,
        id: id,
        namespace: namespace,
        transition: transition
      )
    )
  }
}

private struct ComposerGlassSurfaceModifier<S: Shape>: ViewModifier {
  let shape: S
  let id: ComposerGlassElement?
  let namespace: Namespace.ID?
  let transition: GlassEffectTransition

  func body(content: Content) -> some View {
    glass(content.contentShape(shape))
  }

  @ViewBuilder
  private func glass(_ content: some View) -> some View {
    if let id, let namespace {
      content
        .glassEffect(
          .regular,
          in: shape
        )
        .glassEffectID(id.rawValue, in: namespace)
        .glassEffectTransition(transition)
    } else {
      content
        .glassEffect(
          .regular,
          in: shape
        )
    }
  }
}
