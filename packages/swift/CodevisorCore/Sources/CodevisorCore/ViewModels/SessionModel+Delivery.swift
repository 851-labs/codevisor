import ACPKit
import Foundation

struct OutgoingMessage: Equatable {
  let message: UserMessage
  let delivery: ServerPromptDelivery?
  let sentAt: Date
  var afterBotSequence: Int? = nil
  var landsInQueue = false
}

struct PendingTranscriptMessage: Equatable {
  let message: UserMessage
  let sentAt: Date
}

struct UnreachedSend: Equatable {
  let messageID: UUID
  let actionID: String
}

enum SendOutcome {
  case accepted(ServerPromptAccepted?)
  case failed(any Error)

  var isAccepted: Bool {
    guard case .accepted = self else { return false }
    return true
  }
}

extension SessionModel {
  static let undeliveredReason = "Codevisor couldn’t deliver this message. Try again in a moment."

  var transcriptOutgoingMessages: [UserMessage] {
    pendingOutgoing.map(\.message)
  }

  var pendingOutgoing: [PendingTranscriptMessage] {
    guard !presentsBotConversation else { return [] }
    return outgoingMessages.filter { !$0.landsInQueue }.map {
      PendingTranscriptMessage(message: $0.message, sentAt: $0.sentAt)
    }
  }

  var unsentQueuedMessages: [UnsentQueuedMessage] {
    guard !presentsBotConversation else { return [] }
    let deliveries = transcriptDeliveries
    return outgoingMessages.filter(\.landsInQueue).map { outgoing in
      UnsentQueuedMessage(
        id: outgoing.message.id, text: outgoing.message.text, attachmentCount: outgoing.message.attachments.count,
        delivery: deliveries[outgoing.message.id])
    }
  }

  func holdsLocalUserMessage(_ id: UUID) -> Bool {
    settledIndexById[id] != nil || outgoingMessages.contains { $0.message.id == id }
  }

  var transcriptDeliveries: [UUID: TranscriptDelivery] {
    var deliveries: [UUID: TranscriptDelivery] = [:]
    for id in slowMessageIDs where !acceptedMessageIDs.contains(id) { deliveries[id] = .sending }
    for (id, reason) in failedMessageReasons { deliveries[id] = .failed(reason: reason) }
    for id in awaitingStepMessageIDs where deliveries[id] == nil { deliveries[id] = .awaitingStep }
    return deliveries
  }

  func sendOutgoing(
    _ message: UserMessage, delivery: ServerPromptDelivery?, afterBotSequence: Int? = nil, landsInQueue: Bool = false
  ) async {
    outgoingMessages.append(
      OutgoingMessage(
        message: message, delivery: delivery, sentAt: now(), afterBotSequence: afterBotSequence,
        landsInQueue: landsInQueue))
    if !landsInQueue { onLocalUserMessageAppended?(message.id) }
    await startConsumer()
    await deliverOutgoing(message.id)
  }

  public func retryUnsentMessage(id: UUID) async {
    guard failedMessageReasons[id] != nil, let outgoing = outgoingMessages.first(where: { $0.message.id == id })
    else { return }
    failedMessageReasons[id] = nil
    if outgoing.delivery == nil, !presentsBotConversation, !isSending {
      outgoingMessages.removeAll { $0.message.id == id }
      return await send(outgoing.message)
    }
    slowMessageIDs.insert(id)
    await deliverOutgoing(id)
  }

  public func deleteUnsentMessage(id: UUID) {
    guard failedMessageReasons.removeValue(forKey: id) != nil else { return }
    slowMessageIDs.remove(id)
    outgoingMessages.removeAll { $0.message.id == id }
  }

  func confirmOutgoing(_ id: UUID) {
    rememberSteerBubble(id)
    outgoingMessages.removeAll { $0.message.id == id }
    acceptedMessageIDs.remove(id)
    slowMessageIDs.remove(id)
    failedMessageReasons[id] = nil
  }

  func deliver(_ message: UserMessage, delivery: ServerPromptDelivery?, actionID: String) async -> SendOutcome {
    let notice = startSendingNotice(for: message.id)
    defer { notice.cancel() }
    let startedAt = now()
    while true {
      do {
        return .accepted(try await prompt(message, delivery: delivery, actionID: actionID))
      } catch {
        guard ServerConnectionLoss.isConnectionLoss(error) else { return .failed(error) }
        if message.id == unacceptedTurnPromptID { turnPromptWaitedForConnection = true }
        guard await transport.waitUntilConnected() else { return .failed(error) }
        if StaleSend.hasWaitedTooLong(since: startedAt, now: now()) { return .failed(StaleSend.Error()) }
      }
    }
  }

  private func prompt(
    _ message: UserMessage, delivery: ServerPromptDelivery?, actionID: String
  ) async throws -> ServerPromptAccepted {
    try await transport.prompt(
      message.text,
      attachments: message.attachments,
      messageId: message.id.uuidString.lowercased(),
      clientId: promptClientId,
      delivery: delivery,
      clientActionId: actionID
    )
  }

  private func startSendingNotice(for id: UUID) -> Task<Void, Never> {
    let noticeDelay = sendingNoticeDelay
    return Task { [weak self] in
      try? await Task.sleep(for: noticeDelay)
      guard !Task.isCancelled else { return }
      self?.slowMessageIDs.insert(id)
    }
  }

  private func deliverOutgoing(_ id: UUID) async {
    guard let outgoing = outgoingMessages.first(where: { $0.message.id == id }) else { return }
    let message = outgoing.message
    switch await deliver(message, delivery: outgoing.delivery, actionID: id.uuidString.lowercased()) {
    case let .accepted(response):
      let notSteered = outgoing.delivery != nil && response?.wasSteered == false
      onPromptAccepted?(message.attachments.count, notSteered)
      if notSteered { onPromptNotSteered?(id) }
      settleAccepted(id)
      refreshQueueForUnshownSteer(id, response: response)
    case let .failed(error):
      slowMessageIDs.remove(id)
      guard outgoingMessages.contains(where: { $0.message.id == id }) else { return }
      failedMessageReasons[id] = humanServerErrorMessage(error, fallback: Self.undeliveredReason)
    }
  }

  private func settleAccepted(_ id: UUID) {
    slowMessageIDs.remove(id)
    guard outgoingMessages.contains(where: { $0.message.id == id }) else { return }
    if serverShows(id) {
      confirmOutgoing(id)
    } else {
      acceptedMessageIDs.insert(id)
    }
  }

  private func serverShows(_ id: UUID) -> Bool {
    let key = id.uuidString.lowercased()
    if presentsBotConversation { return botLog.contains(normalizedID: key) }
    return queuedPrompts.contains { $0.id.lowercased() == key }
      || settledConversation.contains { item in
        if case let .user(message) = item { return message.id == id }
        return false
      }
  }
}
