import CodevisorCore
import CodevisorUI
import SwiftUI

struct PaletteDestinationsPublisher: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var selection: SidebarSelection?
  let store: SessionStore?
  let revealRequest: SidebarRevealRequest
  let isEnabled: Bool
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var grouping
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  @ClientPreference(SidebarPreferenceKey.machineOrder, default: []) private var machineOrder: [String]
  @ClientPreference(SidebarPreferenceKey.projectOrder, default: []) private var projectOrder: [String]

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.paletteDestinations, isEnabled && store != nil ? destinations : nil)
  }

  private var destinations: PaletteDestinations {
    PaletteDestinations(bots: { botItems }, workspaces: { workspaceItems })
  }

  private var botItems: [CommandPaletteItem] {
    guard botsEnabled else { return [] }

    return BotConversationList(environment: environment, store: store).conversations().map { conversation in
      let bot = conversation.bot
      return CommandPaletteItem(id: "bot:\(bot.id)", title: bot.name, icon: .symbol(bot.symbolName)) {
        selection = .bot(serverId: bot.serverId, id: bot.id)
      }
    }
  }

  private var workspaceItems: [CommandPaletteItem] {
    SidebarPaletteDestinations(
      groups: listing.groups,
      rowContent: SidebarRowContent(
        environment: environment, store: store, grouping: grouping,
        rowDetails: ClientPreferences.shared.sidebarRowDetails),
      activate: activate
    ).items
  }

  private var listing: SidebarWorkspaceListing {
    SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: pinnedWorkspaceIDs,
      machineOrder: machineOrder, projectOrder: projectOrder)
  }

  private func activate(_ item: SidebarWorkspaceListItem) {
    revealRequest.rowID = item.workspace.id
    SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection).activate(item)
  }
}
