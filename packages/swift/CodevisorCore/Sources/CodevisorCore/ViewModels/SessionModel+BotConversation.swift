import ACPKit
import Foundation

extension SessionModel {
  static let botConversationPageSize = 50

  public var transcriptBotConversation: TranscriptBotConversation? {
    guard presentsBotConversation else { return nil }
    let sentIDs = Set(botMessages.map { $0.id.lowercased() })
    let deliveries = transcriptDeliveries
    let unsent =
      outgoingMessages
      .map(\.message)
      .filter { !sentIDs.contains($0.id.uuidString.lowercased()) }
      .map {
        TranscriptBotMessage(
          id: $0.id.uuidString.lowercased(), sender: .user, text: $0.text, attachments: $0.attachments,
          delivery: deliveries[$0.id])
      }
    return TranscriptBotConversation(
      messages: botMessages.map(Self.transcriptBotMessage) + unsent,
      isWorking: isSending
    )
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

  private static func sentAt(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}
