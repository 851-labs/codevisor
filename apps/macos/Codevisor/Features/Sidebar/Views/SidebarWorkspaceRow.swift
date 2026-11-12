import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceRow: View {
  let details: WorkspaceRowDetails
  let store: SessionStore?
  let isSelected: Bool
  let isReordering: Bool
  let onActivate: () -> Void
  let lifecycle: WorkspaceRowLifecycle

  var body: some View {
    HoverableRow(isSelected: isSelected, isHoverEnabled: !isReordering) { isHovered in
      WorkspaceRow(
        details: details, store: store, lifecycle: lifecycle,
        style: .sidebar(isSelected: isSelected, isHovered: isHovered), onActivate: onActivate)
    }
  }
}

struct SidebarWorkspaceRowLabel: View {
  let name: String
  var subtitle: String? = nil
  var status: SidebarRowStatus? = nil
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  var body: some View {
    HStack(spacing: 7) {
      SidebarWorkspaceLeadingIcon(icon: icon, store: store, status: status)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title(for: name))
          .lineLimit(1)
        if subtitle != nil || status != nil {
          SidebarWorkspaceRowSubtitle(subtitle: subtitle, status: status)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(.primary)
    .accessibilityElement(children: .combine)
  }
}

struct SidebarRowMachine: Equatable {
  let name: String
  let systemImage: String
}

enum SidebarWorkspaceIcon: Equatable {
  case chat(ChatSession, isQuiet: Bool = false)
  case workingTerminal
  case workspace
}

enum SidebarRowIcon {
  static let size: CGFloat = 13
  static let trailingSize: CGFloat = 12
  static let trailingSlot: CGFloat = 16
  static let weight: Font.Weight = .regular
}
