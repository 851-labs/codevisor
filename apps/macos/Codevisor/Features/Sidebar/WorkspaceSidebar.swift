import SwiftUI

struct WorkspaceSidebar: View {
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true

  var body: some View {
    if FeatureFlag.sidebarRefresh.isEnabled {
      SidebarView(selection: $selection, store: store, publishesSceneActions: publishesSceneActions)
    } else {
      ClassicSidebarView(selection: $selection, store: store, publishesSceneActions: publishesSceneActions)
    }
  }
}
