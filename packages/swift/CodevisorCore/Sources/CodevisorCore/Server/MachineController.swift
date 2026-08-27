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
    /// How the machine answered (Phase 22): directly, or through the cloud
    /// relay after the direct route failed. Nil while unreachable.
    public var route: MachineRoute?
    /// The server's own stable id (config.id from /v1/info) — the key its
    /// entries carry in the fleet's sync namespaces. Distinct from the
    /// CLIENT-side machine id ("cloud:<deviceId>", "remote-…").
    public var serverId: String?

    public init(
        isReachable: Bool,
        label: String,
        cloudDeviceId: String? = nil,
        route: MachineRoute? = nil,
        serverId: String? = nil
    ) {
        self.isReachable = isReachable
        self.label = label
        self.cloudDeviceId = cloudDeviceId
        self.route = route
        self.serverId = serverId
    }
}

/// The transport a machine's traffic currently rides.
public enum MachineRoute: Sendable, Equatable {
    case direct
    case relay
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
    /// Live apps keep bearer tokens in Keychain. Nil preserves the embedded
    /// token behavior for isolated previews/tests that do not have a device
    /// credential store.
    private let credentialStore: (any MachineCredentialStore)?
    let projectList: ProjectListModel
    let workspaceSync: WorkspaceSyncModel?
    // Internal so split-off extension files (MachineConnection) can key the
    // fleet's composition on it: platforms without a local server have no
    // "Local" machine at all.
    let localServer: (any LocalServerControlling)?
    let clientFactory: ClientFactory
    let requestGate: ServerRequestGate
    private let key = "machines"
    /// How long to wait between reachability probes while the remote server
    /// restarts into its updated version. Injectable so tests run fast.
    let updatePollInterval: Duration
    let updatePollAttempts: Int
    @ObservationIgnored private var credentialReadFailures: Set<String> = []
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
    /// Invoked when a `sync.changed` event arrives — a machine's config
    /// replica changed; ConfigSync adopts and re-gossips it. Arguments:
    /// (serverId, changed document).
    @ObservationIgnored public var onSyncChanged: ((String, ServerSyncDocument) -> Void)?
    /// Invoked when a machine's live connection comes up (selected machine
    /// prepared, or a background stream opened) — ConfigSync converges it
    /// immediately instead of waiting for the next periodic sweep.
    @ObservationIgnored public var onMachineConnected: ((String) -> Void)?
    /// Invoked after a remote machine is added or re-tokened (sheet,
    /// deeplink, or roster apply) — the fleet roster publishes it.
    @ObservationIgnored public var onMachineAdded: ((CodevisorMachine) -> Void)?
    /// Invoked after a machine is removed locally — the roster tombstones it.
    @ObservationIgnored public var onMachineRemoved: ((String) -> Void)?

    /// Fired after a machine's route flips (direct ↔ relay) and its shell
    /// stream has been re-homed, so app-level chat caches can re-home their
    /// per-session streams onto the new transport too.
    @ObservationIgnored public var onMachineRouteChanged: ((String) -> Void)?

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
        // The PERSISTED links dedupe too: a machine whose direct route is
        // down this launch has no live probe to advertise its identity, and
        // must not sprout a cloud twin next to its configured entry.
        .union(registry.remoteMachines.compactMap(\.cloudDeviceId))
        let knownNames = Set(machines.map(\.name))
        return cloudProvider.cloudMachines.filter {
            !knownCloudIds.contains($0.deviceId) && !knownNames.contains($0.name)
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

    /// When only the local placeholder is selected on a client-only platform,
    /// adopt the best available real machine. Client-only platforms (no local
    /// server) don't list "Local" at all, so a selection resting on it is
    /// never a real choice — explicit or not — and stranding the user there
    /// renders an unreachable fleet. macOS supplies a working local server
    /// and keeps it as the default, even when cloud machines are already on
    /// the account. No-op when a real machine is already selected or no
    /// non-local machine exists.
    private func autoSelectPreferredMachineIfNeeded() {
        guard localServer == nil,
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
        // Newly arrived cloud machines get their background streams even
        // when the selection did not move.
        ensureBackgroundConnections()
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
    /// `select: false` is the roster-apply path: the machine joins the list
    /// quietly, without stealing the user's current selection.
    public func addRemote(
        host input: String,
        name: String? = nil,
        token: String? = nil,
        select: Bool = true
    ) throws -> CodevisorMachine {
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
            if select { registry.selectedMachineId = existing.id }
            persist()
            if select {
                beginWaiting(for: existing.id, reason: .connecting)
                projectList.selectServer(
                    serverId: existing.id,
                    serverClient: client(for: existing.id),
                    refresh: false
                )
                Task { await prepareSelectedMachine() }
            }
            onMachineAdded?(existing)
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
        if select { registry.selectedMachineId = machine.id }
        persist()
        if select {
            beginWaiting(for: machine.id, reason: .connecting)
            projectList.selectServer(
                serverId: machine.id,
                serverClient: client(for: machine.id),
                refresh: false
            )
            // Probe right away so a freshly added machine shows its real
            // status instead of waiting for the next periodic refresh.
            Task { await prepareSelectedMachine() }
        }
        onMachineAdded?(machine)
        return machine
    }

    /// Adds a remote machine only after confirming the host is reachable and
    /// the token is accepted, so a wrong token surfaces as an error in the Add
    /// dialog instead of a broken machine you have to remove and re-add.
    /// `syncConfig` records the onboarding opt-in on the machine itself.
    @discardableResult
    public func addRemoteValidating(
        host input: String,
        name: String? = nil,
        token: String? = nil,
        syncConfig: Bool = true
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
        let machine = try addRemote(host: input, name: name, token: token)
        applySyncParticipation(machine.id, enabled: syncConfig)
        return machine
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
        onMachineRemoved?(id)
        try credentialStore?.removeToken(forMachineID: id)
        registry.remoteMachines.removeAll { $0.id == id }
        removeConnection(for: id)
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
            removeConnection(for: machine.id)
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
        // Background machines connect IMMEDIATELY, in parallel with the
        // selected machine's own preparation. Sequencing them after it meant
        // a hanging selected machine (dead LAN address, wedged relay) held
        // every healthy machine's snapshot hostage — and with it, the whole
        // fleet-aggregated home screen.
        ensureBackgroundConnections()
        connection(for: machineId).navigationSyncState = .catchingUp

        if machine.isLocal, let localServer {
            let serverState = await localServer.ensureRunning()
            guard machineId == selectedMachineId else { return }
            if case let .unavailable(message) = serverState {
                markFailed(for: machineId, message: message)
                connection(for: machineId).status = MachineStatus(
                    isReachable: false,
                    label: message
                )
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
                connection(for: machineId).status = MachineStatus(
                    isReachable: false,
                    label: message
                )
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
        onMachineConnected?(machineId)
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

    func persist() {
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
