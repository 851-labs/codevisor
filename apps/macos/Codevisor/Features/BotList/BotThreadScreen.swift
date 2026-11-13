import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotThreadScreen: View {
  let bot: Bot
  let thread: ServerThread
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.transcriptTopChromeHeight) private var topChromeHeight

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      BotThreadTranscript(
        messages: environment.botThreads.messages(in: thread.threadId),
        hasOlder: environment.botThreads.threadsWithOlderMessages.contains(thread.threadId),
        loadOlder: loadOlder
      ) { participant in
        ThreadParticipantAvatar(participant: participant, size: 28)
      }
      Text("Only \(bot.name) and \(otherName) write in this thread.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
    }
    .padding(.top, topChromeHeight)
    .task(id: thread.threadId) {
      await environment.botThreads.loadMessages(in: thread.threadId, serverId: bot.serverId)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: close) {
        Label(bot.name, systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)
      .help("Back to your conversation with \(bot.name)")
      .keyboardShortcut(.cancelAction)
      Spacer(minLength: 8)
      if let other {
        ThreadParticipantAvatar(participant: other, size: 22)
      }
      Text("\(bot.name) and \(otherName)")
        .font(.headline)
        .lineLimit(1)
      Spacer(minLength: 8)
      Label(bot.name, systemImage: "chevron.left")
        .hidden()
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var other: ServerThreadParticipant? {
    environment.botThreads.other(in: thread, than: bot)
  }

  private var otherName: String {
    other?.threadDisplayName ?? "Agent"
  }

  private func close() {
    environment.botThreads.openThreadByBot[bot.id] = nil
  }

  private func loadOlder() {
    Task { await environment.botThreads.loadOlderMessages(in: thread.threadId, serverId: bot.serverId) }
  }
}
