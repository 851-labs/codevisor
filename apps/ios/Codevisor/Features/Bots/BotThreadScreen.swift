import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotThreadScreen: View {
  let bot: Bot
  let thread: ServerThread
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.windowID) private var windowID
  @State private var controller: SessionController?
  @State private var headerWindowBottom: CGFloat = 0

  var body: some View {
    content
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          BotThreadHeader(bot: bot, participant: other)
            .background {
              WindowFrameProbe { headerWindowBottom = $0.maxY }
            }
            .frame(height: BotConversationHeader.barHeight, alignment: .top)
        }
      }
      .task(id: thread.threadId) {
        controller = makeController()
        await environment.botThreads.loadMessages(in: thread.threadId, serverId: bot.serverId)
      }
      .onChange(of: presented, initial: true) { present() }
      .onChange(of: controller.map(ObjectIdentifier.init)) { present() }
  }

  @ViewBuilder
  private var content: some View {
    if let controller {
      SessionTranscriptView(
        controller: controller,
        presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
          for: .init(paneID: viewerId, isNewChat: false, windowID: windowID),
          controller: controller
        ),
        isReadOnly: true,
        topChromeWindowBottom: headerWindowBottom
      )
      .id(thread.threadId)
    } else {
      ChatSurfaceBackground().ignoresSafeArea()
    }
  }

  private var viewerId: UUID {
    UUID(uuidString: thread.threadId) ?? bot.id
  }

  private var presented: PresentedThread {
    PresentedThread(
      conversation: .thread(environment.botThreads.messages(in: thread.threadId)),
      hasOlder: environment.botThreads.threadsWithOlderMessages.contains(thread.threadId))
  }

  private var other: ServerThreadParticipant? {
    environment.botThreads.other(in: thread, than: bot)
  }

  private func present() {
    guard let controller else { return }
    let presented = presented
    controller.presentThread(presented.conversation, hasOlder: presented.hasOlder)
    controller.loadOlderThreadMessages = { [botThreads = environment.botThreads, thread, bot] in
      await botThreads.loadOlderMessages(in: thread.threadId, serverId: bot.serverId)
    }
  }

  private func makeController() -> SessionController? {
    guard let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId),
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return nil }
    let controller = SessionController(
      project: project,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      hostWorkspaceId: bot.workspaceId,
      serverClient: environment.machines.client(for: session.serverId),
      machines: environment.machines,
      attachmentFiles: environment.composerDrafts.attachmentFiles
    )
    controller.configureExistingSession(session)
    return controller
  }
}

private struct BotThreadHeader: View {
  let bot: Bot
  let participant: ServerThreadParticipant?
  @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 56

  var body: some View {
    VStack(spacing: -BotHeaderAvatarMetrics.overlap) {
      ThreadGroupAvatar(bot: bot, participant: participant, size: avatarSize)
        .botHeaderAvatarShadow()
        .zIndex(1)
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thread between \(title)")
    .accessibilityIdentifier("bot.thread.header")
  }

  private var title: String {
    "\(bot.name) & \(participant?.threadDisplayName ?? "Agent")"
  }
}
