import SwiftUI

/// Shared Liquid Glass treatment for the functional surfaces clustered around
/// the composer. Keeping the material and geometry here prevents pinned
/// controls from drifting back to opaque, independently styled cards.
public enum ComposerGlassStyle {
  public static let composerCornerRadius: CGFloat = 16
  public static let accessoryCornerRadius: CGFloat = 12
  public static let clusterSpacing: CGFloat = 8
}

/// Stable identities for every Liquid Glass shape in the session's bottom
/// chrome. SwiftUI uses these within one namespace to preserve the correct
/// material geometry as nearby surfaces appear, disappear, and resize.
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
    modifier(
      ComposerGlassSurfaceModifier(
        cornerRadius: cornerRadius,
        id: id,
        namespace: namespace,
        transition: transition
      )
    )
  }
}

private struct ComposerGlassSurfaceModifier: ViewModifier {
  let cornerRadius: CGFloat
  let id: ComposerGlassElement?
  let namespace: Namespace.ID?
  let transition: GlassEffectTransition

  @ViewBuilder
  func body(content: Content) -> some View {
    if let id, let namespace {
      content
        .glassEffect(
          .regular,
          in: RoundedRectangle(cornerRadius: cornerRadius)
        )
        // The project defaults declarations to MainActor. Passing the
        // raw String gives this nonisolated API a standard-library
        // Hashable & Sendable identity without actor-bound conformance.
        .glassEffectID(id.rawValue, in: namespace)
        .glassEffectTransition(transition)
    } else {
      content
        .glassEffect(
          .regular,
          in: RoundedRectangle(cornerRadius: cornerRadius)
        )
    }
  }
}
