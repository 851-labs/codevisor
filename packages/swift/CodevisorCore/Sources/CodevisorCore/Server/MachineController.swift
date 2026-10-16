import Foundation
import Observation

public struct MachineRegistry: Sendable, Codable, Equatable {
  public var selectedMachineId: String

  public init(selectedMachineId: String = CodevisorMachine.local.id) {
    self.selectedMachineId = selectedMachineId
  }
}

public struct MachineStatus: Sendable, Equatable {
  public var isReachable: Bool
  public var label: String
  public var cloudDeviceId: String?
  public var serverId: String?
  public var features: Set<String>
  public var maxUploadBytes: Int?

  public init(
    isReachable: Bool,
    label: String,
    cloudDeviceId: String? = nil,
    serverId: String? = nil,
    features: Set<String> = [],
    maxUploadBytes: Int? = nil
  ) {
    self.isReachable = isReachable
    self.label = label
    self.cloudDeviceId = cloudDeviceId
    self.serverId = serverId
    self.features = features
    self.maxUploadBytes = maxUploadBytes
  }

  public static let legacyUploadLimitBytes = 32 * 1024 * 1024

  public var uploadLimitBytes: Int { maxUploadBytes ?? Self.legacyUploadLimitBytes }

  public var supportsScreenSharing: Bool { features.contains("screen-sharing-v1") }
  public var supportsComputerUseStreaming: Bool { features.contains("computer-use-stream-v1") }
  public var supportsLivePreview: Bool { features.contains("live-preview-v1") }
  public var supportsSimulator: Bool { features.contains("simulator-v1") }
  public var supportsBots: Bool { features.contains("bots-v1") }
}

public func codevisorMachineIsThisMac(
  _ machineId: String,
  statusByMachineId: [String: MachineStatus]
) -> Bool {
  if machineId == CodevisorMachine.local.id { return true }
  guard let local = statusByMachineId[CodevisorMachine.local.id]?.serverId,
    let other = statusByMachineId[machineId]?.serverId
  else { return false }
  return local == other
}

public enum ServerUpdatePhase: Equatable, Sendable {
  case idle
  case updating
  case failed(String)
}

@MainActor
@Observable
public final class MachineController {
  public internal(set) var registry: MachineRegistry
  var connectionsById: [String: MachineConnection] = [:]
  public var serverUpdateChannel: ServerUpdateChannel = .stable

  public typealias ClientFactory = @MainActor (CodevisorMachine) -> any CodevisorServerClienting

  let store: any PersistenceStore
  let projectList: ProjectListModel
  let workspaceSync: WorkspaceSyncModel?
  let localServer: (any LocalServerControlling)?
  let includesLocalMachine: Bool
  let injectedClientFactory: ClientFactory?
  let requestGate: ServerRequestGate
  private let key = "machines"
  let updatePollInterval: Duration
  let updatePollAttempts: Int
  let updateScheduler: ServerUpdateScheduler
  let preparationSleep: @Sendable (Duration) async throws -> Void
  let preparationRetryBaseDelay: Duration
  let navigationClock: any Clock<Duration>
  let reconnectNoticeDelay: Duration
  let reconnectNoticeScheduler: SessionConnectionRecoveryScheduler
  @ObservationIgnored public var onHarnessLifecycleChanged: ((String) -> Void)?
  @ObservationIgnored public var onHarnessAuthChanged: ((String) -> Void)?
  @ObservationIgnored public var onPluginStateChanged: ((String) -> Void)?
  @ObservationIgnored public var onMcpStateChanged: ((String) -> Void)?
  @ObservationIgnored public var onBotsChanged: ((String) -> Void)?
  @ObservationIgnored public var onPluginUpdated: ((String, String) -> Void)?
  @ObservationIgnored public var onSyncChanged: ((String, ServerSyncDocument) -> Void)?
  @ObservationIgnored public var onMachineConnected: ((String) -> Void)?
  @ObservationIgnored public var onSessionStateChanged: ((ChatSession, Int?) -> Void)?
  public init(
    store: any PersistenceStore,
    projectList: ProjectListModel,
    workspaceSync: WorkspaceSyncModel? = nil,
    localServer: (any LocalServerControlling)? = nil,
    clientFactory: ClientFactory? = nil,
    updatePollInterval: Duration = .seconds(2),
    updatePollAttempts: Int = 90,
    updateScheduler: ServerUpdateScheduler = .continuous,
    preparationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    preparationRetryBaseDelay: Duration = .seconds(1),
    navigationClock: any Clock<Duration> = ContinuousClock(),
    reconnectNoticeDelay: Duration = .seconds(5),
    reconnectNoticeScheduler: SessionConnectionRecoveryScheduler = .continuous
  ) {
    let requestGate = ServerRequestGate()
    self.store = store
    self.projectList = projectList
    self.workspaceSync = workspaceSync
    self.localServer = localServer
    self.includesLocalMachine = localServer != nil || clientFactory != nil
    self.requestGate = requestGate
    self.injectedClientFactory = clientFactory
    self.updatePollInterval = updatePollInterval
    self.updatePollAttempts = updatePollAttempts
    self.updateScheduler = updateScheduler
    self.preparationSleep = preparationSleep
    self.preparationRetryBaseDelay = preparationRetryBaseDelay
    self.navigationClock = navigationClock
    self.reconnectNoticeDelay = reconnectNoticeDelay
    self.reconnectNoticeScheduler = reconnectNoticeScheduler
    if let data = store.loadData(forKey: "machines") {
      do {
        registry = try JSONDecoder().decode(MachineRegistry.self, from: data).normalized()
      } catch {
        registry = MachineRegistry()
        handleCorruptPayload(
          store: store,
          key: "machines",
          data: data,
          error: error,
          reportTitle: "Couldn't Read Your Machine List",
          reportMessage: "The file was unreadable. A backup was saved in Codevisor's data folder."
        )
      }
    } else {
      registry = MachineRegistry()
    }
    for machine in machines {
      if clientFactory == nil {
        beginWaiting(for: machine.id, reason: .starting)
      } else {
        markReady(for: machine.id)
      }
    }
    configureNavigationStore()
  }

