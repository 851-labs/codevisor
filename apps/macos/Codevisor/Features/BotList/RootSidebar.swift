import CodevisorCore
import SwiftUI

struct RootSidebar: View {
  @Binding var selection: SidebarSelection?
  let store: SessionStore?
  var publishesSceneActions = true
  var isDrawer = false
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var revealRequest = SidebarRevealRequest()
  @State private var visibleColumnWidth: CGFloat = 0
  @State private var modePickerWidth: CGFloat?

  var body: some View {
    layout
      .modifier(
        PaletteDestinationsPublisher(
          selection: $selection, store: store, revealRequest: revealRequest, isEnabled: publishesSceneActions)
      )
      .background {
        if !isDrawer {
          SplitColumnExtentReader { visibleColumnWidth = $0 }.frame(width: 0, height: 0)
        }
      }
      .navigationSplitViewColumnWidth(min: Self.minimumWidth, ideal: 270, max: 360)
      .toolbar {
        if showsToolbarModePicker {
          ToolbarItem {
            SidebarModePicker(mode: $storedMode)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.width
              } action: {
                modePickerWidth = $0
              }
          }
        }
      }
  }

  private var showsToolbarModePicker: Bool {
    botsEnabled && !isDrawer && visibleColumnWidth >= widthFittingModePicker
  }

  private static let minimumWidth = SidebarModePicker.sidebarWidthFitting(pickerWidth: nil, showsWindowControls: true)

  private var widthFittingModePicker: CGFloat {
    SidebarModePicker.sidebarWidthFitting(pickerWidth: modePickerWidth, showsWindowControls: !panelLayout.isFullScreen)
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
