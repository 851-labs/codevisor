import CodevisorCore
import SwiftUI

struct SidebarBotsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var botEditor: BotEditorTarget?
  @Binding var deletingBot: Bot?
  @Binding var selection: SidebarSelection?
  let store: SessionStore?

  func body(content: Content) -> some View {
    content
      .sheet(item: $botEditor) { target in
        BotEditorSheet(target: target, environment: environment, store: store) { bot in
          selection = .bot(serverId: bot.serverId, id: bot.id)
        }
      }
      .confirmationDialog(
        "Delete \(deletingBot?.name ?? "bot")?",
        isPresented: Binding(get: { deletingBot != nil }, set: { if !$0 { deletingBot = nil } }),
        titleVisibility: .visible,
        presenting: deletingBot
      ) { bot in
        Button("Delete Bot", role: .destructive) { delete(bot) }
      } message: { bot in
        Text(Bot.deletionMessage)
      }
  }

  private func delete(_ bot: Bot) {
    if selection == .bot(serverId: bot.serverId, id: bot.id) {
      selection = .newChat(nil)
    }
    Task {
      do {
        try await environment.bots.delete(bot)
        environment.botSections.forget(bot: bot.id)
      } catch {
        ErrorReporter.shared.report("Couldn't delete bot", error: error)
      }
    }
  }
}
