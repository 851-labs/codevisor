import Foundation
import Observation

public enum MachineControllerError: Error, Equatable, Sendable, LocalizedError {
    case invalidHost(String)
    case cannotRemoveLocal
    case cannotRenameLocal

    public var errorDescription: String? {
        switch self {
        case let .invalidHost(host):
            "“\(host)” isn't a valid host. Enter a hostname or IP address, like 192.168.1.20 or mac-studio.local."
        case .cannotRemoveLocal:
            "This Mac can't be removed from the machine list."
        case .cannotRenameLocal:
            "This Mac can't be renamed here. Its name follows the computer name in System Settings."
        }
    }
}

public struct MachineRegistry: Sendable, Codable, Equatable {
    public var selectedMachineId: String
    /// True once the user has explicitly chosen a machine (an actual tap in
    /// the picker). While false, the controller may auto-select the best
    /// available real machine so a fresh sign-in doesn't strand the user on
    /// the local placeholder (which is non-functional on iOS). Auto-selection
    /// never sets this, so a vanished auto-pick can be replaced next refresh.
    public var hasExplicitMachineSelection: Bool
    public var remoteMachines: [CodevisorMachine]

    public init(
        selectedMachineId: String = CodevisorMachine.local.id,
        hasExplicitMachineSelection: Bool = false,
        remoteMachines: [CodevisorMachine] = []
    ) {
        self.selectedMachineId = selectedMachineId
        self.hasExplicitMachineSelection = hasExplicitMachineSelection
        self.remoteMachines = remoteMachines
    }

    /// Custom decode keeps registries persisted before explicit selection
    /// existed loadable. Unknown legacy appearance keys are intentionally
    /// ignored and disappear the next time the registry is saved.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedMachineId = try container.decode(String.self, forKey: .selectedMachineId)
        // Registries persisted before this flag existed decode as "no explicit
        // choice yet", so they benefit from auto-selection like fresh installs.
        hasExplicitMachineSelection =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .hasExplicitMachineSelection
            ) ?? false
        remoteMachines = try container.decode([CodevisorMachine].self, forKey: .remoteMachines)
    }
}

public struct MachineStatus: Sendable, Equatable {
    public var isReachable: Bool
    public var label: String
    /// The machine's cloud device id (from /v1/info) when it is connected to
    /// Codevisor Cloud — the identity that deduplicates it against the cloud
    /// machine list.
    public var cloudDeviceId: String?

    public init(isReachable: Bool, label: String, cloudDeviceId: String? = nil) {
        self.isReachable = isReachable
        self.label = label
        self.cloudDeviceId = cloudDeviceId
    }
}

/// Progress of a client-triggered update of the selected machine's server.
public enum ServerUpdatePhase: Equatable, Sendable {
    case idle
    case updating
    case failed(String)
}

@MainActor
@Observable
public final class MachineController {
    public private(set) var registry: MachineRegistry
    public private(set) var statusByMachineId: [String: MachineStatus] = [:]
    public private(set) var updateInfoByMachineId: [String: ServerUpdateInfo] = [:]
    public private(set) var availabilityByMachineId: [String: ServerAvailability] = [:]
    public internal(set) var navigationSyncStateByMachineId: [String: NavigationSyncState] = [:]
    /// The release feed remote server update checks follow — mirrors the
    /// app's alpha-updates setting. AppEnvironment keeps it in sync.
    public var serverUpdateChannel: ServerUpdateChannel = .stable
    public private(set) var serverUpdatePhase: ServerUpdatePhase = .idle

    public typealias ClientFactory = @MainActor (CodevisorMachine) -> any CodevisorServerClienting

