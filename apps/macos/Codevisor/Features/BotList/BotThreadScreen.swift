import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotThreadScreen: View {
  let bot: Bot
  let thread: ServerThread
  let controller: SessionController
  let surface: TranscriptPresentationSurface
  let focus: TerminalFocusController
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    ChatScreen(
      controller: controller,
      focus: focus,
      presentationSurface: surface,
      isReadOnly: true,
      presentsBotConversation: true
    )
    .environment(\.transcriptTopChromeHeight, BotConversationHeader.height)
    .overlay(alignment: .top) {
      BotThreadHeader(bot: bot, participant: other)
        .ignoresSafeArea(edges: .top)
    }
    .toolbar {
      ToolbarSpacer(.fixed, placement: .navigation)
      ToolbarItem(placement: .navigation) {
        Button(action: close) {
          Label("Back to \(bot.name)", systemImage: "chevron.backward")
        }
        .help("Back to your conversation with \(bot.name)")
        .keyboardShortcut(.cancelAction)
      }
    }
    .id(thread.threadId)
    .task(id: thread.threadId) {
      await environment.botThreads.loadMessages(in: thread.threadId, serverId: bot.serverId)
    }
    .onChange(of: presented, initial: true) { _, presented in
      controller.presentThread(presented.conversation, hasOlder: presented.hasOlder)
    }
    .onAppear {
      controller.loadOlderThreadMessages = { [botThreads = environment.botThreads, thread, bot] in
        await botThreads.loadOlderMessages(in: thread.threadId, serverId: bot.serverId)
      }
    }
  }

  private var presented: PresentedThread {
    PresentedThread(
      conversation: .thread(environment.botThreads.messages(in: thread.threadId), viewedBy: bot),
      hasOlder: environment.botThreads.threadsWithOlderMessages.contains(thread.threadId))
  }

  private var other: ServerThreadParticipant? {
    environment.botThreads.other(in: thread, than: bot)
  }

  private func close() {
    environment.botThreads.openThreadByBot[bot.id] = nil
  }
}

private struct BotThreadHeader: View {
  let bot: Bot
  let participant: ServerThreadParticipant?

  var body: some View {
    VStack(spacing: -BotConversationHeader.overlap) {
      ThreadGroupAvatar(bot: bot, participant: participant, size: BotConversationHeader.avatarSize)
        .botHeaderAvatarShadow()
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(
          .regular,
          in: BotConversationHeaderNameShape(
            avatarSize: BotConversationHeader.avatarSize, overlap: BotConversationHeader.overlap))
    }
    .padding(.top, 4)
    .frame(height: BotConversationHeader.height, alignment: .top)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thread between \(title)")
  }

  private var title: String {
    "\(bot.name) & \(participant?.threadDisplayName ?? "Agent")"
  }
}
