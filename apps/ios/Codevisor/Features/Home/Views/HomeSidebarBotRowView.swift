import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarBotRowView: View, Equatable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let bot: HomeSidebarBot
  let actions: HomeSidebarActionHandler
  var isSelectionRow = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bot == rhs.bot && lhs.actions === rhs.actions && lhs.isSelectionRow == rhs.isSelectionRow
  }

  private func onOpen() { actions.actions.openBot(bot.bot) }
  private func onEdit() { actions.actions.editBot(bot.bot) }
  private func onArchive() { actions.actions.archiveBot(bot.bot) }
  private func onUnarchive() { actions.actions.unarchiveBot(bot.bot) }
  private func onDelete() { actions.actions.deleteBot(bot.bot) }

  private var isArchived: Bool { bot.bot.isArchived }

  var body: some View {
    HStack(spacing: 10) {
      if isSelectionRow {
        label
      } else {
        Button(action: onOpen) { label }
          .buttonStyle(.plain)
      }
      if let machine = bot.machine {
        HomeSidebarSymbol(name: machine.systemImage)
          .imageScale(.small)
      }
      if !bot.hasNestedRows {
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .opacity(isArchived ? 0.6 : 1)
    .swipeActions(edge: .trailing) { swipeButtons }
    .contextMenu { menu }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isArchived ? "Archived" : "")
    .accessibilityActions { accessibilityButtons }
    .accessibilityIdentifier("sidebar.bot.\(bot.bot.name)")
  }

  private var offersArchive: Bool { bot.canArchive && !isArchived }

  @ViewBuilder
  private var swipeButtons: some View {
    if isArchived {
      Button(action: onUnarchive) {
        Image(systemName: "arrow.uturn.backward")
      }
      .tint(.blue)
      .accessibilityLabel("Unarchive")
      deleteSwipe
    } else {
      if offersArchive {
        Button(action: onArchive) {
          Image(systemName: "archivebox")
        }
        .tint(.indigo)
        .accessibilityLabel("Archive")
      } else {
        deleteSwipe
      }
      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .tint(.gray)
      .accessibilityLabel("Edit")
    }
  }

  @ViewBuilder
  private var menu: some View {
    if isArchived {
      Button(action: onUnarchive) {
        Label("Unarchive", systemImage: "arrow.uturn.backward")
      }
    } else {
      Button(action: onEdit) {
        Label("Edit", systemImage: "pencil")
      }
    }
    Divider()
    if offersArchive {
      Button(action: onArchive) {
        Label("Archive", systemImage: "archivebox")
      }
    } else {
      Button(role: .destructive, action: onDelete) {
        Label("Delete…", systemImage: "trash")
      }
    }
  }

  @ViewBuilder
  private var accessibilityButtons: some View {
    if isArchived {
      Button("Unarchive", action: onUnarchive)
    } else {
      Button("Edit", action: onEdit)
    }
    if offersArchive {
      Button("Archive", action: onArchive)
    } else {
      Button("Delete", action: onDelete)
    }
  }

  private var deleteSwipe: some View {
    Button(role: .destructive, action: onDelete) {
      Image(systemName: "trash")
    }
    .accessibilityLabel("Delete")
  }

  private var label: some View {
    Label {
      HomeSidebarRowTitle(title: bot.bot.name)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    } icon: {
      if bot.status == .idle {
        HomeSidebarSymbol(name: bot.bot.symbolName)
      } else {
        HomeStatusIndicator(status: bot.status)
      }
    }
    .contentShape(Rectangle())
  }

  private var accessibilityLabel: String {
    let status = bot.status == .idle ? nil : bot.status.caption.lowercased()
    return [bot.bot.name, "bot", status, bot.machine.map { "on \($0.name)" }].compactMap { $0 }.joined(separator: ", ")
  }
}