    private let store: any PersistenceStore
    /// Live apps keep bearer tokens in Keychain. Nil preserves the embedded
    /// token behavior for isolated previews/tests that do not have a device
    /// credential store.
    private let credentialStore: (any MachineCredentialStore)?
    let projectList: ProjectListModel
    let workspaceSync: WorkspaceSyncModel?
    private let localServer: (any LocalServerControlling)?
    private let clientFactory: ClientFactory
    private let requestGate: ServerRequestGate
    private let key = "machines"
    /// How long to wait between reachability probes while the remote server
    /// restarts into its updated version. Injectable so tests run fast.
    private let updatePollInterval: Duration
    private let updatePollAttempts: Int
    @ObservationIgnored private var credentialReadFailures: Set<String> = []
    @ObservationIgnored var eventSyncTask: Task<Void, Never>?
    @ObservationIgnored var pendingRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var preparationMachineId: String?
    @ObservationIgnored private var preparationToken: UUID?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored var navigationSyncMachineId: String?
    @ObservationIgnored var navigationSyncToken: UUID?
    @ObservationIgnored var navigationSyncTask: Task<Void, Never>?
    /// Invoked when a `harness.lifecycle.updated` event arrives for a machine
    /// — the AppEnvironment bridges it to its harness-catalog revision so
    /// mounted pickers and settings panes refetch.
    @ObservationIgnored public var onHarnessLifecycleChanged: ((String) -> Void)?
    /// Invoked when a `plugin.state.updated` event arrives for a machine —
    /// the AppEnvironment bridges it to its plugin-state revision so mounted
    /// settings panes and New Tab cards refetch.
    @ObservationIgnored public var onPluginStateChanged: ((String) -> Void)?
    /// Invoked when a `plugin.updated` event arrives (the plugin's code or
    /// install changed: restart, re-import, re-link) — the AppEnvironment
    /// bridges it to a per-plugin revision so that plugin's open panes
    /// re-run their token→load flow. Arguments: (serverId, pluginId).
    @ObservationIgnored public var onPluginUpdated: ((String, String) -> Void)?

