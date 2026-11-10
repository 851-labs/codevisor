import ACPKit
import Foundation

extension SessionModel {
  static let botConversationPageSize = 50

  public var transcriptBotConversation: TranscriptBotConversation? {
    transcriptBotConversation(adding: [])
  }

  func transcriptBotConversation(adding queued: [UnsentBotMessage]) -> TranscriptBotConversation? {
    guard presentsBotConversation else { return nil }
    let deliveredIDs = botLog.normalizedIDs
    let unsent = BotConversationTimeline.merging(
      queued, into: unsentBotMessages(excluding: deliveredIDs), deliveredIDs: deliveredIDs)
    return TranscriptBotConversation(
      messages: BotConversationTimeline.messages(delivered: botLog, unsent: unsent),
      isWorking: isSending
    )
  }

  func sendBotMessage(_ message: UserMessage, afterSequence: Int?) async {
    errorMessage = nil
    harnessAuthenticationErrorMessage = nil
    await sendOutgoing(message, delivery: nil, afterBotSequence: afterSequence)
  }

  private func unsentBotMessages(excluding deliveredIDs: Set<String>) -> [UnsentBotMessage] {
    let deliveries = transcriptDeliveries
    let unsent = outgoingMessages.filter { !deliveredIDs.contains($0.message.id.uuidString.lowercased()) }
    return unsent.map { Self.unsentBotMessage($0, delivery: deliveries[$0.message.id]) }
  }

  private static func unsentBotMessage(_ outgoing: OutgoingMessage, delivery: TranscriptDelivery?) -> UnsentBotMessage {
    let message = outgoing.message
    return UnsentBotMessage(
      message: TranscriptBotMessage(
        id: message.id.uuidString.lowercased(), sender: .user, text: message.text,
        attachments: message.attachments, delivery: delivery),
      afterSequence: outgoing.afterBotSequence)
  }

  public func presentBotConversation() {
    guard !presentsBotConversation else { return }
    presentsBotConversation = true
    Task { await refreshBotConversation() }
  }

  func refreshBotConversation() async {
    guard presentsBotConversation,
      let page = try? await transport.botConversation(before: nil, limit: Self.botConversationPageSize)
    else { return }
    let newestKnown = botLog.lastSequence
    let oldestFetched = page.messages.map(\.sequence).min()
    let leavesGap = newestKnown.flatMap { known in oldestFetched.map { $0 > known + 1 } } ?? false
    if botLog.isEmpty || leavesGap {
      botLog.replace(with: page.messages)
      hasOlderBotMessages = page.hasMore
    } else {
      for message in page.messages { upsertBotMessage(message) }
    }
  }

  @discardableResult
  public func loadOlderBotMessages() async -> Int {
    guard hasOlderBotMessages, !isLoadingOlderBotMessages, let oldest = botLog.firstSequence else { return 0 }
    isLoadingOlderBotMessages = true
    defer { isLoadingOlderBotMessages = false }
    guard
      let page = try? await transport.botConversation(
        before: oldest, limit: Self.botConversationPageSize)
    else { return 0 }
    botLog.prepend(page.messages)
    hasOlderBotMessages = page.hasMore
    return page.messages.count
  }

  func upsertBotMessage(_ message: ServerBotMessage) {
    if let id = UUID(uuidString: message.id) { confirmOutgoing(id) }
    botLog.upsert(message)
  }

  static func sentAt(_ value: String) -> Date? {
    ServerTimestamp.date(from: value)
  }
}
