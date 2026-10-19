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
  private func onDelete() { actions.actions.deleteBot(bot.bot) }

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
    .swipeActions(edge: .trailing) {
      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Delete")
      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .tint(.gray)
      .accessibilityLabel("Edit")
    }
    .contextMenu {
      Button(action: onEdit) {
        Label("Edit Bot…", systemImage: "pencil")
      }
      Divider()
      Button(role: .destructive, action: onDelete) {
        Label("Delete Bot…", systemImage: "trash")
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityActions {
      Button("Edit", action: onEdit)
      Button("Delete", action: onDelete)
    }
    .accessibilityIdentifier("sidebar.bot.\(bot.bot.name)")
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