  @ObservationIgnored public var cloudProvider: (any CloudMachineProviding)?

  public var allMachines: [CodevisorMachine] {
    machines
      + cloudOnlyMachines.map { cloud in
        var machine = CodevisorMachine.cloud(from: cloud)
        machine.icon = icon(chosen: cloud.icon, reportedBy: machine.id)
        if let loopback = cloudProvider?.loopbackBaseURL(for: cloud) {
          machine.baseURL = loopback
        }
        return machine
      }
  }

  public var cloudOnlyMachines: [CloudMachine] {
    guard let cloudProvider, cloudProvider.isCloudSignedIn else { return [] }
    let configuredIds = Set(machines.map(\.id))
    let knownCloudIds = Set(
      statusByMachineId
        .filter { configuredIds.contains($0.key) }
        .values
        .compactMap(\.cloudDeviceId)
    )
    let knownNames: Set<String> = includesLocalMachine ? [CodevisorMachine.local.name] : []
    return cloudProvider.cloudMachines.filter {
      !knownCloudIds.contains($0.deviceId) && !knownNames.contains($0.name)
    }
  }

  private func applySelection(_ id: String) {
    guard let machine = machine(for: id) else { return }
    registry.selectedMachineId = machine.id
    persist()
  }

  private func autoSelectPreferredMachineIfNeeded() {
    guard localServer == nil,
      selectedMachineId == CodevisorMachine.local.id,
      let candidate = preferredAutoSelectionCandidate()
    else { return }
    applySelection(candidate.id)
  }

  private func preferredAutoSelectionCandidate() -> CodevisorMachine? {
    let candidates = allMachines.filter { !$0.isLocal }
    return candidates.first { isMachineOnline($0) } ?? candidates.first
  }

  private func isMachineOnline(_ machine: CodevisorMachine) -> Bool {
    if machine.isCloud {
      return cloudMachine(forMachineId: machine.id)?.online ?? false
    }
    return statusByMachineId[machine.id]?.isReachable ?? false
  }

  public func reconcileCloudSelection() {
    let selectedId = selectedMachineId
    if selectedId.hasPrefix(CodevisorMachine.cloudIdPrefix),
      machine(for: selectedId) != nil
    {
      applySelection(selectedId)
    }
    autoSelectPreferredMachineIfNeeded()
    ensureBackgroundConnections()
  }

  public func handleCloudAccountSignedOut() {
    guard selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix) else { return }
    registry.selectedMachineId = CodevisorMachine.local.id
    persist()
  }

  public func resetSelection() {
    registry = MachineRegistry()
    persist()
  }

  func persist() {
    do {
      try store.saveData(JSONEncoder().encode(registry.normalized()), forKey: key)
    } catch {
      Log.persistence.error(
        "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }
}

extension MachineRegistry {
  func normalized() -> MachineRegistry {
    let keepsSelection =
      selectedMachineId == CodevisorMachine.local.id
      || selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
    return MachineRegistry(
      selectedMachineId: keepsSelection ? selectedMachineId : CodevisorMachine.local.id)
  }
}
