import SwiftUI

struct WorkspaceRow: View {
  enum Style {
    case sidebar(isSelected: Bool, isHovered: Bool)
    case card(focusShape: UnevenRoundedRectangle)
  }

  let details: WorkspaceRowDetails
  let store: SessionStore?
  let lifecycle: WorkspaceRowLifecycle
  let style: Style
  let onActivate: () -> Void

  static let trailingSpacing: CGFloat = 7
  static let horizontalInset: CGFloat = 10
  static let archivedOpacity: Double = 0.6

  var body: some View {
    activationTarget
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .contextMenu { WorkspaceRowMenu(lifecycle: lifecycle, unreadChat: details.unreadChat) }
  }

  @ViewBuilder
  private var activationTarget: some View {
    switch style {
    case let .sidebar(isSelected, isHovered):
      WorkspaceRowPressTarget(
        details: details, store: store, lifecycle: lifecycle, isSelected: isSelected, isHovered: isHovered,
        onActivate: onActivate)
    case let .card(focusShape):
      WorkspaceRowButtonTarget(
        details: details, store: store, lifecycle: lifecycle, focusShape: focusShape, onActivate: onActivate)
    }
  }
}

private struct WorkspaceRowPressTarget: View {
  let details: WorkspaceRowDetails
  let store: SessionStore?
  let lifecycle: WorkspaceRowLifecycle
  let isSelected: Bool
  let isHovered: Bool
  let onActivate: () -> Void

  var body: some View {
    HStack(spacing: WorkspaceRow.trailingSpacing) {
      WorkspaceRowLabel(details: details, store: store, isArchived: lifecycle.isArchived)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onSidebarRowPress(perform: onActivate)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(lifecycle.isArchived ? "Archived" : "")
        .accessibilityAction(.default, onActivate)
        .accessibilityActions { WorkspaceRowAccessibilityActions(lifecycle: lifecycle) }
      WorkspaceRowTrailing(details: details, lifecycle: lifecycle, isHovered: isHovered)
    }
    .padding(.horizontal, WorkspaceRow.horizontalInset)
    .overlay(alignment: .trailing) {
      if isHovered {
        WorkspaceRowHoverActions(lifecycle: lifecycle, title: details.title)
          .padding(.trailing, WorkspaceRow.horizontalInset)
      }
    }
  }
}

private struct WorkspaceRowButtonTarget: View {
  let details: WorkspaceRowDetails
  let store: SessionStore?
  let lifecycle: WorkspaceRowLifecycle
  let focusShape: UnevenRoundedRectangle
  let onActivate: () -> Void

  var body: some View {
    Button(action: onActivate) {
      HStack(spacing: WorkspaceRow.trailingSpacing) {
        WorkspaceRowLabel(details: details, store: store, isArchived: lifecycle.isArchived)
        WorkspaceRowProperties(details: details, isArchived: lifecycle.isArchived)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WorkspaceInspectorCardShape.rowPadding)
      .contentShape(Rectangle())
      .contentShape(.focusEffect, focusShape)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Open \(details.title)")
    .accessibilityActions { WorkspaceRowAccessibilityActions(lifecycle: lifecycle) }
  }
}

private struct WorkspaceRowLabel: View {
  let details: WorkspaceRowDetails
  let store: SessionStore?
  let isArchived: Bool

  var body: some View {
    SidebarWorkspaceRowLabel(
      name: details.name, subtitle: details.subtitle, status: details.status, icon: details.icon, store: store
    )
    .opacity(isArchived ? WorkspaceRow.archivedOpacity : 1)
  }
}
