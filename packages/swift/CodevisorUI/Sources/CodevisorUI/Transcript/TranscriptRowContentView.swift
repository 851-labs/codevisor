import ACPKit
import CodevisorCore
import CodevisorProtocol
import StreamMarkdown
import SwiftUI
import TranscriptKit

@MainActor
public struct TranscriptRowLeaves {
  public var conversationItem:
    (
      _ item: ConversationItem,
      _ isWaitingOnUser: Bool,
      _ waitingOnBackgroundTask: String?,
      _ goalActivity: GoalActivity?
    ) -> AnyView
  public var activeConversationItem:
    (
      _ item: ConversationItem,
      _ isWaitingOnUser: Bool,
      _ waitingOnBackgroundTask: String?,
      _ goalActivity: GoalActivity?,
      _ controller: SessionController
    ) -> AnyView
  public var assistantTurn:
    (
      _ message: AssistantMessage,
      _ isWaitingOnUser: Bool,
      _ waitingOnBackgroundTask: String?,
      _ presentation: AssistantTurnPresentation
    ) -> AnyView
  public var userMessage: (_ message: UserMessage) -> AnyView
  public var botMessage: (_ message: TranscriptBotMessage, _ content: TranscriptBotMessageContent) -> AnyView
  public var workedItem:
    (
      _ item: WorkedItem,
      _ turn: AssistantTurn,
      _ turnID: UUID,
      _ isTurnActive: Bool,
      _ animationPresentation: StreamingTextAnimationPresentation,
      _ animationEnabled: Bool
    ) -> AnyView
  public var attachmentThumbnail: (_ file: PreviewFile) -> AnyView
  public var setup: (_ phases: [SessionSetupPhase]) -> AnyView
  public var setupRequest:
    (_ request: TranscriptSetupRequest, _ inBotConversation: Bool, _ controller: SessionController) -> AnyView
  public var interaction:
    (_ interaction: TranscriptInteraction, _ inBotConversation: Bool, _ controller: SessionController) -> AnyView
  public var errorRow: (_ message: String, _ rowID: TranscriptPresentationRow.ID) -> AnyView

  public init(
    conversationItem: @escaping (ConversationItem, Bool, String?, GoalActivity?) -> AnyView,
    activeConversationItem:
      @escaping (ConversationItem, Bool, String?, GoalActivity?, SessionController) -> AnyView,
    assistantTurn: @escaping (AssistantMessage, Bool, String?, AssistantTurnPresentation) -> AnyView,
    userMessage: @escaping (UserMessage) -> AnyView,
    botMessage: @escaping (TranscriptBotMessage, TranscriptBotMessageContent) -> AnyView,
    workedItem:
      @escaping (WorkedItem, AssistantTurn, UUID, Bool, StreamingTextAnimationPresentation, Bool) -> AnyView,
    attachmentThumbnail: @escaping (PreviewFile) -> AnyView,
    setup: @escaping ([SessionSetupPhase]) -> AnyView,
    setupRequest: @escaping (TranscriptSetupRequest, Bool, SessionController) -> AnyView,
    interaction: @escaping (TranscriptInteraction, Bool, SessionController) -> AnyView,
    errorRow: @escaping (String, TranscriptPresentationRow.ID) -> AnyView
  ) {
    self.conversationItem = conversationItem
    self.activeConversationItem = activeConversationItem
    self.assistantTurn = assistantTurn
    self.userMessage = userMessage
    self.botMessage = botMessage
    self.workedItem = workedItem
    self.attachmentThumbnail = attachmentThumbnail
    self.setup = setup
    self.setupRequest = setupRequest
    self.interaction = interaction
    self.errorRow = errorRow
  }
}

public struct TranscriptRowContentView: View {
  let row: TranscriptPresentationRow
  let controller: SessionController
  let leaves: TranscriptRowLeaves

  public init(row: TranscriptPresentationRow, controller: SessionController, leaves: TranscriptRowLeaves) {
    self.row = row
    self.controller = controller
    self.leaves = leaves
  }

  public var body: some View {
    rowContent
      .environment(\.transcriptAttachmentThumbnail, TranscriptAttachmentThumbnail(leaves.attachmentThumbnail))
  }