    public init(
        store: any PersistenceStore,
        projectList: ProjectListModel,
        workspaceSync: WorkspaceSyncModel? = nil,
        credentialStore: (any MachineCredentialStore)? = nil,
        localServer: (any LocalServerControlling)? = nil,
        clientFactory: ClientFactory? = nil,
        updatePollInterval: Duration = .seconds(2),
        updatePollAttempts: Int = 90
    ) {
        let requestGate = ServerRequestGate()
        self.store = store
        self.credentialStore = credentialStore
        self.projectList = projectList
        self.workspaceSync = workspaceSync
        self.localServer = localServer
        self.requestGate = requestGate
        self.clientFactory =
            clientFactory ?? {
                CodevisorServerClient(
                    config: $0.serverConfig,
                    requestGate: requestGate,
                    machineId: $0.id
                )
            }
        self.updatePollInterval = updatePollInterval
        self.updatePollAttempts = updatePollAttempts
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
        if let credentialStore {
            var migratedCredentialIDs: Set<String> = []
            for index in registry.remoteMachines.indices {
                let id = registry.remoteMachines[index].id
                do {
                    if let embedded = registry.remoteMachines[index].token, !embedded.isEmpty {
                        try credentialStore.saveToken(embedded, forMachineID: id)
                        guard try credentialStore.token(forMachineID: id) == embedded else {
                            throw ClientDatabaseError(
                                operation: "credential read-back",
                                detail: "Token for \(id) did not round-trip"
                            )
                        }
                        migratedCredentialIDs.insert(id)
                    }
                    registry.remoteMachines[index].token =
                        try credentialStore.token(forMachineID: id)
                    credentialReadFailures.remove(id)
                } catch {
                    // A locked or temporarily unavailable Keychain must not
                    // make a valid machine registry look corrupt or cause a
                    // later unrelated save to delete its credential.
                    credentialReadFailures.insert(id)
                    Log.persistence.error(
                        "Failed to load credential for \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
            if !migratedCredentialIDs.isEmpty {
                do {
                    var sanitized = registry
                    for index in sanitized.remoteMachines.indices
                    where migratedCredentialIDs.contains(sanitized.remoteMachines[index].id) {
                        sanitized.remoteMachines[index].token = nil
                    }
                    try store.saveData(
                        JSONEncoder().encode(sanitized.normalized()),
                        forKey: "machines"
                    )
                } catch {
                    Log.persistence.error(
                        "Failed to sanitize machine credentials: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        if clientFactory == nil {
            beginWaiting(
                for: selectedMachine.id,
                reason: selectedMachine.isLocal ? .starting : .connecting
            )
        } else {
            // Injected clients are previews/test transports with no external
            // process lifecycle for this controller to await.
            markReady(for: selectedMachine.id)
        }
        projectList.selectServer(
            serverId: selectedMachine.id,
            serverClient: selectedClient,
            refresh: false
        )
    }

    /// Bridges the cloud account feature in (set once at composition time).
    /// While signed in, its machines join `allMachines` and its relay configs
    /// back the clients for `cloud:` machine ids.
    @ObservationIgnored public var cloudProvider: (any CloudMachineProviding)?

    public var machines: [CodevisorMachine] {
        [CodevisorMachine.local] + registry.remoteMachines
    }

    /// Every machine the app can reach, however it arrives: the configured
    /// (local + remote) machines plus one synthesized entry per cloud machine
    /// that no configured machine already represents.
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

    /// Cloud machines that aren't already represented by a configured machine,
    /// so each machine appears exactly once. Primary match: the cloud device
    /// id each connected server advertises via /v1/info. Fallback while a
    /// server's status probe hasn't answered yet: display name. Empty while
    /// signed out — cloud entries only exist alongside a live account.
    public var cloudOnlyMachines: [CloudMachine] {
        guard let cloudProvider, cloudProvider.isCloudSignedIn else { return [] }
        // Statuses of cloud-synthesized entries also carry the device id;
        // only CURRENTLY CONFIGURED machines' statuses count for
        // deduplication — a cloud entry dedups itself through its own probe,
        // and a machine removed from the registry (individually or by the
        // delete-all-data reset) must not keep hiding its cloud twin through
        // a stale status left in this in-memory map.
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

    /// The cloud presence entry backing a `cloud:` machine id, if any.
    public func cloudMachine(forMachineId id: String) -> CloudMachine? {
        guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id),
            let cloudProvider, cloudProvider.isCloudSignedIn
        else { return nil }
        return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
    }

    public var selectedMachineId: String {
        registry.selectedMachineId
    }

    public var selectedMachine: CodevisorMachine {
        machine(for: registry.selectedMachineId) ?? CodevisorMachine.local
    }

    public var selectedClient: any CodevisorServerClienting {
        client(for: selectedMachine.id)
    }

    public var selectedServerAvailability: ServerAvailability {
        availabilityByMachineId[selectedMachineId] ?? .ready
    }

    public var selectedNavigationSyncState: NavigationSyncState {
        navigationSyncStateByMachineId[selectedMachineId] ?? .cached
    }

    public func machine(for id: String) -> CodevisorMachine? {
        allMachines.first { $0.id == id }
    }

    public func client(for machineId: String) -> any CodevisorServerClienting {
        // Cloud machines get a real HTTP client whose transports tunnel every
        // request/WebSocket through the account's encrypted relay, so all
        // existing features work unchanged.
        if let config = relayServerConfig(forMachineId: machineId) {
            return CodevisorServerClient(
                config: config,
                requestGate: requestGate,
                machineId: machineId
            )
        }
        let machine = machine(for: machineId) ?? CodevisorMachine.local
        return clientFactory(machine)
    }

    /// The server config for a machine id — relay-backed for cloud machines,
    /// plain otherwise. Consumers that build their own transports from a
    /// config (terminals) use this so cloud machines tunnel automatically.
    public func serverConfig(for machineId: String) -> CodevisorServerConfig {
        if let config = relayServerConfig(forMachineId: machineId) {
            return config
        }
        return (machine(for: machineId) ?? selectedMachine).serverConfig
    }

    private func relayServerConfig(forMachineId machineId: String) -> CodevisorServerConfig? {
        guard let cloud = cloudMachine(forMachineId: machineId) else { return nil }
        return cloudProvider?.relayServerConfig(for: cloud)
    }

    /// The machine's effective HTTP origin for consumers that must dial a
    /// real socket instead of the in-process relay transports (plugin pane
    /// webviews, external helper processes): direct machines answer their
    /// configured baseURL; cloud machines lazily start the in-app loopback
    /// bridge and answer its `http://127.0.0.1:<port>` address, waiting
    /// (bounded) for the listener to come up. Nil when the machine is gone or
    /// the relay bridge can't start (signed out, relay down).
    public func effectiveHTTPBaseURL(
        forMachineId machineId: String,
        timeout: Duration = .seconds(10)
    ) async -> URL? {
        guard let cloud = cloudMachine(forMachineId: machineId) else {
            return machine(for: machineId)?.baseURL
        }
        guard let cloudProvider else { return nil }
        // The first call kicks the bridge off; poll for the published port —
        // it appears via an observable the synchronous accessor can't await.
        let deadline = ContinuousClock.now + timeout
        while true {
            if let url = cloudProvider.loopbackBaseURL(for: cloud) { return url }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func selectMachine(_ id: String) {
        guard machine(for: id) != nil else { return }
        // An explicit tap is a durable choice: record it so auto-selection
        // stops preferring another machine over the user's decision.
        registry.hasExplicitMachineSelection = true
        applySelection(id)
    }

    /// Points the registry, request gate, and project list at `id` without
    /// touching `hasExplicitMachineSelection`. Auto-selection uses this so an
    /// auto-pick can be superseded (or replaced) later; `selectMachine` layers
    /// the explicit-choice flag on top.
    private func applySelection(_ id: String) {
        guard let machine = machine(for: id) else { return }
        registry.selectedMachineId = machine.id
        beginWaiting(for: machine.id, reason: machine.isLocal ? .starting : .connecting)
        persist()
        // Machine preparation owns the one authoritative refresh. Starting a
        // second fire-and-forget refresh here lets two snapshots invalidate
        // each other as soon as the request gate opens.
        projectList.selectServer(
            serverId: machine.id,
            serverClient: client(for: machine.id),
            refresh: false
        )
    }

    /// When the user hasn't made an explicit choice yet and only the local
    /// placeholder is selected, adopt the best available real machine. On iOS
    /// the local machine is a non-functional placeholder, so a fresh sign-in
    /// that has cloud machines should land on one of them instead of stranding
    /// the user on "Local". macOS supplies a working local server and keeps it
    /// as the default, even when cloud machines are already on the account.
    /// No-op once the user has explicitly chosen or no non-local machine exists.
    private func autoSelectPreferredMachineIfNeeded() {
        guard !registry.hasExplicitMachineSelection,
            localServer == nil,
            selectedMachineId == CodevisorMachine.local.id,
            let candidate = preferredAutoSelectionCandidate()
        else { return }
        // Deliberately not selectMachine: the auto-pick must stay non-explicit
        // so it can be re-picked if this machine later disappears.
        applySelection(candidate.id)
        Task { await prepareSelectedMachine() }
    }

    /// The machine auto-selection should adopt: any non-local machine, with an
    /// online one preferred over an offline one; ties (and the all-offline
    /// case) break by `allMachines` list order (local first, then configured
    /// remotes, then cloud-only entries). With a single cloud machine present,
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

    /// A cloud selection persisted across launches resolves to the local
    /// machine until the account's machine list arrives. Once it does, rewire
    /// project list and gate to the now-available cloud machine.
    public func reconcileCloudSelection() {
        let selectedId = selectedMachineId
        if selectedId.hasPrefix(CodevisorMachine.cloudIdPrefix),
            machine(for: selectedId) != nil,
            projectList.selectedServerId != selectedId
        {
            selectMachine(selectedId)
            // The shell's selection-change task is keyed on the machine id,
            // which never changed here (the persisted selection was this cloud
            // machine all along) — it will not refire, and without preparation
            // the request gate would stay waiting forever. Kick it explicitly,
            // like addRemote does for a freshly added machine.
            Task { await prepareSelectedMachine() }
            return
        }
        // A fresh sign-in with machines but no explicit choice: adopt one so
        // the user isn't left on the local placeholder.
        autoSelectPreferredMachineIfNeeded()
    }

    /// Cloud entries only exist while signed in; when the account signs out
    /// with a cloud machine selected, fall back to the local machine so the
    /// app never points at a machine that no longer exists.
    public func handleCloudAccountSignedOut() {
        guard selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix) else { return }
        registry.selectedMachineId = CodevisorMachine.local.id
        beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
        persist()
        projectList.selectServer(
            serverId: CodevisorMachine.local.id,
            serverClient: client(for: CodevisorMachine.local.id),
            refresh: false
        )
        Task { await prepareSelectedMachine() }
    }

    @discardableResult
    public func addRemote(host input: String, name: String? = nil, token: String? = nil) throws -> CodevisorMachine {
        let baseURL = try Self.normalizedRemoteURL(from: input)
        let customName = Self.normalizedName(name)
        let normalizedToken = Self.normalizedName(token)
        if let index = registry.remoteMachines.firstIndex(where: { $0.baseURL == baseURL }) {
            if let customName {
                registry.remoteMachines[index].name = customName
            }
            if let normalizedToken {
                registry.remoteMachines[index].token = normalizedToken
            }
            let existing = registry.remoteMachines[index]
            registry.selectedMachineId = existing.id
            beginWaiting(for: existing.id, reason: .connecting)
            persist()
            projectList.selectServer(
                serverId: existing.id,
                serverClient: client(for: existing.id),
                refresh: false
            )
            Task { await prepareSelectedMachine() }
            return existing
        }
        let baseId = Self.remoteId(for: baseURL)
        let id = uniqueMachineId(baseId)
        let machine = CodevisorMachine(
            id: id,
            name: customName ?? baseURL.host ?? id,
            baseURL: baseURL,
            kind: "remote",
            token: normalizedToken
        )
        registry.remoteMachines.append(machine)
        registry.selectedMachineId = machine.id
        beginWaiting(for: machine.id, reason: .connecting)
        persist()
        projectList.selectServer(
            serverId: machine.id,
            serverClient: client(for: machine.id),
            refresh: false
        )
        // Probe right away so a freshly added machine shows its real status
        // instead of waiting for the next periodic refresh.
        Task { await prepareSelectedMachine() }
        return machine
    }

    /// This machine's stable connection token (the loopback call is exempt
    /// from token auth), for pasting into another device's Add Remote Machine
    /// sheet. Stable across restarts so the copied value keeps working.
    public func issueLocalConnectionToken() async throws -> String {
        try await client(for: CodevisorMachine.local.id).connectionToken().token
    }

    /// Adds a remote machine only after confirming the host is reachable and
    /// the token is accepted, so a wrong token surfaces as an error in the Add
    /// dialog instead of a broken machine you have to remove and re-add.
    @discardableResult
    public func addRemoteValidating(
        host input: String,
        name: String? = nil,
        token: String? = nil
    ) async throws -> CodevisorMachine {
        let baseURL = try Self.normalizedRemoteURL(from: input)
        let probe = CodevisorMachine(
            id: "probe",
            name: "probe",
            baseURL: baseURL,
            kind: "remote",
            token: Self.normalizedName(token)
        )
        // Throws on an unreachable host or a rejected token (401).
        _ = try await clientFactory(probe).info()
        return try addRemote(host: input, name: name, token: token)
    }

    /// Renames a remote machine. Blank names are ignored; the local machine
    /// can't be renamed.
    public func renameMachine(_ id: String, to name: String) throws {
        guard id != CodevisorMachine.local.id else { throw MachineControllerError.cannotRenameLocal }
        guard let customName = Self.normalizedName(name),
            let index = registry.remoteMachines.firstIndex(where: { $0.id == id })
        else { return }
        registry.remoteMachines[index].name = customName
        persist()
    }

    private static func normalizedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func removeMachine(_ id: String) throws {
        guard id != CodevisorMachine.local.id else { throw MachineControllerError.cannotRemoveLocal }
        try credentialStore?.removeToken(forMachineID: id)
        registry.remoteMachines.removeAll { $0.id == id }
        // Drop the removed machine's in-memory state. Its status in
        // particular carries the cloud device id that deduplicates the cloud
        // machine list — left behind, it would keep hiding the machine's
        // cloud twin from `allMachines`.
        statusByMachineId[id] = nil
        updateInfoByMachineId[id] = nil
        availabilityByMachineId[id] = nil
        navigationSyncStateByMachineId[id] = nil
        if registry.selectedMachineId == id {
            registry.selectedMachineId = CodevisorMachine.local.id
            beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
            projectList.selectServer(
                serverId: CodevisorMachine.local.id,
                serverClient: selectedClient,
                refresh: false
            )
            Task { await prepareSelectedMachine() }
        }
        persist()
    }

    public func removeAllRemoteMachines() {
        for machine in registry.remoteMachines {
            do {
                try credentialStore?.removeToken(forMachineID: machine.id)
            } catch {
                Log.persistence.error(
                    "Failed to remove credential for \(machine.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            // Same as removeMachine: the app-data reset runs in-process, so
            // a removed machine's stale status (with its cloud device id)
            // would otherwise survive and dedup its cloud twin away.
            statusByMachineId[machine.id] = nil
            updateInfoByMachineId[machine.id] = nil
            availabilityByMachineId[machine.id] = nil
            navigationSyncStateByMachineId[machine.id] = nil
        }
        credentialReadFailures.removeAll()
        registry = MachineRegistry()
        beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
        persist()
        projectList.selectServer(
            serverId: CodevisorMachine.local.id,
            serverClient: selectedClient,
            refresh: false
        )
        Task { await prepareSelectedMachine() }
    }

    public func prepareSelectedMachine() async {
        let machine = selectedMachine
        let machineId = machine.id
        let client = client(for: machineId)

        if preparationMachineId == machineId, let preparationTask {
            await preparationTask.value
            return
        }

        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPreparation(
                for: machine,
                client: client
            )
        }
        preparationMachineId = machineId
        preparationToken = token
        preparationTask = task
        await task.value
        if preparationToken == token {
            preparationMachineId = nil
            preparationToken = nil
            preparationTask = nil
        }
    }

    private func performPreparation(
        for machine: CodevisorMachine,
        client: any CodevisorServerClienting
    ) async {
        let machineId = machine.id
        navigationSyncStateByMachineId[machineId] = .catchingUp

        if machine.isLocal, let localServer {
            let serverState = await localServer.ensureRunning()
            guard machineId == selectedMachineId else { return }
            if case let .unavailable(message) = serverState {
                markFailed(for: machineId, message: message)
                statusByMachineId[machineId] = MachineStatus(isReachable: false, label: message)
                return
            }
            if serverState == .alreadyRunning {
                // The durable server's PATH is frozen at its launch; a CLI
                // installed since then (followed by an app relaunch) stays
                // invisible to it. Fire one rescan so it re-resolves PATH —
                // off the critical path so machine prep isn't delayed.
                Task {
                    do {
                        _ = try await client.rescanHarnesses()
                    } catch {
                        Log.machines.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        } else {
            do {
                // Unlike health, info also proves this device's connection
                // token is accepted before ordinary requests are released.
                _ = try await client.info()
            } catch {
                guard machineId == selectedMachineId else { return }
                let message = serverErrorMessage(error)
                markFailed(for: machineId, message: message)
                statusByMachineId[machineId] = MachineStatus(isReachable: false, label: message)
                return
            }
        }

        guard machineId == selectedMachineId else { return }
        markReady(for: machineId)
        await refreshStatus(for: machineId)
        guard machineId == selectedMachineId else { return }
        await synchronizeNavigationState(
            serverId: machineId,
            client: client,
            presentation: .catchUp
        )
    }

    public func retrySelectedMachine() async {
        let machine = selectedMachine
        beginWaiting(for: machine.id, reason: machine.isLocal ? .starting : .connecting)
        await prepareSelectedMachine()
    }

    public func refreshStatus(for id: String) async {
        let client = client(for: id)
        do {
            let info = try await client.info()
            statusByMachineId[id] = MachineStatus(
                isReachable: true,
                label: "\(info.name) \(info.version)",
                cloudDeviceId: info.cloudDeviceId
            )
            // A signed-in account with an unregistered local server (it may
            // have started after sign-in): register it now so this machine
            // shows up on the user's other devices.
            if id == CodevisorMachine.local.id, info.cloudDeviceId == nil {
                cloudProvider?.registerLocalMachineIfNeeded()
            }
            do {
                updateInfoByMachineId[id] = try await client.updateInfo(
                    refresh: true,
                    channel: serverUpdateChannel
                )
            } catch {
                updateInfoByMachineId[id] = nil
                Log.machines.debug(
                    "Update info probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        } catch {
            // A local server that failed to start has a more useful story
            // than "Unreachable" — surface why instead.
            if id == CodevisorMachine.local.id, case let .unavailable(message) = localServer?.state {
                statusByMachineId[id] = MachineStatus(isReachable: false, label: message)
            } else if case CodevisorServerClientError.httpStatus(401, _) = error {
                // The server answered — the token is just wrong (or the
                // machine was paired against a different server on that host).
                // Say so, so the user fixes the token instead of chasing a
                // phantom network problem.
                statusByMachineId[id] = MachineStatus(isReachable: false, label: "Invalid connection token")
            } else {
                statusByMachineId[id] = MachineStatus(isReachable: false, label: "Unreachable")
                Log.machines.debug(
                    "Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Refreshes only the selected remote machine's release state. The app
    /// calls this periodically while that machine is open so a release cut
    /// after the initial connection still raises the update banner.
    public func refreshSelectedServerUpdate() async {
        let machineId = selectedMachineId
        guard !selectedMachine.isLocal, serverUpdatePhase != .updating else { return }
        let client = selectedClient
        do {
            let update = try await client.updateInfo(
                refresh: true,
                channel: serverUpdateChannel
            )
            // A machine switch can happen while the request is in flight.
            guard machineId == selectedMachineId else { return }
            updateInfoByMachineId[machineId] = update
        } catch {
            // A transient background failure should not erase a banner we
            // already know about. The next five-minute pass will retry.
            Log.machines.debug(
                "Periodic update probe for \(machineId, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The selected machine's server update state, when known.
    public var selectedServerUpdate: ServerUpdateInfo? {
        updateInfoByMachineId[selectedMachineId]
    }

    /// Asks the selected machine's server to update itself, then waits for it
    /// to restart into the newer version before refreshing everything and
    /// resubscribing to its event stream.
    public func updateSelectedServer() async {
        guard serverUpdatePhase != .updating else { return }
        let machineId = selectedMachineId
        let client = selectedClient
        let updateChannel = serverUpdateChannel
        let initialVersion = selectedServerUpdate?.currentVersion
        serverUpdatePhase = .updating
        // Close the gate before dispatching the update request. The server
        // may begin shutting down as soon as it handles that endpoint, before
        // the response has made the round trip back to this client.
        beginWaiting(for: machineId, reason: .updating)
        let initialHealth = try? await client.health()
        do {
            let applied = try await client.applyServerUpdate(channel: updateChannel)
            guard applied.accepted else {
                markReady(for: machineId)
                if machineId == selectedMachineId { startEventSync() }
                if applied.reason == "busy" {
                    // The server still has chats mid-turn; updating now would
                    // kill them. The banner disables its button for this app's
                    // own chats, but another client could have started one.
                    serverUpdatePhase = .failed(
                        "This server still has chats running. Wait for them to finish, then update."
                    )
                    return
                }
                // Nothing to do (already up to date); refresh the banner state.
                await refreshStatus(for: machineId)
                serverUpdatePhase = .idle
                return
            }
            for _ in 0..<updatePollAttempts {
                try? await Task.sleep(for: updatePollInterval)
                // The user moved on to a different machine; stop waiting.
                guard machineId == selectedMachineId else {
                    serverUpdatePhase = .idle
                    return
                }
                guard let info = try? await client.info() else { continue }
                let exactTargetReached =
                    applied.targetVersion == nil || info.version == applied.targetVersion
                var restartedWithDifferentVersion =
                    (initialVersion ?? initialHealth?.version).map { info.version != $0 } ?? false
                if !restartedWithDifferentVersion,
                    let initialBootId = initialHealth?.bootId,
                    let currentBootId = (try? await client.health())?.bootId
                {
                    restartedWithDifferentVersion = currentBootId != initialBootId
                }
                var requestedChannelIsCurrent = false
                if !exactTargetReached, restartedWithDifferentVersion,
                    let update = try? await client.updateInfo(
                        refresh: true,
                        channel: updateChannel
                    )
                {
                    requestedChannelIsCurrent = !update.updateAvailable
                }
                if exactTargetReached || requestedChannelIsCurrent {
                    // Clear the spinner as soon as the replacement server is
                    // confirmed. Alpha manifests include a prerelease suffix,
                    // while the bundled runtime reports its base version, and
                    // a remote Mac may install an even newer release according
                    // to its own Sparkle channel.
                    serverUpdatePhase = .idle
                    markReady(for: machineId)
                    await refreshStatus(for: machineId)
                    await projectList.refreshFromServer()
                    startEventSync()
                    return
                }
            }
            let message = "The server did not come back after updating. Check it on the machine directly."
            serverUpdatePhase = .failed(message)
            markFailed(for: machineId, message: message)
        } catch {
            let message = serverErrorMessage(error)
            serverUpdatePhase = .failed(message)
            if (try? await client.info()) != nil {
                markReady(for: machineId)
                if machineId == selectedMachineId { startEventSync() }
            } else {
                markFailed(for: machineId, message: message)
            }
        }
    }

    private func beginWaiting(for machineId: String, reason: ServerWaitingReason) {
        if let navigationSyncMachineId, navigationSyncMachineId != machineId {
            navigationSyncTask?.cancel()
            self.navigationSyncMachineId = nil
            navigationSyncToken = nil
            navigationSyncTask = nil
        }
        if machineId == selectedMachineId {
            stopEventSync()
        }
        availabilityByMachineId[machineId] = .waiting(reason)
        navigationSyncStateByMachineId[machineId] = .catchingUp
        requestGate.beginWaiting(for: machineId)
    }

    private func markReady(for machineId: String) {
        availabilityByMachineId[machineId] = .ready
        requestGate.markReady(for: machineId)
    }

    private func markFailed(for machineId: String, message: String) {
        availabilityByMachineId[machineId] = .failed(message)
        navigationSyncStateByMachineId[machineId] = .stale(message)
        requestGate.markFailed(for: machineId, message: message)
    }

    public static func normalizedRemoteURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MachineControllerError.invalidHost(input) }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
            components.host?.isEmpty == false
        else {
            throw MachineControllerError.invalidHost(input)
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        if components.port == nil {
            components.port = CodevisorServerConfig.productionPort
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw MachineControllerError.invalidHost(input) }
        return url
    }

    private func uniqueMachineId(_ baseId: String) -> String {
        if machine(for: baseId) == nil { return baseId }
        var index = 2
        while machine(for: "\(baseId)-\(index)") != nil {
            index += 1
        }
        return "\(baseId)-\(index)"
    }

    private static func remoteId(for url: URL) -> String {
        let host = url.host ?? "remote"
        let port = url.port ?? CodevisorServerConfig.productionPort
        let raw = "remote-\(host)-\(port)".lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private func persist() {
        do {
            var persisted = registry.normalized()
            if let credentialStore {
                for index in persisted.remoteMachines.indices {
                    let machine = persisted.remoteMachines[index]
                    if let token = machine.token, !token.isEmpty {
                        try credentialStore.saveToken(token, forMachineID: machine.id)
                        guard try credentialStore.token(forMachineID: machine.id) == token else {
                            throw ClientDatabaseError(
                                operation: "credential read-back",
                                detail: "Token for \(machine.id) did not round-trip"
                            )
                        }
                        credentialReadFailures.remove(machine.id)
                    } else if !credentialReadFailures.contains(machine.id) {
                        try credentialStore.removeToken(forMachineID: machine.id)
                    }
                    persisted.remoteMachines[index].token = nil
                }
            }
            try store.saveData(JSONEncoder().encode(persisted), forKey: key)
        } catch {
            Log.persistence.error(
                "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

private extension MachineRegistry {
    func normalized() -> MachineRegistry {
        let remotes = remoteMachines.filter { !$0.isLocal }
        let allIds = Set(remotes.map(\.id)).union([CodevisorMachine.local.id])
        // Cloud selections persist by id (stable across launches); when the
        // machine isn't available (signed out), selection falls back to
        // local at resolution time instead of being rewritten here.
        let keepsSelection =
            allIds.contains(selectedMachineId)
            || selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
        return MachineRegistry(
            selectedMachineId: keepsSelection ? selectedMachineId : CodevisorMachine.local.id,
            hasExplicitMachineSelection: hasExplicitMachineSelection,
            remoteMachines: remotes
        )
    }
}
