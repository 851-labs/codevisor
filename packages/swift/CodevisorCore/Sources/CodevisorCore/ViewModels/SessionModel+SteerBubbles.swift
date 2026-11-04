import ACPKit
import Foundation

extension SessionModel {
  private var awaitingStepItems: [ServerPromptQueueItem] {
    guard !presentsBotConversation else { return [] }
    return promptQueue.items.filter { $0.isNextStep && !$0.isSystem }
  }

  var awaitingStepMessageIDs: Set<UUID> {
    Set(awaitingStepItems.compactMap { UUID(uuidString: $0.id) })
  }

  var transcriptPendingMessages: [UserMessage] {
    let outgoing = pendingOutgoing
    let shownIDs = Set(outgoing.map(\.message.id))
    let absorbed = presentsBotConversation ? [] : absorbedSteerMessages
    let steers = (awaitingStepItems.compactMap(steerBubble) + absorbed).filter {
      !shownIDs.contains($0.message.id) && settledIndexById[$0.message.id] == nil
    }
    return Self.inSendOrder(outgoing + steers).map(\.message)
  }

  static func inSendOrder(_ pending: [PendingTranscriptMessage]) -> [PendingTranscriptMessage] {
    pending.enumerated()
      .sorted { ($0.element.sentAt, $0.offset) < ($1.element.sentAt, $1.offset) }
      .map(\.element)
  }

  func awaitingStepQueueItemID(for messageID: UUID) -> String? {
    awaitingStepItems.first { UUID(uuidString: $0.id) == messageID }?.id
  }

  func rememberSteerBubble(_ id: UUID) {
    let key = id.uuidString.lowercased()
    guard !presentsBotConversation,
      promptQueue.items.contains(where: { $0.isNextStep && $0.id.lowercased() == key }),
      let outgoing = outgoingMessages.first(where: { $0.message.id == id })
    else { return }
    steerBubbleMessages[id] = PendingTranscriptMessage(message: outgoing.message, sentAt: outgoing.sentAt)
  }

  func refreshQueueForUnshownSteer(_ id: UUID, response: ServerPromptAccepted?) {
    guard response?.wasSteered == true, acceptedMessageIDs.contains(id) else { return }
    Task { [weak self] in _ = await self?.promptQueue.refresh() }
  }

  func steerQueueChanged(from previous: [ServerPromptQueueItem]) {
    let wasAwaiting = previous.filter(\.isNextStep).map(\.id)
    let awaiting = promptQueue.items.filter(\.isNextStep).map(\.id)
    guard wasAwaiting != awaiting else { return }
    transcriptProjectionRevision &+= 1
    guard !presentsBotConversation else { return }
    let remaining = Set(promptQueue.items.map(\.id))
    for item in previous where item.isNextStep && !item.isSystem && !remaining.contains(item.id) {
      guard withdrawnSteerIDs.remove(item.id) == nil else { continue }
      guard let steer = steerBubble(item), settledIndexById[steer.message.id] == nil,
        !absorbedSteerMessages.contains(where: { $0.message.id == steer.message.id })
      else { continue }
      absorbedSteerMessages.append(steer)
    }
  }

  func withdrawSteer(messageID: UUID) async -> Bool {
    guard let id = awaitingStepQueueItemID(for: messageID) else { return false }
    withdrawnSteerIDs.insert(id)
    let withdrawn = await promptQueue.withdrawSteer(id: id)
    if !withdrawn { withdrawnSteerIDs.remove(id) }
    return withdrawn
  }

  func takeAbsorbedSteer(_ id: String?) -> Bool {
    guard let id, let messageID = UUID(uuidString: id) else { return false }
    steerBubbleMessages[messageID] = nil
    guard let index = absorbedSteerMessages.firstIndex(where: { $0.message.id == messageID }) else { return false }
    absorbedSteerMessages.remove(at: index)
    return true
  }

  private func steerBubble(_ item: ServerPromptQueueItem) -> PendingTranscriptMessage? {
    guard let id = UUID(uuidString: item.id) else { return nil }
    if let remembered = steerBubbleMessages[id] { return remembered }
    let message = UserMessage(id: id, text: item.text, attachments: (item.attachments ?? []).map(\.attachment))
    return PendingTranscriptMessage(message: message, sentAt: Self.sentAt(item.createdAt) ?? .distantPast)
  }
}
