import CodevisorCore
import CodevisorUI
import SwiftUI

struct RootSidebar: View {
  @Binding var selection: SidebarSelection?
  @Binding var botEditor: BotEditorTarget?
  let store: SessionStore?
  let revealRequest: SidebarRevealRequest
  var publishesSceneActions = true
  var isDrawer = false
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var visitedModes: Set<SidebarMode> = []
  @State private var parkedMode: SidebarMode?
  @State private var parkedSelection: SidebarSelection?

  var body: some View {
    layout
      .modifier(
        PaletteDestinationsPublisher(
          selection: $selection, store: store, revealRequest: revealRequest, isEnabled: publishesSceneActions)
      )
      .modifier(SidebarModeToolbar(isDrawer: isDrawer))
  }

  @ViewBuilder
  private var layout: some View {
    if isDrawer {
      VStack(spacing: 0) {
        DrawerModePicker(mode: $storedMode)
          .padding(.top, 10)
        content
      }
    } else {
      content
    }
  }

  private var content: some View {
    ZStack {
      ForEach(SidebarMode.allCases, id: \.self) { mode in
        if isMounted(mode) {
          modeList(mode)
            .allowsHitTesting(mode == storedMode)
            .environment(\.isActiveSidebarMode, mode == storedMode)
        }
      }
    }
    .onChange(of: storedMode, initial: true) { _, mode in
      visitedModes.insert(mode)
      parkedSelection = selection
      parkedMode = SidebarMode.allCases.first { $0 != mode }
    }
  }

  private func isMounted(_ mode: SidebarMode) -> Bool {
    mode == storedMode || visitedModes.contains(mode)
  }

  private func listSelection(for mode: SidebarMode) -> Binding<SidebarSelection?> {
    mode != storedMode && mode == parkedMode ? $parkedSelection : $selection
  }

  @ViewBuilder
  private func modeList(_ mode: SidebarMode) -> some View {
    switch mode {
    case .bots:
      BotListSidebar(
        selection: listSelection(for: mode), botEditor: $botEditor, store: store,
        publishesSceneActions: publishesSceneActions
      )
      .modifier(SidebarModeLayer(isActive: mode == storedMode))
    case .code:
      SidebarView(
        selection: listSelection(for: mode), store: store, publishesSceneActions: publishesSceneActions,
        revealRequest: revealRequest)
    }
  }
}
