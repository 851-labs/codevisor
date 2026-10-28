import SwiftUI

struct SidebarModeSceneActions<Actions>: ViewModifier {
  @Environment(\.isActiveSidebarMode) private var isActiveMode
  let key: WritableKeyPath<FocusedValues, Actions?>
  let actions: Actions?
  let store: SessionStore?
  let stepHandlerOwner: UUID
  let step: (Int) -> Void

  private var stepHandlerStore: SessionStore? { isActiveMode ? store : nil }

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(key, isActiveMode ? actions : nil)
      .task(id: stepHandlerStore.map(ObjectIdentifier.init)) {
        stepHandlerStore?.setWorkspaceStepHandler(owner: stepHandlerOwner, step)
      }
  }
}
