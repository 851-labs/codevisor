import SwiftUI

struct SidebarModeNewButtonStyle: PrimitiveButtonStyle {
  private static let glyphSize: CGFloat = 16

  func makeBody(configuration: Configuration) -> some View {
    Button(role: configuration.role, action: configuration.trigger) {
      configuration.label
        .imageScale(.large)
        .frame(width: Self.glyphSize, height: Self.glyphSize)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.extraLarge)
  }
}
