import Foundation
import Observation

@MainActor
@Observable
public final class BotThreadsModel {
  public static let pageSize = 50

  public private(set) var threadsByBot: [UUID: [ServerThread]] = [:]
  public private(set) var messagesByThread: [String: [ServerThreadMessage]] = [:]
  public private(set) var threadsWithOlderMessages: Set<String> = []
  public var openThreadByBot: [UUID: String] = [:]
  public private(set) var openAgentByBot: [UUID: UUID] = [:]
  @ObservationIgnored public var botLookup: (String, UUID) -> Bot? = { _, _ in nil }
  @ObservationIgnored private let machines: MachineController
  @ObservationIgnored private var serverByBot: [UUID: String] = [:]

  public init(machines: MachineController) {
    self.machines = machines
  }

  public func threads(of bot: Bot) -> [ServerThread] {
    threadsByBot[bot.id] ?? []
  }

  public func openThread(of bot: Bot) -> ServerThread? {
    guard let threadId = openThreadByBot[bot.id] else { return nil }
    return threads(of: bot).first { $0.threadId == threadId }
  }

  public func messages(in threadId: String) -> [ServerThreadMessage] {
    messagesByThread[threadId] ?? []
  }

  public func other(in thread: ServerThread, than bot: Bot) -> ServerThreadParticipant? {
    thread.participants.first { $0.botId?.lowercased() != bot.record.id.lowercased() }
  }

  public func open(_ threadId: String, of bot: Bot) async {
    if !threads(of: bot).contains(where: { $0.threadId == threadId }) { await refreshThreads(of: bot) }
    openAgentByBot[bot.id] = nil
    openThreadByBot[bot.id] = threadId
  }

  public func openAgent(of bot: Bot) -> UUID? {
    openAgentByBot[bot.id]
  }

  public func showAgent(_ sessionId: UUID, of bot: Bot) {
    openThreadByBot[bot.id] = nil
    openAgentByBot[bot.id] = sessionId
  }

  public func closePage(of bot: Bot) {
    openThreadByBot[bot.id] = nil
    openAgentByBot[bot.id] = nil
  }

  public func refreshThreads(of bot: Bot) async {
    serverByBot[bot.id] = bot.serverId
    guard let threads = try? await machines.client(for: bot.serverId).botThreads(botId: bot.record.id) else { return }
    threadsByBot[bot.id] = threads
    if let open = openThreadByBot[bot.id], !threads.contains(where: { $0.threadId == open }) {
      openThreadByBot[bot.id] = nil
    }
  }

  public func loadMessages(in threadId: String, serverId: String) async {
    guard
      let page = try? await machines.client(for: serverId)
        .threadMessages(threadId: threadId, before: nil, limit: Self.pageSize)
    else { return }
    messagesByThread[threadId] = merged(page.messages, into: messagesByThread[threadId] ?? [])
    setHasOlder(page.hasMore, in: threadId)
  }

  public func loadOlderMessages(in threadId: String, serverId: String) async {
    guard threadsWithOlderMessages.contains(threadId), let oldest = messagesByThread[threadId]?.first,
      let page = try? await machines.client(for: serverId)
        .threadMessages(threadId: threadId, before: oldest.sequence, limit: Self.pageSize)
    else { return }
    messagesByThread[threadId] = merged(page.messages, into: messagesByThread[threadId] ?? [])
    setHasOlder(page.hasMore, in: threadId)
  }

  public func receive(_ event: ServerThreadMessageEvent, serverId: String) {
    let message = event.message
    if let loaded = messagesByThread[message.threadId] {
      messagesByThread[message.threadId] = merged([message], into: loaded)
    }
    var isKnown = false
    for (botId, threads) in threadsByBot {
      guard let index = threads.firstIndex(where: { $0.threadId == message.threadId }) else { continue }
      isKnown = true
      var thread = threads[index]
      thread.lastMessage = message
      threadsByBot[botId] = [thread] + threads.filter { $0.threadId != message.threadId }
    }
    if !isKnown { refreshThreads(onServer: serverId) }
  }

  private func refreshThreads(onServer serverId: String) {
    let botIds = serverByBot.filter { $0.value == serverId }.map(\.key)
    Task { [weak self] in
      for botId in botIds {
        guard let self, let bot = self.botLookup(serverId, botId) else { continue }
        await self.refreshThreads(of: bot)
      }
    }
  }

  private func setHasOlder(_ hasOlder: Bool, in threadId: String) {
    if hasOlder { threadsWithOlderMessages.insert(threadId) } else { threadsWithOlderMessages.remove(threadId) }
  }

  private func merged(_ incoming: [ServerThreadMessage], into loaded: [ServerThreadMessage]) -> [ServerThreadMessage] {
    var bySequence = Dictionary(loaded.map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
    for message in incoming { bySequence[message.sequence] = message }
    return bySequence.values.sorted { $0.sequence < $1.sequence }
  }
}
