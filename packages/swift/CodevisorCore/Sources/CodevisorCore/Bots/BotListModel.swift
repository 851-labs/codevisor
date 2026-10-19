import Foundation
import Observation

@MainActor
@Observable
public final class BotListModel {
  public private(set) var recordsByServer: [String: [ServerBot]] = [:]
  @ObservationIgnored private let machines: MachineController
  @ObservationIgnored private var refreshGenerations: [String: UInt64] = [:]

  public init(machines: MachineController) {
    self.machines = machines
  }

  public var bots: [Bot] {
    var seen = Set<String>()
    return machineIdsByServer.flatMap { machineId in
      (recordsByServer[machineId] ?? []).compactMap { record in
        seen.insert(record.id).inserted ? Bot(serverId: machineId, record: record) : nil
      }
    }
  }

  public var botMachines: [CodevisorMachine] {
    let ids = Set(machineIdsByServer.filter(supportsBots(on:)))
    return machines.allMachines.filter { ids.contains($0.id) }
  }

  public func supportsBots(on serverId: String) -> Bool {
    machines.statusByMachineId[serverId]?.supportsBots == true
  }

  public func supportsProjectChanges(on serverId: String) -> Bool {
    machines.statusByMachineId[serverId]?.supportsBotProjectChanges == true
  }

  private var machineIdsByServer: [String] {
    var seen = Set<String>()
    return machines.allMachines.map(\.id).filter { machineId in
      seen.insert(machines.syncKey(forMachineId: machineId) ?? machineId).inserted
    }
  }

  public func bot(serverId: String, id: UUID) -> Bot? {
    bots.first { $0.serverId == serverId && $0.id == id }
  }

  public func bot(forSession sessionId: UUID, serverId: String) -> Bot? {
    bots.first { $0.serverId == serverId && $0.sessionId == sessionId }
  }

  public func bot(forWorkspace workspaceId: UUID, serverId: String) -> Bot? {
    bots.first { $0.serverId == serverId && $0.workspaceId == workspaceId }
  }

  public func refresh(serverId: String) async {
    let generation = (refreshGenerations[serverId] ?? 0) + 1
    refreshGenerations[serverId] = generation
    guard supportsBots(on: serverId) else {
      recordsByServer[serverId] = nil
      return
    }
    guard let records = try? await machines.client(for: serverId).listBots(),
      refreshGenerations[serverId] == generation
    else { return }
    recordsByServer[serverId] = records
  }

  @discardableResult
  public func create(_ request: ServerCreateBotRequest, on serverId: String) async throws -> Bot {
    let record = try await machines.client(for: serverId).createBot(request)
    await machines.refreshNavigationState(for: serverId)
    store(record, on: serverId)
    guard let bot = Bot(serverId: serverId, record: record) else {
      throw CodevisorServerClientError.invalidResponse
    }
    return bot
  }

  public func update(_ bot: Bot, _ request: ServerUpdateBotRequest) async throws {
    let record = try await machines.client(for: bot.serverId)
      .updateBot(id: bot.record.id, request)
    store(record, on: bot.serverId)
  }

  public func addProject(_ projectId: UUID, to bot: Bot) async throws {
    let record = try await machines.client(for: bot.serverId)
      .addBotProject(botId: bot.record.id, projectId: projectId.uuidString.lowercased())
    store(record, on: bot.serverId)
  }

  public func removeProject(_ projectId: UUID, from bot: Bot) async throws {
    let record = try await machines.client(for: bot.serverId)
      .removeBotProject(botId: bot.record.id, projectId: projectId.uuidString.lowercased())
    store(record, on: bot.serverId)
  }

  public func delete(_ bot: Bot) async throws {
    try await machines.client(for: bot.serverId).deleteBot(id: bot.record.id)
    refreshGenerations[bot.serverId, default: 0] += 1
    recordsByServer[bot.serverId]?.removeAll { $0.id == bot.record.id }
    await machines.refreshNavigationState(for: bot.serverId)
  }

  private func store(_ record: ServerBot, on serverId: String) {
    refreshGenerations[serverId, default: 0] += 1
    var records = recordsByServer[serverId] ?? []
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      records[index] = record
    } else {
      records.append(record)
    }
    recordsByServer[serverId] = records
  }
}
