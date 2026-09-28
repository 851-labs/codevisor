import Foundation
import Observation

/// Persisted with synthesized `Codable`, which ignores unknown keys: legacy
/// appearance metadata, the retired `hasExplicitMachineSelection` flag, and
/// the retired directly paired `remoteMachines` still decode and disappear
/// the next time the registry is saved.
public struct MachineRegistry: Sendable, Codable, Equatable {
  public var selectedMachineId: String

  public init(selectedMachineId: String = CodevisorMachine.local.id) {
    self.selectedMachineId = selectedMachineId
  }
}

public struct MachineStatus: Sendable, Equatable {
  public var isReachable: Bool
  public var label: String
  /// The machine's cloud device id (from /v1/info) when it is connected to
  /// Codevisor Cloud — the identity that deduplicates this Mac against its
  /// own entry in the cloud machine list.
  public var cloudDeviceId: String?
  /// The server's own stable id (config.id from /v1/info) — the key its
  /// entries carry in the fleet's sync namespaces. Distinct from the
  /// CLIENT-side machine id ("local", "cloud:<deviceId>").
  public var serverId: String?
  /// The capabilities the server advertised on its last probe (the
  /// `features` list from /v1/info). Cached here so views can gate on a
  /// capability synchronously instead of re-probing the server on every
  /// mount — a probe-after-render pops the gated UI in late.
  public var features: Set<String>
  /// The largest attachment upload the server advertised (`maxUploadBytes`
  /// from /v1/info); nil for servers that predate the field.
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

  /// What servers accepted before they advertised a limit: their cloud
  /// relay buffered each request body and capped it at 32 MiB.
  public static let legacyUploadLimitBytes = 32 * 1024 * 1024

  /// The largest attachment this machine accepts.
  public var uploadLimitBytes: Int { maxUploadBytes ?? Self.legacyUploadLimitBytes }

  /// Whether the server can drive a native screen-sharing session.
  public var supportsScreenSharing: Bool { features.contains("screen-sharing-v1") }
  /// The machine can stream the window a chat's agent controls through
  /// Computer Use to that chat's viewers.
  public var supportsComputerUseStreaming: Bool { features.contains("computer-use-stream-v1") }
}

/// Whether `machineId` reaches this Mac's own server: the local entry, or a
/// cloud entry that probed as the same server. A Mac can show
/// up under more than one entry, and work on any of them runs here.
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

/// Progress of a client-triggered update of one explicit machine's server.
public enum ServerUpdatePhase: Equatable, Sendable {
  case idle
  case updating
  case failed(String)
}

@MainActor
@Observable
public final class MachineController {
  public internal(set) var registry: MachineRegistry
  /// One connection record per machine this controller has touched — the
  /// single home for a machine's live client-side state. The legacy
  /// `*ByMachineId` dictionaries are read-only projections of these (see
  /// MachineConnection.swift).
  var connectionsById: [String: MachineConnection] = [:]
  /// The release feed remote server update checks follow — mirrors the
  /// app's alpha-updates setting. AppEnvironment keeps it in sync.
  public var serverUpdateChannel: ServerUpdateChannel = .stable

  public typealias ClientFactory = @MainActor (CodevisorMachine) -> any CodevisorServerClienting

