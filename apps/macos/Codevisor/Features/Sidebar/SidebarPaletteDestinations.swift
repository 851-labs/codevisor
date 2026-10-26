import CodevisorCore
import CodevisorUI

struct SidebarPaletteDestinations {
  let groups: [SidebarWorkspaceGroup]
  let bots: [Bot]
  let rowContent: SidebarRowContent
  let activate: @MainActor (SidebarView.SidebarStop) -> Void

  var items: [CommandPaletteItem] {
    bots.map(botItem) + workspaces.map(workspaceItem)
  }

  private var workspaces: [SidebarWorkspaceListItem] {
    var seen = Set<UUID>()
    let unique = groups.flatMap(\.items).filter { seen.insert($0.id).inserted }
    return unique.compactMap { rowContent.listItem(for: $0) }
  }

  private func workspaceItem(_ item: SidebarWorkspaceListItem) -> CommandPaletteItem {
    let workspace = item.workspace
    let title = SidebarWorkspaceRowLabel.title(for: workspace.name)
    let details = [rowContent.projectName(for: workspace), remoteMachineName(for: workspace)]
      .compactMap { $0 }
      .filter { $0 != title }
    return CommandPaletteItem(
      id: "workspace:\(workspace.id)", title: title,
      subtitle: details.isEmpty ? nil : details.joined(separator: " · "),
      icon: .workspace(rowContent.icon(for: item)), searchTerms: details
    ) { activate(.workspace(item)) }
  }

  private func botItem(_ bot: Bot) -> CommandPaletteItem {
    CommandPaletteItem(id: "bot:\(bot.id)", title: bot.name, icon: .symbol(bot.symbolName)) {
      activate(.bot(bot))
    }
  }

  private func remoteMachineName(for workspace: Workspace) -> String? {
    guard let machine = rowContent.environment.machines.machine(for: workspace.serverId), !machine.isLocal
    else { return nil }
    return machine.name
  }
}
