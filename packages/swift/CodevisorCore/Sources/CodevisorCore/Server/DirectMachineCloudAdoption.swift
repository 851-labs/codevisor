import CodevisorClient
import CodevisorCloud
import Foundation

public struct PendingDirectMachine: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var baseURL: URL
  public var legacyToken: String?

  public init(id: String, name: String, baseURL: URL, legacyToken: String? = nil) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.legacyToken = legacyToken
  }
}

@MainActor
public final class DirectMachineCloudAdoption {
  public typealias TokenReader = @Sendable (String) throws -> String?
  public typealias TokenRemover = @Sendable (String) throws -> Void
  public typealias ClientFactory = (CodevisorServerConfig) -> any CodevisorServerClienting

  nonisolated static let storeKey = "machines.pendingCloudAdoption"

  public var onSettled: ((_ oldMachineId: String, _ cloudMachineId: String?) -> Void)?

  private let store: any PersistenceStore
  private let readToken: TokenReader
  private let removeToken: TokenRemover
  private let clientFactory: ClientFactory
  private var pending: [PendingDirectMachine]
  private var isRunning = false

  public init(
    store: any PersistenceStore,
    readToken: @escaping TokenReader = RetiredMachineCredentials.token,
    removeToken: @escaping TokenRemover = RetiredMachineCredentials.removeToken,
    clientFactory: @escaping ClientFactory = { CodevisorServerClient(config: $0) }
  ) {
    self.store = store
    self.readToken = readToken
    self.removeToken = removeToken
    self.clientFactory = clientFactory
    pending = Self.load(from: store)
  }

  public var hasPendingMachines: Bool { !pending.isEmpty }

  nonisolated static func enqueue(_ machines: [PendingDirectMachine], in store: any PersistenceStore) throws {
    guard !machines.isEmpty else { return }
    var queued = load(from: store)
    let known = Set(queued.map(\.id))
    queued += machines.filter { !known.contains($0.id) }
    try store.saveData(JSONEncoder().encode(queued), forKey: storeKey)
  }

  public func adoptPendingMachines(cloud: any CloudMachineProviding) async {
    guard !isRunning, !pending.isEmpty, cloud.isCloudSignedIn, cloud.isCloudRosterVerified else {
      return
    }
    isRunning = true
    defer { isRunning = false }
    for machine in pending {
      let deviceId = await register(machine, cloud: cloud)
      if let deviceId {
        Log.machines.log(
          "Moved directly paired machine \(machine.id, privacy: .public) onto the cloud account as \(deviceId, privacy: .public)"
        )
      } else {
        Log.machines.notice("Dropped directly paired machine \(machine.id, privacy: .public)")
      }
      try? removeToken(machine.id)
      pending.removeAll { $0.id == machine.id }
      persist()
      onSettled?(machine.id, deviceId.map { CodevisorMachine.cloudIdPrefix + $0 })
    }
  }

  public func reset() {
    for machine in pending { try? removeToken(machine.id) }
    pending = []
    persist()
  }

  private func register(_ machine: PendingDirectMachine, cloud: any CloudMachineProviding) async -> String? {
    let token = machine.legacyToken ?? (try? readToken(machine.id)) ?? nil
    let client = clientFactory(CodevisorServerConfig(baseURL: machine.baseURL, bearerToken: token))
    do {
      let registration = try await client.cloudRegistration()
      if registration.connected {
        let accountDeviceIds = Set(cloud.cloudMachines.map(\.deviceId))
        return registration.deviceId.flatMap { accountDeviceIds.contains($0) ? $0 : nil }
      }
      return try await cloud.adoptDirectMachine(using: client, name: machine.name)
    } catch {
      Log.machines.debug(
        "Directly paired machine \(machine.id, privacy: .public) could not be moved: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private func persist() {
    do {
      if pending.isEmpty {
        try store.removeData(forKey: Self.storeKey)
      } else {
        try store.saveData(JSONEncoder().encode(pending), forKey: Self.storeKey)
      }
    } catch {
      Log.persistence.error(
        "Failed to save \(Self.storeKey, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  private nonisolated static func load(from store: any PersistenceStore) -> [PendingDirectMachine] {
    guard let data = store.loadData(forKey: storeKey) else { return [] }
    return (try? JSONDecoder().decode([PendingDirectMachine].self, from: data)) ?? []
  }
}