  let store: any PersistenceStore
  let projectList: ProjectListModel
  let workspaceSync: WorkspaceSyncModel?
  // Internal so split-off extension files (MachineConnection) can key the
  // fleet's composition on it: platforms without a local server have no
  // "Local" machine at all.
  let localServer: (any LocalServerControlling)?
  /// Injected transports model a local machine in previews and unit tests;
  /// production client-only platforms omit both an embedded server and a
  /// factory, so they still have no phantom local target.
  let includesLocalMachine: Bool
  /// Previews and unit tests inject transports that stand in for every
  /// machine the fleet resolves, cloud machines included. Production leaves
  /// it nil: cloud machines ride the relay, the local machine plain HTTP.
  let injectedClientFactory: ClientFactory?
  let requestGate: ServerRequestGate
  private let key = "machines"
  /// How long to wait between reachability probes while the remote server
  /// restarts into its updated version. Injectable so tests run fast.
  let updatePollInterval: Duration
  let updatePollAttempts: Int
  let updateScheduler: ServerUpdateScheduler
  /// Backoff base for automatic retries of a failed remote preparation
  /// (base · 2^n, capped). Injectable so tests run fast.
  let preparationSleep: @Sendable (Duration) async throws -> Void
  let preparationRetryBaseDelay: Duration
  /// Shared scheduler for navigation debounce, timeout, and retry deadlines.
  let navigationClock: any Clock<Duration>
  /// Invoked when a `harness.lifecycle.updated` event arrives for a machine
  /// — the AppEnvironment bridges it to its harness-catalog revision so
  /// mounted pickers and settings panes refetch.
  @ObservationIgnored public var onHarnessLifecycleChanged: ((String) -> Void)?
  /// Invoked when a `harness.auth.updated` event arrives for a machine — a
  /// sign-in probe settled or an account changed state there. The
  /// AppEnvironment bridges it to the same catalog revision, without the
  /// update-center inventory re-read a lifecycle change also triggers.
  @ObservationIgnored public var onHarnessAuthChanged: ((String) -> Void)?
  /// Invoked when a `plugin.state.updated` event arrives for a machine —
  /// the AppEnvironment bridges it to its plugin-state revision so mounted
  /// settings panes and New Tab cards refetch.
  @ObservationIgnored public var onPluginStateChanged: ((String) -> Void)?
  /// Invoked when an `mcp.updated` event arrives for a machine — a managed
  /// MCP server's visible state changed there (connection settled, OAuth
  /// expired, a synced enable flip applied). The AppEnvironment bridges it
  /// to its MCP-state revision so mounted settings panes refetch.
  @ObservationIgnored public var onMcpStateChanged: ((String) -> Void)?
  /// Invoked when a `plugin.updated` event arrives (the plugin's code or
  /// install changed: restart, re-import, re-link) — the AppEnvironment
  /// bridges it to a per-plugin revision so that plugin's open panes
  /// re-run their token→load flow. Arguments: (serverId, pluginId).
  @ObservationIgnored public var onPluginUpdated: ((String, String) -> Void)?
  /// Invoked when a `sync.changed` event arrives — a machine's config
  /// replica changed; ConfigSync adopts and re-gossips it. Arguments:
  /// (serverId, changed document).
  @ObservationIgnored public var onSyncChanged: ((String, ServerSyncDocument) -> Void)?
  /// Invoked when a machine's live connection comes up — ConfigSync converges it
  /// immediately instead of waiting for the next periodic sweep.
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
    navigationClock: any Clock<Duration> = ContinuousClock()
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
        // Injected clients are previews/test transports with no
        // external process lifecycle for this controller to await.
        markReady(for: machine.id)
      }
    }
    configureNavigationStore()
  }

  /// Bridges the cloud account feature in (set once at composition time).
  /// While signed in, its machines join `allMachines` and its relay configs
  /// back the clients for `cloud:` machine ids.
  @ObservationIgnored public var cloudProvider: (any CloudMachineProviding)?

  /// Every machine the app can reach: this Mac's embedded machine (where
  /// there is one) plus one synthesized entry per cloud machine that isn't
  /// this Mac's own cloud registration.
  public var allMachines: [CodevisorMachine] {
    machines
      + cloudOnlyMachines.map { cloud in
        var machine = CodevisorMachine.cloud(from: cloud)
        // A real loopback address (bridged onto the relay) replaces the
        // placeholder once the machine's bridge is listening, so baseURL
        // consumers like the external terminal proxy can actually dial it.
        if let loopback = cloudProvider?.loopbackBaseURL(for: cloud) {
          machine.baseURL = loopback
        }
        return machine
      }
  }

  /// Cloud machines that aren't already represented by the local machine,
  /// so this Mac appears exactly once. Primary match: the cloud device id
  /// the local server advertises via /v1/info (or adopted at registration).
  /// Fallback while its status probe hasn't answered yet: display name.
  /// Empty while signed out — cloud entries only exist alongside a live
  /// account.
  public var cloudOnlyMachines: [CloudMachine] {
    guard let cloudProvider, cloudProvider.isCloudSignedIn else { return [] }
    // Statuses of cloud-synthesized entries also carry the device id;
    // only the configured (local) machine's status counts for
    // deduplication — a cloud entry must not hide itself.
    let configuredIds = Set(machines.map(\.id))
    let knownCloudIds = Set(
      statusByMachineId
        .filter { configuredIds.contains($0.key) }
        .values
        .compactMap(\.cloudDeviceId)
    )
    let knownNames = Set(machines.map(\.name))
    return cloudProvider.cloudMachines.filter {
      !knownCloudIds.contains($0.deviceId) && !knownNames.contains($0.name)
    }
  }

  /// Persists the legacy composer fallback without changing any machine's
  /// connection, request gate, update state, or navigation state. New
  /// composer state lives in ComposerDefaultsStore; this value remains only
  /// for migration compatibility with older installs.
  private func applySelection(_ id: String) {
    guard let machine = machine(for: id) else { return }
    registry.selectedMachineId = machine.id
    persist()
  }

  /// When only the local placeholder is selected on a client-only platform,
  /// adopt the best available real machine. Client-only platforms (no local
  /// server) don't list "Local" at all, so a selection resting on it is
  /// never a real choice, and stranding the user there
  /// renders an unreachable fleet. macOS supplies a working local server
  /// and keeps it as the default, even when cloud machines are already on
  /// the account. No-op when a real machine is already selected or no
  /// non-local machine exists.
  private func autoSelectPreferredMachineIfNeeded() {
    guard localServer == nil,
      selectedMachineId == CodevisorMachine.local.id,
      let candidate = preferredAutoSelectionCandidate()
    else { return }
    applySelection(candidate.id)
  }

  /// The machine auto-selection should adopt: any non-local machine, with an
  /// online one preferred over an offline one; ties (and the all-offline
  /// case) break by `allMachines` list order. With a single cloud machine present,
  /// that machine is the only candidate and is chosen.
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

  /// Reconciles the legacy composer fallback after cloud discovery and
  /// starts explicit per-machine connections. It never changes routing for
  /// an open chat or any other machine-scoped operation.
  public func reconcileCloudSelection() {
    let selectedId = selectedMachineId
    if selectedId.hasPrefix(CodevisorMachine.cloudIdPrefix),
      machine(for: selectedId) != nil
    {
      applySelection(selectedId)
    }
    // A fresh sign-in with machines: adopt one so the user isn't left on
    // the local placeholder.
    autoSelectPreferredMachineIfNeeded()
    // Newly arrived cloud machines get their own streams regardless of
    // which target the composer remembers.
    ensureBackgroundConnections()
  }

  /// Cloud entries only exist while signed in; when the account signs out
  /// with a cloud machine selected, fall back to the local machine so the
  /// app never points at a machine that no longer exists.
  public func handleCloudAccountSignedOut() {
    guard selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix) else { return }
    registry.selectedMachineId = CodevisorMachine.local.id
    persist()
  }

  /// Forgets the remembered composer fallback (the delete-all-data reset).
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
  /// Keeps only a selection that can still resolve: the local machine or a
  /// cloud machine. Cloud selections persist by id (stable across
  /// launches); when the machine isn't available (signed out), selection
  /// falls back to local at resolution time instead of being rewritten
  /// here. Anything else (a retired directly paired machine) resets.
  func normalized() -> MachineRegistry {
    let keepsSelection =
      selectedMachineId == CodevisorMachine.local.id
      || selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
    return MachineRegistry(
      selectedMachineId: keepsSelection ? selectedMachineId : CodevisorMachine.local.id)
  }
}
