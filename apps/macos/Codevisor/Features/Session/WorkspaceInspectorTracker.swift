import SwiftUI

struct WorkspaceInspectorTracker: View {
  let actions: () -> WorkspaceInspectorActions?
  @Binding var inspects: Bool

  var body: some View {
    let actions = actions()
    Color.clear
      .onChange(of: actions != nil, initial: true) { _, inspects in self.inspects = inspects }
      .focusedSceneValue(\.workspaceInspector, actions)
  }
}
