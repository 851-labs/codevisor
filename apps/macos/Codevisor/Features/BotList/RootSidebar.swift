import CodevisorCore
import SwiftUI

struct RootSidebar: View {
  @Binding var selection: SidebarSelection?
  let store: SessionStore?
  var publishesSceneActions = true
  var isDrawer = false
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var revealRequest = SidebarRevealRequest()

  var body: some View {
    layout
      .modifier(
        PaletteDestinationsPublisher(
          selection: $selection, store: store, revealRequest: revealRequest, isEnabled: publishesSceneActions)
      )
      .toolbar {
        if botsEnabled && !isDrawer {
          ToolbarItem { SidebarModePicker(mode: $storedMode) }
        }
      }
  }

  @ViewBuilder
  private var layout: some View {
    if isDrawer && botsEnabled {
      VStack(spacing: 0) {
        SidebarModePicker(mode: $storedMode)
          .controlSize(.large)
          .padding(.top, 10)
        content
      }
    } else {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if SidebarMode.active(storedMode, botsEnabled: botsEnabled) == .chat {
      BotListSidebar(selection: $selection, store: store, publishesSceneActions: publishesSceneActions)
    } else {
      SidebarView(
        selection: $selection, store: store, publishesSceneActions: publishesSceneActions,
        revealRequest: revealRequest)
    }
  }
}
