import CodevisorUI
import SwiftUI

struct SidebarTabRow: View {
  struct Actions {
    let close: () -> Void
    let keep: () -> Void
  }

  let label: WorkspaceTabLabel
  let isSelected: Bool
  let isReordering: Bool
  let onSelect: () -> Void
  var actions: Actions? = nil

  var body: some View {
    HoverableRow(isSelected: isSelected, isHoverEnabled: !isReordering) { isHovered in
      HStack(spacing: SidebarWorkspaceRow.trailingSpacing) {
        SidebarTabRowLabel(label: label)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .onSidebarRowPress(perform: onSelect)
          .simultaneousGesture(TapGesture(count: 2).onEnded { actions?.keep() })
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
          .accessibilityAction(.default, onSelect)
          .accessibilityActions { accessibilityActions }
        trailingAccessory(isHovered: isHovered)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu { contextMenu }
  }

  @ViewBuilder
  private func trailingAccessory(isHovered: Bool) -> some View {
    if isHovered, let actions {
      SidebarRowHoverButton(
        systemImage: "xmark", help: "Close tab", accessibilityLabel: "Close \(label.title)", action: actions.close)
    } else if label.isSplit {
      Image(systemName: "rectangle.split.2x1")
        .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
        .foregroundStyle(.secondary)
        .frame(width: SidebarRowIcon.trailingSlot, height: SidebarRowIcon.trailingSlot)
        .help("Split")
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var contextMenu: some View {
    if let actions {
      Button(action: actions.close) {
        Label("Close Tab", systemImage: "xmark")
          .labelStyle(.titleAndIcon)
      }
      .shortcut(.closeSplit)
    }
  }

  @ViewBuilder
  private var accessibilityActions: some View {
    if let actions {
      Button("Close", action: actions.close)
    }
  }
}

struct SidebarTabRowLabel: View {
  let label: WorkspaceTabLabel

  var body: some View {
    HStack(spacing: 7) {
      label.icon
        .font(.system(size: SidebarRowIcon.size, weight: SidebarRowIcon.weight))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .help(label.icon.help)
      Text(label.title)
        .italic(label.isPreview)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(.primary)
    .accessibilityElement(children: .combine)
  }
}
