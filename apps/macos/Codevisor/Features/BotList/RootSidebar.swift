import CodevisorCore
import SwiftUI

struct RootSidebar: View {
  @Binding var selection: SidebarSelection?
  let store: SessionStore?
  var publishesSceneActions = true
  var isDrawer = false
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  var body: some View {
    content
      .toolbar {
        if botsEnabled && !isDrawer {
          ToolbarItem { SidebarModePicker(mode: $storedMode) }
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if SidebarMode.active(storedMode, botsEnabled: botsEnabled) == .chat {
      BotListSidebar(selection: $selection, store: store, publishesSceneActions: publishesSceneActions)
    } else {
      SidebarView(selection: $selection, store: store, publishesSceneActions: publishesSceneActions)
    }
  }
}
