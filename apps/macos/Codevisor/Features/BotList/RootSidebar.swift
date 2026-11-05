import CodevisorCore
import CodevisorUI
import SwiftUI

struct RootSidebar: View {
  let navigation: SidebarNavigation
  let store: SessionStore?
  let revealRequest: SidebarRevealRequest
  var publishesSceneActions = true
  var isDrawer = false
  @Environment(AppEnvironment.self) private var environment
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var visibleColumnWidth: CGFloat = 0
  @State private var modePickerWidth: CGFloat?
  @State private var visitedModes: Set<SidebarMode> = []
  @State private var parkedMode: SidebarMode?
  @State private var parkedSelection: SidebarSelection?
  @State private var botEditor: BotEditorTarget?

  private var activeMode: SidebarMode { SidebarMode.active(storedMode, botsEnabled: botsEnabled) }

  var body: some View {
    layout
      .modifier(
        PaletteDestinationsPublisher(
          selection: navigation.committed, store: store, revealRequest: revealRequest, isEnabled: publishesSceneActions)
      )
      .focusedSceneValue(\.rootSidebarActions, sceneActions)
      .background {
        if !isDrawer {
          SplitColumnExtentReader { visibleColumnWidth = $0 }.frame(width: 0, height: 0)
        }
      }
      .navigationSplitViewColumnWidth(min: Self.minimumWidth, ideal: 270, max: 360)
      .toolbar {
        if showsToolbarModePicker {
          ToolbarItem {
            SidebarModePicker(mode: $storedMode, help: SidebarModeShortcut.help)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.width
              } action: {
                modePickerWidth = $0
              }
          }
        }
      }
  }

  private var sceneActions: RootSidebarActions? {
    guard publishesSceneActions, store != nil else { return nil }
    return RootSidebarActions(newChat: openNewChat, newBot: canCreateBots ? openNewBot : nil)
  }

  private var canCreateBots: Bool { botsEnabled && !environment.bots.botMachines.isEmpty }

  private func openNewChat() {
    navigation.go(to: .newChat(nil))
    storedMode = .code
  }

  private func openNewBot() {
    storedMode = .chat
    botEditor = .create
  }

  private var showsToolbarModePicker: Bool {
    botsEnabled && !isDrawer && visibleColumnWidth >= widthFittingModePicker
  }

  private static let minimumWidth = sidebarWidthFitting(pickerWidth: nil, showsWindowControls: true)

  private var widthFittingModePicker: CGFloat {
    Self.sidebarWidthFitting(pickerWidth: modePickerWidth, showsWindowControls: !panelLayout.isFullScreen)
  }

  private static func sidebarWidthFitting(pickerWidth: CGFloat?, showsWindowControls: Bool) -> CGFloat {
    let windowControls: CGFloat = 92
    let fullScreenLeadingInset: CGFloat = 6
    let fallbackPickerWidth: CGFloat = 112
    let toolbarItemPadding: CGFloat = 4
    let sidebarToggle: CGFloat = 44
    let trailingInset: CGFloat = 4
    return (showsWindowControls ? windowControls : fullScreenLeadingInset) + toolbarItemPadding
      + (pickerWidth ?? fallbackPickerWidth) + toolbarItemPadding + sidebarToggle + trailingInset
  }

  @ViewBuilder
  private var layout: some View {
    if isDrawer && botsEnabled {
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
            .allowsHitTesting(mode == activeMode)
            .environment(\.isActiveSidebarMode, mode == activeMode)
        }
      }
    }
    .onChange(of: activeMode, initial: true) { _, mode in
      visitedModes.insert(mode)
      parkedSelection = navigation.committed.wrappedValue
      parkedMode = SidebarMode.allCases.first { $0 != mode }
    }
  }

  private func isMounted(_ mode: SidebarMode) -> Bool {
    mode == activeMode || (botsEnabled && visitedModes.contains(mode))
  }

  private func listNavigation(for mode: SidebarMode) -> SidebarNavigation {
    guard mode != activeMode && mode == parkedMode else { return navigation }
    return SidebarNavigation(committed: $parkedSelection)
  }

  @ViewBuilder
  private func modeList(_ mode: SidebarMode) -> some View {
    switch mode {
    case .chat:
      BotListSidebar(
        selection: listNavigation(for: mode).selection, botEditor: $botEditor, store: store,
        publishesSceneActions: publishesSceneActions
      )
      .modifier(SidebarModeLayer(isActive: mode == activeMode))
    case .code:
      SidebarView(
        navigation: listNavigation(for: mode), store: store, publishesSceneActions: publishesSceneActions,
        revealRequest: revealRequest)
    }
  }
}
