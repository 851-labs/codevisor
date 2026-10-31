import SwiftUI

struct SidebarHeadingFrameRecorder: ViewModifier {
  let id: String
  let geometry: SidebarDragGeometryStore

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(SidebarView.reorderSpace))
      } action: { frame in
        geometry.headings[id] = frame
      }
      .onDisappear { geometry.headings[id] = nil }
  }
}
