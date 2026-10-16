import SwiftUI

public enum ThemedSurfaceRole {
  case sidebar
  case popover
}

public struct ThemedSurfaceModifier<S: Shape>: ViewModifier {
  let role: ThemedSurfaceRole
  let shape: S
  let ignoresSafeArea: Bool

  public func body(content: Content) -> some View {
    switch role {
    case .sidebar:
      content.background { extended(shape.fill(.regularMaterial)) }
    case .popover:
      content.background { extended(shape.fill(Color.windowBackgroundColor)) }
    }
  }

  @ViewBuilder
  private func extended(_ view: some View) -> some View {
    if ignoresSafeArea {
      view.ignoresSafeArea()
    } else {
      view
    }
  }
}

extension View {
  public func themedSurface(_ role: ThemedSurfaceRole) -> some View {
    modifier(ThemedSurfaceModifier(role: role, shape: Rectangle(), ignoresSafeArea: true))
  }

  public func themedSurface(_ role: ThemedSurfaceRole, in shape: some Shape) -> some View {
    modifier(ThemedSurfaceModifier(role: role, shape: shape, ignoresSafeArea: false))
  }
}
