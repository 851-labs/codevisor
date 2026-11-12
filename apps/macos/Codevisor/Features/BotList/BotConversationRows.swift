import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers

struct BotConversationRows: View {
  let rows: [BotSidebarRow]
  let sections: [CustomSection]
  let selectedBotID: UUID?
  var statuses: SidebarRowStatuses? = nil
  let actions: BotSidebarRowActions
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var reorder = BotRowReorder()
  @State private var draggedSection: UUID?
  @State private var sectionDropTarget: UUID?

  var body: some View {
    SidebarRowList(rows: rows, id: \.placedID, spacing: 2, animation: Motion.listReflow(reduceMotion: reduceMotion)) {
      row($0)
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(BotRowReorder.space))
        } action: { [id = $0.id] frame in
          reorder.frames[id] = frame
        }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .coordinateSpace(.named(BotRowReorder.space))
    .overlay(alignment: .topLeading) { BotRowReorderOverlay(reorder: reorder, rows: rows) }
  }

  @ViewBuilder
  private func row(_ row: BotSidebarRow) -> some View {
    switch row.kind {
    case let .bot(conversation, section):
      botRow(conversation, section: section)
    case let .section(section, isExpanded):
      sectionHeader(section, isExpanded: isExpanded)
    case let .archivedSection(isExpanded):
      SidebarSectionHeader(title: "Archived", isExpanded: isExpanded, onToggle: actions.toggleArchived)
    case let .archivedBot(conversation):
      archivedBotRow(conversation)
    }
  }

  private func botRow(_ conversation: BotConversation, section: UUID?) -> some View {
    let bot = conversation.bot
    let status = statuses?.status(of: bot.workspaceId)
    return BotConversationRow(conversation: conversation, isSelected: bot.id == selectedBotID, status: status)
      .opacity(reorder.isDragging(bot.id) ? 0.4 : 1)
      .onSidebarRowPress { open(bot, status: status) }
      .accessibilityAction(.default) { open(bot, status: status) }
      .simultaneousGesture(reorderGesture(for: bot))
      .contextMenu {
        if let chat = chat(of: bot) {
          ChatSessionUnreadMenuItem(session: chat)
          Divider()
        }
        Button {
          actions.edit(bot)
        } label: {
          Label("Edit", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        if actions.canFork(bot) {
          Button {
            actions.fork(bot)
          } label: {
            Label("Fork…", systemImage: "arrow.triangle.branch")
              .labelStyle(.titleAndIcon)
          }
        }
        Divider()
        MoveToSectionMenu(
          currentSectionID: section, sections: sections, move: { actions.moveBot(bot.id, $0) },
          newSection: { actions.newSection(bot) })
        Divider()
        if actions.canArchive(bot) {
          Button {
            actions.archive(bot)
          } label: {
            Label("Archive", systemImage: "archivebox")
              .labelStyle(.titleAndIcon)
          }
          .shortcut(.archiveWorkspace)
        } else {
          deleteButton(bot)
        }
      }
      .id(bot.id)
  }

  private func archivedBotRow(_ conversation: BotConversation) -> some View {
    let bot = conversation.bot
    return BotConversationRow(conversation: conversation, isSelected: bot.id == selectedBotID)
      .opacity(0.6)
      .onSidebarRowPress { actions.select(bot) }
      .accessibilityAction(.default) { actions.select(bot) }
      .accessibilityValue("Archived")
      .contextMenu {
        Button {
          actions.unarchive(bot)
        } label: {
          Label("Unarchive", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
        Divider()
        deleteButton(bot)
      }
      .id(bot.id)
  }

  private func open(_ bot: Bot, status: SidebarRowStatus?) {
    guard let agent = status?.askingWorkspaceID, agent != bot.workspaceId else { return actions.select(bot) }
    actions.openAgent(agent)
  }

  private func chat(of bot: Bot) -> ChatSession? {
    environment.projectList.session(bot.sessionId, serverId: bot.serverId)
  }

  private func deleteButton(_ bot: Bot) -> some View {
    Button(role: .destructive) {
      actions.delete(bot)
    } label: {
      Label("Delete…", systemImage: "trash")
        .labelStyle(.titleAndIcon)
    }
  }

  private func sectionHeader(_ section: CustomSection, isExpanded: Bool) -> some View {
    CustomSectionHeader(
      section: section, isExpanded: isExpanded,
      isDropTarget: reorder.drag?.target == .section(section.id) || sectionDropTarget == section.id,
      onToggle: { actions.toggleSection(section.id) }, onRename: { actions.renameSection(section) },
      onDelete: { actions.deleteSection(section) }
    )
    .onDrag {
      draggedSection = section.id
      return NSItemProvider(object: section.id.uuidString as NSString)
    }
    .onDrop(
      of: [.plainText],
      delegate: BotSectionDropDelegate(
        target: section.id, dragging: $draggedSection, dropTarget: $sectionDropTarget,
        perform: sectionDropAction(onto: section)))
  }

  private func sectionDropAction(onto section: CustomSection) -> (() -> Void)? {
    guard let draggedSection, draggedSection != section.id,
      let index = sections.firstIndex(where: { $0.id == section.id })
    else { return nil }
    return { actions.moveSection(draggedSection, index) }
  }

  private func reorderGesture(for bot: Bot) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(BotRowReorder.space))
      .onChanged { value in
        if !reorder.isDragging(bot.id) {
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) { reorder.lift(bot.id) }
        }
        reorder.move(bot.id, by: value.translation.height, in: rows)
      }
      .onEnded { value in
        guard reorder.isDragging(bot.id) else { return }
        reorder.move(bot.id, by: value.translation.height, in: rows)
        let finished = withAnimation(Motion.quick(reduceMotion: reduceMotion)) { reorder.drop() }
        if let finished { drop(finished, bot: bot) }
      }
  }

  private func drop(_ drag: BotRowDrag, bot: Bot) {
    switch drag.target {
    case let .section(section):
      actions.moveBot(bot.id, section)
    case let .insertion(index):
      actions.placeBot(bot, BotSidebarRows.placement(insertingAt: index, excluding: bot.id, in: rows))
    case nil:
      break
    }
  }
}

private struct BotPlacedRowID: Hashable {
  let id: BotSidebarRowID
  let section: UUID?
}

extension BotSidebarRow {
  fileprivate var placedID: BotPlacedRowID {
    switch kind {
    case let .bot(_, section): BotPlacedRowID(id: id, section: section)
    case .section, .archivedSection, .archivedBot: BotPlacedRowID(id: id, section: nil)
    }
  }
}
