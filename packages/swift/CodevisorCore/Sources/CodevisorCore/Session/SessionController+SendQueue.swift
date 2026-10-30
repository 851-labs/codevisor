import ACPKit
import Foundation

enum SessionPreparation {
  case ready(SessionModel)
  case notStarted(String)
  case failed(String, returnsToNewChat: Bool)
}

struct SessionSetupFailure: Error {
  let message: String
}

public struct UnsentQueuedMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  public let attachmentCount: Int
  public let delivery: TranscriptDelivery?
}

extension SessionController {
  static let closedChatReason = "This chat was closed."
  static let modelSelectionReason = "Choose a model for this chat, then try again."

  func sendToBot() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composerAttachments.isEmpty else { return }

    let sent = attachments.detachForSend()
    let message = UserMessage(text: text, attachments: sent.map(\.sentAttachment))
    rememberSentPreviews(of: sent)
    userSendSignal &+= 1
    requestUserSendAnimation(for: message.id)
    sends.enqueue(
      message, attachmentIDs: sent.map(\.id), route: .bot(afterSequence: model?.botMessages.last?.sequence))
    composerText = ""
  }

  public var hasUnsentBotMessages: Bool {
    !sends.unsentBotMessages.isEmpty
  }

  public var canSend: Bool {
    let hasDraft = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerAttachments.isEmpty
    return hasDraft && acceptsSends
  }

  public var acceptsSends: Bool {
    if let sandboxTargetAvailability, sandboxTargetAvailability != .available { return false }
    guard !hasSentFirst, project.isRunTargetPlaceholder else { return true }
    return isServerReady && !isPausedForUpdate && selectedHarness != nil
  }

  public var hasUnsentMessages: Bool {
    !sends.unsent.isEmpty || model?.outgoingMessages.isEmpty == false
  }

  public var unsentQueuedMessages: [UnsentQueuedMessage] {
    let serverIDs = Set(queuedPrompts.map { $0.id.lowercased() })
    let waiting = queuedSendEntries
    var seen = Set<UUID>()
    let local = (model?.unsentQueuedMessages ?? []).map { Self.keepingProgress(of: $0, from: waiting) } + waiting
    return local.filter { message in
      !serverIDs.contains(message.id.uuidString.lowercased()) && seen.insert(message.id).inserted
    }
  }

  private static func keepingProgress(
    of message: UnsentQueuedMessage, from waiting: [UnsentQueuedMessage]
  ) -> UnsentQueuedMessage {
    guard message.delivery == nil, let delivery = waiting.first(where: { $0.id == message.id })?.delivery else {
      return message
    }
    return UnsentQueuedMessage(
      id: message.id, text: message.text, attachmentCount: message.attachmentCount, delivery: delivery)
  }

  public var hasQueuedMessages: Bool {
    !queuedPrompts.isEmpty || !unsentQueuedMessages.isEmpty
  }

  private var queuedSendEntries: [UnsentQueuedMessage] {
    sends.unsent.filter(\.route.landsInPromptQueue).map { entry in
      UnsentQueuedMessage(
        id: entry.message.id, text: entry.message.text, attachmentCount: entry.message.attachments.count,
        delivery: entry.delivery)
    }
  }

  var unsentAgentSends: [SendQueue.Unsent] {
    sends.unsent.filter { entry in
      guard case .agent = entry.route, !entry.route.landsInPromptQueue else { return false }
      return model?.holdsLocalUserMessage(entry.message.id) != true
    }
  }

  var sendReadiness: SendQueue.Readiness {
    if transcriptSandboxPower != nil { return .waking(failure: Self.sandboxWakeFailure) }
    if case let .failed(message) = configurationValidationState { return .failed(message) }
    let isSettled = isServerReady && !isConnecting && !isPausedForUpdate && configurationValidationState == .ready
    return isSettled ? .ready : .waiting(unreachableReason)
  }

  func connectForSend(_ message: UserMessage) async -> SendQueue.Preparation {
    defer { isFirstSendConnecting = false }
    switch await prepareSession(for: message.text) {
    case let .ready(model):
      guard !requiresModelSelection else { return .failed(modelSelectionFailure) }
      return .ready(model)
    case let .notStarted(reason):
      returnToDraft(message)
      isSubmitting = false
      status = .failed(reason)
      return .withdrawn
    case let .failed(reason, _):
      status = projectCloneFailure == nil ? .idle : .failed(reason)
      return .failed(reason)
    }
  }

  func deliverSend(_ message: UserMessage, route: SendQueue.Route, to model: SessionModel) async {
    switch route {
    case let .bot(afterSequence):
      await model.sendBotMessage(message, afterSequence: afterSequence ?? model.botMessages.last?.sequence)
    case let .agent(delivery):
      await model.send(message, startedAt: pendingSendStartedAt, delivery: delivery)
    }
  }

  func rememberUploaded(_ uploaded: Attachment, sentAs sentFileID: String) {
    guard uploaded.fileId != sentFileID else { return }

    SentAttachmentAliases.remember(uploaded: uploaded.fileId, sentAs: sentFileID)
    guard let preview = sentAttachmentPreviews.preview(for: sentFileID) else { return }
    sentAttachmentPreviews.remember(preview, for: uploaded.fileId)
  }

  func rememberSentPreviews(of sent: [ComposerAttachment]) {
    for attachment in sent where attachment.isImage {
      guard let preview = attachment.sentPreviewData else { continue }
      sentAttachmentPreviews.remember(preview, for: attachment.sentFileID)
    }
  }

  private func returnToDraft(_ message: UserMessage) {
    composerText = message.text
    cancelUserSendAnimation(for: message.id)
  }

  private var unreachableReason: String {
    if let serverWaitMessage { return serverWaitMessage }
    return presentsBotConversation
      ? "The bot isn’t reachable right now. Try again in a moment."
      : "This chat isn’t reachable right now. Try again in a moment."
  }

  private var modelSelectionFailure: String {
    presentsBotConversation ? "Pick a model for this bot in its settings, then try again." : Self.modelSelectionReason
  }
}
