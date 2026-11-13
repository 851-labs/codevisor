import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.windowID) private var windowID
  @Environment(\.hostedBotHeaderWindowBottom) private var hostedHeaderWindowBottom
  let serverId: String
  let botId: UUID
  var showsHeader = true
  let onOpenDetails: (Bot) -> Void
  @State private var controller: SessionController?
  @State private var headerWindowBottom: CGFloat = 0

  private var bot: Bot? { environment.bots.bot(serverId: serverId, id: botId) }

  private var session: ChatSession? {
    bot.flatMap { environment.projectList.session($0.sessionId, serverId: $0.serverId) }
  }

  var body: some View {
    content
      .navigationTitle(showsHeader ? bot?.name ?? "Bot" : "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if let bot, showsHeader {
          ToolbarItem(placement: .principal) {
            BotConversationHeader(bot: bot) { if !bot.isArchived { onOpenDetails(bot) } }
              .background {
                WindowFrameProbe { headerWindowBottom = $0.maxY }
              }
              .frame(height: BotConversationHeader.barHeight, alignment: .top)
          }
        }
      }
      .navigationDestination(item: presentedThread) { thread in
        if let bot { BotThreadScreen(bot: bot, thread: thread) }
      }
      .task(id: session?.id) { await connect() }
      .task(id: bot?.id) {
        if let bot { await environment.botThreads.refreshThreads(of: bot) }
      }
  }

  private var presentedThread: Binding<ServerThread?> {
    Binding(
      get: { bot.flatMap { environment.botThreads.openThread(of: $0) } },
      set: { thread in
        if let bot { environment.botThreads.openThreadByBot[bot.id] = thread?.threadId }
      }
    )
  }

  @ViewBuilder
  private var content: some View {
    if let bot, let controller {
      SessionTranscriptView(
        controller: controller,
        presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
          for: .init(paneID: bot.id, isNewChat: false, windowID: windowID),
          controller: controller
        ),
        isReadOnly: bot.isArchived,
        preservesComposerFocusOnSend: true,
        topChromeWindowBottom: showsHeader ? headerWindowBottom : hostedHeaderWindowBottom
      )
      .id(bot.sessionId)
    } else if bot == nil {
      ContentUnavailableView(
        "Bot Unavailable",
        systemImage: "sparkles",
        description: Text("This bot was deleted or its machine is not connected.")
      )
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ChatSurfaceBackground().ignoresSafeArea() }
    }
  }

  private func connect() async {
    guard let bot, let session,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return }
    let controller = ChatControllerCache.shared.controller(
      for: session, project: project, workspaceId: bot.workspaceId, environment: environment)
    controller.presentBotConversation(true)
    self.controller = controller
    guard controller.model == nil, !controller.isConnecting else { return }
    if session.agentSessionId?.isEmpty != false {
      await controller.prepare()
      controller.applyComposerDefaults()
    }
    await controller.connectIfNeeded()
  }
}
