import ACPKit
import Foundation

extension SessionModel {
  static let botConversationPageSize = 50

  public var transcriptBotConversation: TranscriptBotConversation? {
    transcriptBotConversation(adding: [])
  }

  func transcriptBotConversation(adding queued: [UnsentBotMessage]) -> TranscriptBotConversation? {
    guard presentsBotConversation else { return nil }
    let deliveredIDs = Set(botMessages.map { $0.id.lowercased() })
    let unsent = BotConversationTimeline.merging(
      queued, into: unsentBotMessages(excluding: deliveredIDs), deliveredIDs: deliveredIDs)
    return TranscriptBotConversation(
      messages: BotConversationTimeline.messages(delivered: deliveredBotMessages, unsent: unsent),
      isWorking: isSending
    )
  }

  func sendBotMessage(_ message: UserMessage, afterSequence: Int?) async {
    errorMessage = nil
    harnessAuthenticationErrorMessage = nil
    await sendOutgoing(message, delivery: nil, afterBotSequence: afterSequence)
  }

  private var deliveredBotMessages: [DeliveredBotMessage] {
    botMessages.map { DeliveredBotMessage(sequence: $0.sequence, message: Self.transcriptBotMessage($0)) }
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
    let newestKnown = botMessages.last?.sequence
    let oldestFetched = page.messages.first?.sequence
    let leavesGap = newestKnown.flatMap { known in oldestFetched.map { $0 > known + 1 } } ?? false
    if botMessages.isEmpty || leavesGap {
      botMessages = page.messages.sorted { $0.sequence < $1.sequence }
      hasOlderBotMessages = page.hasMore
    } else {
      for message in page.messages { upsertBotMessage(message) }
    }
  }

  @discardableResult
  public func loadOlderBotMessages() async -> Int {
    guard hasOlderBotMessages, !isLoadingOlderBotMessages, let oldest = botMessages.first else { return 0 }
    isLoadingOlderBotMessages = true
    defer { isLoadingOlderBotMessages = false }
    guard
      let page = try? await transport.botConversation(
        before: oldest.sequence, limit: Self.botConversationPageSize)
    else { return 0 }
    botMessages = (page.messages + botMessages).sorted { $0.sequence < $1.sequence }
    hasOlderBotMessages = page.hasMore
    return page.messages.count
  }

  func upsertBotMessage(_ message: ServerBotMessage) {
    if let id = UUID(uuidString: message.id) { confirmOutgoing(id) }
    if let index = botMessages.firstIndex(where: { $0.id == message.id }) {
      botMessages[index] = message
      return
    }
    let index = botMessages.firstIndex { $0.sequence > message.sequence } ?? botMessages.endIndex
    botMessages.insert(message, at: index)
  }

  private static func transcriptBotMessage(_ message: ServerBotMessage) -> TranscriptBotMessage {
    let sender: TranscriptBotMessage.Sender =
      switch message.sender {
      case .user: .user
      case .bot: .bot
      case .notice: .notice
      }
    return TranscriptBotMessage(
      id: message.id,
      sender: sender,
      text: message.text,
      attachments: (message.attachments ?? []).map(\.attachment),
      sentAt: sentAt(message.createdAt)
    )
  }

  private static let fractionalSentAtFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let wholeSecondSentAtFormatter = ISO8601DateFormatter()

  private static func sentAt(_ value: String) -> Date? {
    fractionalSentAtFormatter.date(from: value) ?? wholeSecondSentAtFormatter.date(from: value)
  }
}
