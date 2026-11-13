import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Bot threads", .timeLimit(.minutes(1)))
struct BotThreadsModelTests {
  let fake = SyncFakeServerClient(projects: [], sessions: [])
  let release: Bot
  let releaseSide: ServerThreadParticipant
  let triageSide = ServerThreadParticipant(kind: .bot, name: "Triage", agentId: "chat-triage", botId: "bot-triage")
  let model: BotThreadsModel

  init() throws {
    let record = ServerBot.fixture(name: "Release")
    release = try #require(Bot(serverId: CodevisorMachine.local.id, record: record))
    releaseSide = ServerThreadParticipant(kind: .bot, name: "Release", agentId: record.sessionId, botId: record.id)
    let navigation = NavigationFixture()
    let machines = MachineController(
      store: InMemoryStore(), projectList: navigation.projectList, workspaceSync: navigation.workspaceSync,
      clientFactory: { [fake] _ in fake })
    model = BotThreadsModel(machines: machines)
    model.botLookup = { [release] _, id in id == release.id ? release : nil }
  }

  @Test("A bot's threads load with the other side of each, and the open one closes when it is gone")
  func loadsThreads() async {
    fake.setThreads([thread("t1", last: message(1, triageSide))], ofBot: release.record.id)

    await model.refreshThreads(of: release)
    model.openThreadByBot[release.id] = "t1"

    #expect(model.threads(of: release).map(\.threadId) == ["t1"])
    #expect(model.openThread(of: release)?.threadId == "t1")
    #expect(model.other(in: model.threads(of: release)[0], than: release) == triageSide)

    fake.setThreads([], ofBot: release.record.id)
    await model.refreshThreads(of: release)

    #expect(model.openThread(of: release) == nil)
    #expect(model.openThreadByBot[release.id] == nil)
  }

  @Test("Opening a thread the bot's list has not loaded yet loads the list first")
  func opensAThreadByItsId() async {
    fake.setThreads([thread("t1", last: message(1, triageSide))], ofBot: release.record.id)

    await model.open("t1", of: release)

    #expect(model.openThread(of: release)?.threadId == "t1")
  }

  @Test("A thread's messages load newest page first, and older pages join in order")
  func pagesMessages() async {
    let all = (1...(BotThreadsModel.pageSize + 2)).map { message($0, $0.isMultiple(of: 2) ? triageSide : releaseSide) }
    fake.setMessages(all, inThread: "t1")

    await model.loadMessages(in: "t1", serverId: release.serverId)

    #expect(model.messages(in: "t1").map(\.sequence) == Array(3...(BotThreadsModel.pageSize + 2)))
    #expect(model.threadsWithOlderMessages.contains("t1"))

    await model.loadOlderMessages(in: "t1", serverId: release.serverId)

    #expect(model.messages(in: "t1").map(\.sequence) == Array(1...(BotThreadsModel.pageSize + 2)))
    #expect(!model.threadsWithOlderMessages.contains("t1"))
  }

  @Test("A new message joins an open thread and moves that thread to the top of its bot's list")
  func receivesMessages() async {
    fake.setThreads([thread("t2"), thread("t1", last: message(1, triageSide))], ofBot: release.record.id)
    fake.setMessages([message(1, triageSide)], inThread: "t1")
    await model.refreshThreads(of: release)
    await model.loadMessages(in: "t1", serverId: release.serverId)

    model.receive(ServerThreadMessageEvent(message: message(2, releaseSide)), serverId: release.serverId)

    #expect(model.messages(in: "t1").map(\.sequence) == [1, 2])
    #expect(model.threads(of: release).map(\.threadId) == ["t1", "t2"])
    #expect(model.threads(of: release)[0].lastMessage?.sequence == 2)
    #expect(model.messages(in: "t2").isEmpty)
  }

  @Test("A message in a thread not seen before reloads the threads of the bots on that machine")
  func discoversNewThreads() async {
    await model.refreshThreads(of: release)
    fake.setThreads([thread("t9", last: message(1, triageSide, in: "t9"))], ofBot: release.record.id)

    model.receive(
      ServerThreadMessageEvent(message: message(1, triageSide, in: "t9")), serverId: release.serverId)

    await awaitObserved { !model.threads(of: release).isEmpty }
    #expect(model.threads(of: release).map(\.threadId) == ["t9"])
  }

  private func thread(_ id: String, last: ServerThreadMessage? = nil) -> ServerThread {
    ServerThread(threadId: id, participants: [releaseSide, triageSide], lastMessage: last)
  }

  private func message(
    _ sequence: Int, _ from: ServerThreadParticipant, in threadId: String = "t1"
  )
    -> ServerThreadMessage
  {
    ServerThreadMessage(
      id: "\(threadId)-\(sequence)", threadId: threadId, sequence: sequence, from: from, text: "Text \(sequence)",
      createdAt: "2026-11-12T00:00:00.000Z")
  }
}
