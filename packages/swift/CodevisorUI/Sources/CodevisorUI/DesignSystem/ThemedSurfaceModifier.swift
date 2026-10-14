import SwiftUI

public enum ThemedSurfaceRole {
  case sidebar
  case popover
  case sheet
}

public struct ThemedSurfaceModifier<S: Shape>: ViewModifier {
  @Environment(\.theme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  let role: ThemedSurfaceRole
  let shape: S
  let ignoresSafeArea: Bool

  public func body(content: Content) -> some View {
    if theme.isSystem {
      switch role {
      case .sidebar:
        content.background { extended(shape.fill(.regularMaterial)) }
      case .popover:
        content.background { extended(shape.fill(theme.popoverBackground)) }
      case .sheet:
        content
      }
    } else if reduceTransparency {
      content.background { extended(shape.fill(opaqueColor)) }
    } else {
      content.background {
        extended(
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(opaqueColor.opacity(theme.chromeTintAlpha))
          }
        )
      }
    }
  }

  private var opaqueColor: Color {
    switch role {
    case .sidebar:
      theme.sidebarTint ?? .clear
    case .popover, .sheet:
      theme.popoverTint ?? .clear
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

  public func themedCardShadow(_ theme: Theme) -> some View {
    shadow(color: .black.opacity(theme.isSystem ? 0 : 0.07), radius: 8, y: 8)
      .shadow(color: .black.opacity(theme.isSystem ? 0 : 0.05), radius: 2, y: 2)
  }

  #if os(macOS)
    @ViewBuilder
    public func settingsActionTint(_ theme: Theme) -> some View {
      if theme.isSystem {
        self
      } else {
        tint(theme.textPrimary)
      }
    }
  #endif
}
