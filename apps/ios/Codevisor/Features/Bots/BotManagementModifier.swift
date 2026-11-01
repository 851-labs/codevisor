import CodevisorCore
import SwiftUI

struct BotManagementModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var editing: BotEditorTarget?
  @Binding var deleting: Bot?
  var onCreated: (Bot) -> Void = { _ in }
  var onArchive: (Bot) -> Void = { _ in }
  var onDeleted: (Bot) -> Void = { _ in }

  func body(content: Content) -> some View {
    content
      .sheet(item: $editing) { target in
        BotEditorView(
          target: target, environment: environment, onCreated: onCreated, onArchive: onArchive, onDelete: delete)
      }
      .confirmationDialog(
        "Delete \(deleting?.name ?? "Bot")?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible,
        presenting: deleting
      ) { bot in
        Button("Delete Bot", role: .destructive) { delete(bot) }
      } message: { bot in
        Text(Bot.deletionMessage)
      }
  }

  private func delete(_ bot: Bot) {
    onDeleted(bot)
    Task {
      do {
        try await environment.bots.delete(bot)
        environment.botSections.forget(bot.id)
      } catch {
        ErrorReporter.shared.report("Couldn't delete bot", error: error)
      }
    }
  }
}

extension View {
  func botManagement(
    editing: Binding<BotEditorTarget?>,
    deleting: Binding<Bot?>,
    onCreated: @escaping (Bot) -> Void = { _ in },
    onArchive: @escaping (Bot) -> Void = { _ in },
    onDeleted: @escaping (Bot) -> Void = { _ in }
  ) -> some View {
    modifier(
      BotManagementModifier(
        editing: editing, deleting: deleting, onCreated: onCreated, onArchive: onArchive, onDeleted: onDeleted))
  }
}
