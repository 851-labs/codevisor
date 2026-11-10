import SwiftUI

struct WorkspaceInspectorFileTreeFold: ViewModifier, Animatable {
  var progress: CGFloat
  let index: Int
  let count: Int

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let height = WorkspaceInspectorFileTreeRow.height + WorkspaceInspectorFileTreeRow.spacing
    let visible = min(height, max(0, progress * CGFloat(count) * height - CGFloat(index) * height))
    content
      .frame(height: visible, alignment: .top)
      .clipped()
      .opacity(progress)
  }
}
