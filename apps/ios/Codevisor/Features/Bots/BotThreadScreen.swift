import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotThreadScreen: View {
  let bot: Bot
  let thread: ServerThread
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    BotThreadTranscript(
      messages: environment.botThreads.messages(in: thread.threadId),
      hasOlder: environment.botThreads.threadsWithOlderMessages.contains(thread.threadId),
      loadOlder: loadOlder
    ) { participant in
      ThreadParticipantAvatar(participant: participant, size: 28)
    }
    .safeAreaInset(edge: .bottom) {
      Text("Only \(bot.name) and \(otherName) write in this thread.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
    }
    .background { ChatSurfaceBackground().ignoresSafeArea() }
    .navigationTitle("\(bot.name) and \(otherName)")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: thread.threadId) {
      await environment.botThreads.loadMessages(in: thread.threadId, serverId: bot.serverId)
    }
  }

  private var otherName: String {
    environment.botThreads.other(in: thread, than: bot)?.threadDisplayName ?? "Agent"
  }

  private func loadOlder() {
    Task { await environment.botThreads.loadOlderMessages(in: thread.threadId, serverId: bot.serverId) }
  }
}
