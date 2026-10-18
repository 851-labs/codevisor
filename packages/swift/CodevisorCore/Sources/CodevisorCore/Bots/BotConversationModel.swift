import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class BotConversationModel {
  public static let pageSize = 50

  public let sessionId: UUID
  public private(set) var messages: [ServerBotMessage] = []
  public private(set) var pending: [ServerBotMessage] = []
  public private(set) var failedIds: Set<String> = []
  public private(set) var hasMore = false
  public private(set) var isWorking = false
  public private(set) var isLoadingOlder = false
  public private(set) var hasLoaded = false
  public private(set) var loadError: String?

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private var streamTask: Task<Void, Never>?

  public init(
    sessionId: UUID,
    client: any CodevisorServerClienting,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessionId = sessionId
    self.client = client
    self.now = now
  }

  public var rows: [BotConversationRow] {
    BotConversationLayout.rows(
      messages.map { ($0, .delivered) }
        + pending.map { ($0, failedIds.contains($0.id) ? .failed : .sending) }
    )
  }

  public var lastMessageId: String? {
    pending.last?.id ?? messages.last?.id
  }

  public func start() {
    guard streamTask == nil else { return }
    let stream = client.sessionEventStream(id: sessionId, since: ServerSessionTransport.liveOnlyEventCursor)
    streamTask = Task { [weak self] in
      await self?.refreshLatest()
      do {
        for try await event in stream {
          guard let self, !Task.isCancelled else { return }
          await self.apply(event)
        }
      } catch {}
    }
  }

  public func stop() {
    streamTask?.cancel()
    streamTask = nil
  }

  public func refreshLatest() async {
    do {
      let page = try await client.botConversation(sessionId: sessionId, before: nil, limit: Self.pageSize)
      merge(latest: page)
      loadError = nil
    } catch {
      loadError = String(describing: error)
    }
    hasLoaded = true
  }

  public func loadOlder() async {
    guard hasMore, !isLoadingOlder, let oldest = messages.first else { return }
    isLoadingOlder = true
    defer { isLoadingOlder = false }
    guard
      let page = try? await client.botConversation(
        sessionId: sessionId, before: oldest.sequence, limit: Self.pageSize)
    else { return }
    for message in page.messages { upsert(message) }
    hasMore = page.hasMore
  }

  public func send(_ text: String, attachments: [ServerAttachmentRef] = []) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return }
    let message = ServerBotMessage(
      id: UUID().uuidString.lowercased(),
      sessionId: sessionId.uuidString.lowercased(),
      sequence: Int.max,
      sender: .user,
      text: trimmed,
      attachments: attachments.isEmpty ? nil : attachments,
      createdAt: BotConversationLayout.timestamp(now())
    )
    pending.append(message)
    await deliver(message)
  }

  public func retry(_ id: String) async {
    guard let message = pending.first(where: { $0.id == id }), failedIds.contains(id) else { return }
    failedIds.remove(id)
    await deliver(message)
  }

  public func upload(_ url: URL) async throws -> ServerAttachmentRef {
    let metadata = AttachmentFileStager.metadata(for: url)
    return try await client.uploadFile(name: metadata.name, mimeType: metadata.mimeType, fileURL: url).attachmentRef
  }

  private func deliver(_ message: ServerBotMessage) async {
    do {
      _ = try await client.promptSession(
        id: sessionId,
        text: message.text,
        attachments: message.attachments ?? [],
        messageId: message.id,
        clientId: nil
      )
    } catch {
      if pending.contains(where: { $0.id == message.id }) {
        failedIds.insert(message.id)
      }
    }
  }

  func apply(_ event: ServerEventEnvelope) async {
    switch event.kind {
    case "bot.message":
      guard let message = Self.decodeMessage(event.payload["message"]) else { return }
      upsert(message)
    case "session.updated":
      if let state = event.payload["turnState"]?.stringValue {
        if state == "started" { isWorking = true }
        if state == "ended" { isWorking = false }
      } else if event.payload["stopReason"]?.stringValue != nil {
        isWorking = false
      }
    case "session.error":
      isWorking = false
    case "client.synchronization":
      if event.payload["state"]?.stringValue == SessionStreamSynchronization.caughtUp.rawValue {
        await refreshLatest()
      }
    default:
      break
    }
  }

  private func merge(latest page: ServerBotConversationPage) {
    let newestKnown = messages.last?.sequence
    let oldestFetched = page.messages.first?.sequence
    if messages.isEmpty || (newestKnown.flatMap { known in oldestFetched.map { $0 > known + 1 } } ?? false) {
      messages = page.messages.sorted { $0.sequence < $1.sequence }
      hasMore = page.hasMore
      pending.removeAll { message in messages.contains { $0.id == message.id } }
    } else {
      for message in page.messages { upsert(message) }
    }
    isWorking = page.working
  }

  private func upsert(_ message: ServerBotMessage) {
    pending.removeAll { $0.id == message.id }
    failedIds.remove(message.id)
    if let index = messages.firstIndex(where: { $0.id == message.id }) {
      messages[index] = message
      return
    }
    let index = messages.firstIndex { $0.sequence > message.sequence } ?? messages.endIndex
    messages.insert(message, at: index)
  }

  static func decodeMessage(_ value: JSONValue?) -> ServerBotMessage? {
    guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(ServerBotMessage.self, from: data)
  }
}
