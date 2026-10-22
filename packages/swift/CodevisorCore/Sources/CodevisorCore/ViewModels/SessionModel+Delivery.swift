import ACPKit
import Foundation

struct OutgoingMessage: Equatable {
  let message: UserMessage
  let delivery: ServerPromptDelivery?
}

struct UnreachedSend: Equatable {
  let messageID: UUID
  let actionID: String
}

enum SendOutcome {
  case accepted(ServerPromptAccepted?)
  case failed(any Error)
}

extension SessionModel {
  var transcriptOutgoingMessages: [UserMessage] {
    guard !presentsBotConversation else { return [] }
    return outgoingMessages.filter { outgoing in
      let id = outgoing.message.id
      return outgoing.delivery != .queue || slowMessageIDs.contains(id) || failedMessageIDs.contains(id)
    }.map(\.message)
  }

  var transcriptDeliveries: [UUID: TranscriptDelivery] {
    var deliveries: [UUID: TranscriptDelivery] = [:]
    for id in slowMessageIDs where !acceptedMessageIDs.contains(id) { deliveries[id] = .sending }
    for id in failedMessageIDs { deliveries[id] = .failed }
    return deliveries
  }

  func sendOutgoing(_ message: UserMessage, delivery: ServerPromptDelivery?) async {
    outgoingMessages.append(OutgoingMessage(message: message, delivery: delivery))
    if delivery != .queue { onLocalUserMessageAppended?(message.id) }
    await startConsumer()
    await deliverOutgoing(message.id)
  }

  public func retryUnsentMessage(id: UUID) async {
    guard failedMessageIDs.contains(id), outgoingMessages.contains(where: { $0.message.id == id }) else { return }
    failedMessageIDs.remove(id)
    slowMessageIDs.insert(id)
    await deliverOutgoing(id)
  }

  public func deleteUnsentMessage(id: UUID) {
    guard failedMessageIDs.remove(id) != nil else { return }
    slowMessageIDs.remove(id)
    outgoingMessages.removeAll { $0.message.id == id }
  }

  func resendAfterReconnect() async {
    for outgoing in outgoingMessages where failedMessageIDs.contains(outgoing.message.id) {
      await retryUnsentMessage(id: outgoing.message.id)
    }
    guard !presentsBotConversation, !isSending, let unreached = unreachedSend,
      let prompt = settledConversation.last(where: { $0.userPrompt != nil })?.userPrompt,
      prompt.id == unreached.messageID
    else { return }
    await retryResponse(to: prompt)
  }

  func confirmOutgoing(_ id: UUID) {
    outgoingMessages.removeAll { $0.message.id == id }
    acceptedMessageIDs.remove(id)
    slowMessageIDs.remove(id)
    failedMessageIDs.remove(id)
  }

  func deliver(_ message: UserMessage, delivery: ServerPromptDelivery?, actionID: String) async -> SendOutcome {
    let id = message.id
    var retryDelays = sendRetryDelays[...]
    let noticeDelay = sendingNoticeDelay
    let notice = Task { [weak self] in
      try? await Task.sleep(for: noticeDelay)
      guard !Task.isCancelled else { return }
      self?.slowMessageIDs.insert(id)
    }
    defer { notice.cancel() }
    while true {
      do {
        return .accepted(
          try await transport.prompt(
            message.text,
            attachments: message.attachments,
            messageId: id.uuidString.lowercased(),
            clientId: promptClientId,
            delivery: delivery,
            clientActionId: actionID
          ))
      } catch {
        if Self.isTransientSendFailure(error), let delay = retryDelays.popFirst() {
          try? await Task.sleep(for: delay)
          continue
        }
        if await serverHasMessage(id) { return .accepted(nil) }
        return .failed(error)
      }
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
    case .failed:
      slowMessageIDs.remove(id)
      if outgoingMessages.contains(where: { $0.message.id == id }) { failedMessageIDs.insert(id) }
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
    if presentsBotConversation { return botMessages.contains { $0.id.lowercased() == key } }
    return queuedPrompts.contains { $0.id.lowercased() == key }
      || settledConversation.contains { item in
        if case let .user(message) = item { return message.id == id }
        return false
      }
  }

  private func serverHasMessage(_ id: UUID) async -> Bool {
    if presentsBotConversation {
      await refreshBotConversation()
      return serverShows(id)
    }
    if let queue = await promptQueue.refresh(),
      queue.contains(where: { $0.id.lowercased() == id.uuidString.lowercased() })
    {
      return true
    }
    guard let page = try? await transport.transcriptPage(limit: 16) else { return false }
    return page.conversation.contains { item in
      if case let .user(message) = item { return message.id == id }
      return false
    }
  }

  private static func isTransientSendFailure(_ error: any Error) -> Bool {
    if error is CancellationError { return false }
    guard case let CodevisorServerClientError.httpStatus(status, _) = error else { return true }
    return status >= 500 || status == 408 || status == 429
  }
}
