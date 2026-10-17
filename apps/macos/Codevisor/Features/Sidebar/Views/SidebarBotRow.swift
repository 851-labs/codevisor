import CodevisorCore
import SwiftUI

struct SidebarBotRow: View {
  let title: String
  let icon: SidebarBotIcon
  let isSelected: Bool
  let isHoverEnabled: Bool
  let isExpanded: Bool?
  let onSelect: () -> Void
  let onToggle: () -> Void
  @State private var isHovered = false

  private var showsChevron: Bool { isExpanded != nil && isHovered && isHoverEnabled }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        icon
          .opacity(showsChevron ? 0 : 1)
        Button(action: onToggle) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded == true ? 90 : 0))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsChevron ? 1 : 0)
        .allowsHitTesting(showsChevron)
        .help(isExpanded == true ? "Collapse \(title)" : "Expand \(title)")
        .accessibilityHidden(true)
      }
      .frame(width: 18)
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .sidebarRowHover(isSelected: isSelected, isEnabled: isHoverEnabled)
    .onHover { isHovered = $0 }
    .onTapGesture(perform: onSelect)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityValue(isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    .accessibilityAction(.default, onSelect)
    .accessibilityActions {
      if let isExpanded { Button(isExpanded ? "Collapse" : "Expand", action: onToggle) }
    }
  }
}

struct SidebarBotIcon: View {
  let bot: Bot
  let store: SessionStore?
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    if let chat = urgentChat {
      ChatSessionLeadingIcon(
        session: chat, store: store, activityColor: .secondary, iconSize: SidebarRowIcon.size
      )
      .foregroundStyle(.secondary)
    } else {
      Image(systemName: bot.symbolName)
        .foregroundStyle(.secondary)
    }
  }

  private var urgentChat: ChatSession? {
    let list = environment.projectList
    let status = SidebarChatStatus(list: list, store: store)
    let workspace = environment.navigationStore.workspaceEntries.entry(bot.workspaceId).workspace
    let chats =
      [list.session(bot.sessionId, serverId: bot.serverId)].compactMap { $0 }
      + (workspace.map(status.chats(in:)) ?? []).filter { $0.id != bot.sessionId }
    return status.urgentChat(among: chats)
  }
}