  @ViewBuilder
  private var rowContent: some View {
    let isWaitingOnUser = controller.pendingQuestion != nil
    switch row.content {
    case let .message(item, waitingOnBackgroundTask):
      leaves.conversationItem(item, isWaitingOnUser, waitingOnBackgroundTask, nil)
    case let .assistantPlanning(message):
      leaves.assistantTurn(message, isWaitingOnUser, nil, .planning)
    case let .planDocument(markdown):
      PlanDocumentView(markdown: markdown)
    case .planHeader:
      PlanDocumentHeaderView()
    case let .assistantResult(message, waitingOnBackgroundTask):
      leaves.assistantTurn(message, isWaitingOnUser, waitingOnBackgroundTask, .response)
    case let .assistantWorkedHeader(header):
      TranscriptSettledWorkedHeaderRow(header: header)
    case let .activeWorkedHeader(header):
      TranscriptActiveWorkedHeaderRow(controller: controller, header: header)
    case let .assistantWorkedItem(item):
      TranscriptSettledWorkedItemPresentation(item: item) {
        item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
        leaves.workedItem(item, turn, turnID, isTurnActive, animationPresentation, animationEnabled)
      }
    case let .activeWorkedItem(reference):
      TranscriptActiveWorkedItemPresentation(controller: controller, reference: reference) {
        item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
        leaves.workedItem(item, turn, turnID, isTurnActive, animationPresentation, animationEnabled)
      }
    case let .assistantChrome(message, slice, waitingOnBackgroundTask):
      leaves.assistantTurn(
        message, isWaitingOnUser, waitingOnBackgroundTask, AssistantTurnPresentation(chromeSlice: slice)
      )
    case let .markdownChunk(chunk):
      TranscriptMarkdownChunkView(chunk: chunk)
    case let .assistantAttachment(attachment):
      TranscriptInlineFile(file: attachment.file, label: attachment.label) {
        leaves.attachmentThumbnail(attachment.file)
      }
    case let .pluginApps(apps):
      PluginAppInlineList(apps: apps)
    case let .active(item):
      TranscriptActiveItemRow(controller: controller, projectedItem: item, leaves: leaves)
    case let .botMessage(message, content, _):
      if message.sender == .notice {
        TranscriptBotNoticeRow(text: message.text)
      } else {
        leaves.botMessage(message, content)
      }
    case let .botTimestamp(date):
      TranscriptBotTimestampRow(date: date)
    case let .delivery(id, delivery, inBotConversation):
      TranscriptDeliveryRow(
        delivery: delivery,
        inBotConversation: inBotConversation,
        retry: { Task { await controller.retryUnsentMessage(id: id) } },
        delete: { controller.deleteUnsentMessage(id: id) }
      )
    case .botTyping:
      TranscriptBotTypingRow()
    case let .setupRequest(request, inBotConversation):
      leaves.setupRequest(request, inBotConversation, controller)
    case let .interaction(interaction, inBotConversation):
      leaves.interaction(interaction, inBotConversation, controller)
    case let .setup(phases):
      leaves.setup(phases)
    case let .optimistic(message):
      if !message.text.isEmpty || !message.attachments.isEmpty {
        leaves.userMessage(message)
      }
    case .startingAgent:
      TranscriptStartingWorkedHeader(startedAt: controller.pendingSendStartedAt ?? Date())
        .suppressedDuringStreamingTextEntrance()
    case let .backgroundTask(description):
      WaitingOnAgentsLine(description: description)
        .suppressedDuringStreamingTextEntrance()
    case let .updateGate(harnessName):
      ChatActivityRow("Waiting for \(harnessName) to finish updating...")
        .suppressedDuringStreamingTextEntrance()
    case let .connecting(message):
      ChatActivityRow(message)
        .suppressedDuringStreamingTextEntrance()
    case let .serverWait(message):
      ChatActivityRow(message)
        .suppressedDuringStreamingTextEntrance()
    case let .error(message):
      leaves.errorRow(message, row.id)
    case let .bottomSpacer(height):
      Color.clear.frame(height: height)
    }
  }
}

public struct TranscriptActiveItemRow: View {
  let controller: SessionController
  let projectedItem: ConversationItem
  let leaves: TranscriptRowLeaves
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  public init(controller: SessionController, projectedItem: ConversationItem, leaves: TranscriptRowLeaves) {
    self.controller = controller
    self.projectedItem = projectedItem
    self.leaves = leaves
  }

  public var body: some View {
    let revision = controller.activeItemRevision
    let waitingOnBackgroundTask = controller.waitingBackgroundTaskDescription
    let connectionRecoveryMessage = controller.transcriptActivityOverride
    let goal = controller.model?.goal
    let goalActivity = goal?.status == .active ? goal?.activity : nil
    let item = TranscriptActiveItemResolver.resolve(
      projected: projectedItem,
      live: controller.activeItem,
      settled: controller.settledConversation
    )
    leaves.activeConversationItem(
      item, controller.pendingQuestion != nil, waitingOnBackgroundTask, goalActivity, controller
    )
    .environment(\.runningSubagentToolCallIds, controller.runningSubagentToolCallIds)
    .id(item.id)
    .onChange(of: revision, initial: true) { _, _ in
      invalidateRowMeasurement?()
    }
    .onChange(of: waitingOnBackgroundTask) { _, _ in
      invalidateRowMeasurement?()
    }
    .onChange(of: connectionRecoveryMessage) { _, _ in
      invalidateRowMeasurement?()
    }
    .onChange(of: goalActivity) { _, _ in
      invalidateRowMeasurement?()
    }
  }
}
