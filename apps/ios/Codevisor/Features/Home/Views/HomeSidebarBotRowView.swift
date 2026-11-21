import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarBotRowView: View, Equatable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var mascotSize: CGFloat = 24

  let bot: HomeSidebarBot
  let actions: HomeSidebarActionHandler
  var isSelectionRow = false
  var isOpen = false
  var isConversation = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bot == rhs.bot && lhs.actions === rhs.actions && lhs.isSelectionRow == rhs.isSelectionRow
      && lhs.isOpen == rhs.isOpen && lhs.isConversation == rhs.isConversation
  }

  private func onOpen() { actions.actions.openBot(bot.bot) }
  private func onEdit() { actions.actions.editBot(bot.bot) }
  private func onFork() { actions.actions.forkBot(bot.bot) }
  private func onArchive() { actions.actions.archiveBot(bot.bot) }
  private func onUnarchive() { actions.actions.unarchiveBot(bot.bot) }
  private func onDelete() { actions.actions.deleteBot(bot.bot) }

  private var isArchived: Bool { bot.bot.isArchived }

  var body: some View {
    content
      .opacity(isArchived ? 0.6 : 1)
      .swipeActions(edge: .trailing) { swipeButtons }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(isArchived ? "Archived" : "")
      .accessibilityActions { accessibilityButtons }
      .accessibilityIdentifier("sidebar.bot.\(bot.bot.name)")
  }

  @ViewBuilder
  private var content: some View {
    if isConversation {
      openable(HomeSidebarBotConversationLabel(bot: bot, isOpen: isOpen, showsChevron: !bot.hasNestedRows))
        .buttonStyle(.plain)
    } else {
      openable(compactRow)
    }
  }

  private var compactRow: some View {
    HStack(spacing: 10) {
      label
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
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func openable(_ row: some View) -> some View {
    if isSelectionRow {
      row
    } else {
      Button(action: onOpen) { row }
    }
  }

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
      Button(action: onArchive) {
        Image(systemName: "archivebox")
      }
      .tint(.indigo)
      .accessibilityLabel("Archive")
      Button(action: onEdit) {
        Image(systemName: "pencil")
      }
      .tint(.gray)
      .accessibilityLabel("Edit")
    }
  }

  @ViewBuilder
  private var accessibilityButtons: some View {
    if isArchived {
      Button("Unarchive", action: onUnarchive)
    } else {
      Button("Edit", action: onEdit)
      Button("Fork", action: onFork)
    }
    if isArchived {
      Button("Delete", action: onDelete)
    } else {
      Button("Archive", action: onArchive)
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
      if showsStatus {
        HomeStatusIndicator(status: bot.status)
      } else if let mascot = bot.bot.mascot {
        BotMascotFigure(bot: bot.bot, mascot: mascot, slot: mascotSize)
      } else {
        HomeSidebarSymbol(name: bot.bot.symbolName)
      }
    }
  }

  private var showsStatus: Bool {
    switch bot.status {
    case .idle: false
    case .inProgress: bot.bot.mascot == nil
    case .error, .actionRequired, .unread: true
    }
  }

  private var accessibilityLabel: String {
    let status = bot.status == .idle ? nil : bot.status.caption.lowercased()
    let preview = isConversation ? bot.conversation.preview : nil
    return [bot.bot.name, "bot", status, bot.machine.map { "on \($0.name)" }, preview].compactMap { $0 }
      .joined(separator: ", ")
  }
}
