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

/// User-chosen SF Symbol used to identify a machine.
public struct MachineAppearance: Sendable, Codable, Equatable {
    public var symbolName: String

    public init(symbolName: String) {
        self.symbolName = symbolName
    }

    public static let localDefault = MachineAppearance(
        symbolName: "desktopcomputer"
    )

    public static let remoteDefault = MachineAppearance(
        symbolName: "network"
    )

    public static let cloudDefault = MachineAppearance(
        symbolName: "icloud"
    )
}

public struct CodevisorMachine: Identifiable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var kind: String
    /// Bearer token for this machine's server. Nil for the local machine —
    /// same-machine connections are exempt from the server's token auth.
    public var token: String?
    /// Nil means the machine uses the appropriate local or remote default.
    /// Keeping this optional makes existing persisted registries decode
    /// without a migration.
    public var appearance: MachineAppearance?

    public init(
        id: String,
        name: String,
        baseURL: URL,
        kind: String,
        token: String? = nil,
        appearance: MachineAppearance? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.token = token
        self.appearance = appearance
    }

    public var isLocal: Bool { id == Self.local.id }

    /// True for machines reached through the Codevisor Cloud relay (their ids
    /// are `cloud:<deviceId>`; they are synthesized from cloud presence, not
    /// stored in the registry).
    public var isCloud: Bool { id.hasPrefix(Self.cloudIdPrefix) }

    public var resolvedAppearance: MachineAppearance {
        let fallback = if isLocal {
            MachineAppearance.localDefault
        } else if isCloud {
            MachineAppearance.cloudDefault
        } else {
            MachineAppearance.remoteDefault
        }
        guard let appearance,
              !appearance.symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return appearance
    }

    public var serverConfig: CodevisorServerConfig {
        CodevisorServerConfig(baseURL: baseURL, bearerToken: token)
    }

    public static let local = CodevisorMachine(
        id: "local",
        name: "Local",
        baseURL: URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
        kind: "local"
    )

    public static let cloudIdPrefix = "cloud:"
    /// Cloud machines have no direct address; requests tunnel through the
    /// relay, so their baseURL is a recognizable placeholder.
    public static let cloudPlaceholderBaseURL = URL(string: "https://cloud-relay.invalid")!

    /// The machine-list entry for a cloud presence entry that has no
    /// configured (direct) machine. Its id is stable across launches because
    /// the cloud device id is.
    public static func cloud(from machine: CloudMachine) -> CodevisorMachine {
        CodevisorMachine(
            id: "\(cloudIdPrefix)\(machine.deviceId)",
            name: machine.name,
            baseURL: cloudPlaceholderBaseURL,
            kind: "cloud"
        )
    }

    /// The cloud device id for a `cloud:` machine id, nil otherwise.
    public static func cloudDeviceId(forMachineId id: String) -> String? {
        guard id.hasPrefix(cloudIdPrefix) else { return nil }
        return String(id.dropFirst(cloudIdPrefix.count))
    }
}

/// What the machine list needs from the cloud account feature: the signed-in
/// account's machines plus relay-backed server configs for them. Implemented
/// by CloudAccountController; fakes stand in for tests.
@MainActor
public protocol CloudMachineProviding: AnyObject {
    var isCloudSignedIn: Bool { get }
    var cloudMachines: [CloudMachine] { get }
    /// A server config whose transports tunnel through the cloud relay to
    /// this machine — nil when the relay isn't available (signed out).
    func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig?
    /// A real `http://127.0.0.1:<port>` base URL for this machine, served by
    /// an in-app loopback bridge that forwards plain HTTP/WebSocket onto the
    /// relay — for baseURL consumers that spawn external processes (the
    /// terminal proxy). Calling this may lazily start the bridge; nil until
    /// it is listening (or when the implementation doesn't bridge).
    func loopbackBaseURL(for machine: CloudMachine) -> URL?
}

public extension CloudMachineProviding {
    func loopbackBaseURL(for machine: CloudMachine) -> URL? { nil }
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
    /// The local machine isn't stored in `remoteMachines`, so its optional
    /// appearance override lives alongside the remote registry.
    public var localAppearance: MachineAppearance?
    /// Appearance overrides for cloud-relay machines, keyed by their stable
    /// `cloud:<deviceId>` machine id. Cloud machines are synthesized from
    /// cloud presence rather than stored in `remoteMachines`, so their icons
    /// live here. Entries for machines that leave the account are kept — a
    /// reconnecting machine gets its icon back for free.
    public var cloudAppearances: [String: MachineAppearance]

    public init(
        selectedMachineId: String = CodevisorMachine.local.id,
        hasExplicitMachineSelection: Bool = false,
        remoteMachines: [CodevisorMachine] = [],
        localAppearance: MachineAppearance? = nil,
        cloudAppearances: [String: MachineAppearance] = [:]
    ) {
        self.selectedMachineId = selectedMachineId
        self.hasExplicitMachineSelection = hasExplicitMachineSelection
        self.remoteMachines = remoteMachines
        self.localAppearance = localAppearance
        self.cloudAppearances = cloudAppearances
    }

    /// Custom decode so registries persisted before `cloudAppearances`
    /// existed load with an empty map instead of failing (which would look
    /// like corruption and reset the machine list).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedMachineId = try container.decode(String.self, forKey: .selectedMachineId)
        // Registries persisted before this flag existed decode as "no explicit
        // choice yet", so they benefit from auto-selection like fresh installs.
        hasExplicitMachineSelection = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasExplicitMachineSelection
        ) ?? false
        remoteMachines = try container.decode([CodevisorMachine].self, forKey: .remoteMachines)
        localAppearance = try container.decodeIfPresent(MachineAppearance.self, forKey: .localAppearance)
        cloudAppearances = try container.decodeIfPresent(
            [String: MachineAppearance].self,
            forKey: .cloudAppearances
        ) ?? [:]
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
    private let projectList: ProjectListModel
    private let localServer: (any LocalServerControlling)?
    private let clientFactory: ClientFactory
    private let requestGate: ServerRequestGate
    private let key = "machines"
    /// How long to wait between reachability probes while the remote server
    /// restarts into its updated version. Injectable so tests run fast.
    private let updatePollInterval: Duration
    private let updatePollAttempts: Int
    @ObservationIgnored private var credentialReadFailures: Set<String> = []
    @ObservationIgnored private var eventSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var preparationMachineId: String?
    @ObservationIgnored private var preparationToken: UUID?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    /// Invoked when a `harness.lifecycle.updated` event arrives for a machine
    /// — the AppEnvironment bridges it to its harness-catalog revision so
    /// mounted pickers and settings panes refetch.
    @ObservationIgnored public var onHarnessLifecycleChanged: ((String) -> Void)?

    public init(
        store: any PersistenceStore,
        projectList: ProjectListModel,
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
        self.localServer = localServer
        self.requestGate = requestGate
        self.clientFactory = clientFactory ?? {
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
        var local = CodevisorMachine.local
        local.appearance = registry.localAppearance
        return [local] + registry.remoteMachines
    }

    /// Every machine the app can reach, however it arrives: the configured
    /// (local + remote) machines plus one synthesized entry per cloud machine
    /// that no configured machine already represents.
    public var allMachines: [CodevisorMachine] {
        machines + cloudOnlyMachines.map { cloud in
            var machine = CodevisorMachine.cloud(from: cloud)
            // A real loopback address (bridged onto the relay) replaces the
            // placeholder once the machine's bridge is listening, so baseURL
            // consumers like the external terminal proxy can actually dial it.
            if let loopback = cloudProvider?.loopbackBaseURL(for: cloud) {
                machine.baseURL = loopback
            }
            // Cloud machines aren't stored in the registry, so their saved
            // icon lives in a side map keyed by the stable `cloud:` id. Nil
            // resolves to the icloud default.
            machine.appearance = registry.cloudAppearances[machine.id]
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
        projectList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
    }

    /// When the user hasn't made an explicit choice yet and only the local
    /// placeholder is selected, adopt the best available real machine. On iOS
    /// the local machine is a non-functional placeholder, so a fresh sign-in
    /// that has cloud machines should land on one of them instead of stranding
    /// the user on "Local". No-op once the user has explicitly chosen, or when
    /// no non-local machine exists (e.g. macOS with only its local server).
    private func autoSelectPreferredMachineIfNeeded() {
        guard !registry.hasExplicitMachineSelection,
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
           projectList.selectedServerId != selectedId {
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
            serverClient: client(for: CodevisorMachine.local.id)
        )
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
            projectList.selectServer(serverId: existing.id, serverClient: client(for: existing.id))
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
        projectList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
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

    /// Updates the icon used to identify a machine throughout the app.
    /// Invalid values fall back to that machine kind's safe default.
    public func setAppearance(_ appearance: MachineAppearance, for id: String) {
        guard let machine = machine(for: id) else { return }
        let normalized = CodevisorMachine(
            id: machine.id,
            name: machine.name,
            baseURL: machine.baseURL,
            kind: machine.kind,
            token: machine.token,
            appearance: appearance
        ).resolvedAppearance

        if machine.isLocal {
            registry.localAppearance = normalized
        } else if machine.isCloud {
            registry.cloudAppearances[machine.id] = normalized
        } else if let index = registry.remoteMachines.firstIndex(where: { $0.id == id }) {
            registry.remoteMachines[index].appearance = normalized
        }
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
        if registry.selectedMachineId == id {
            registry.selectedMachineId = CodevisorMachine.local.id
            beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
            projectList.selectServer(serverId: CodevisorMachine.local.id, serverClient: selectedClient)
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
        }
        credentialReadFailures.removeAll()
        registry = MachineRegistry()
        beginWaiting(for: CodevisorMachine.local.id, reason: .starting)
        persist()
        projectList.selectServer(
            serverId: CodevisorMachine.local.id,
            serverClient: selectedClient
        )
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
        await projectList.refreshFromServer()
        guard machineId == selectedMachineId else { return }
        startEventSync()
    }

    public func retrySelectedMachine() async {
        let machine = selectedMachine
        beginWaiting(for: machine.id, reason: machine.isLocal ? .starting : .connecting)
        await prepareSelectedMachine()
    }

    // MARK: - Live sync

    /// The only event kinds `handleSyncEvent` acts on. Everything else on the
    /// global socket — most of it per-token `session.output` chunks from every
    /// streaming session — is filtered inside the client's stream task so it
    /// never pays a main-actor hop just to hit the `default:` case below.
    static let shellSyncEventKinds: Set<String> = [
        "project.created", "project.updated", "project.deleted",
        "worktree.created",
        "session.created", "session.updated", "session.deleted",
        "session.attention.updated", "session.archived",
        "harness.lifecycle.updated",
    ]

    /// Follows the selected server's event stream so projects and sessions
    /// stay in sync across every client connected to that server. Replaces any
    /// previous subscription (e.g. after switching machines).
    public func startEventSync() {
        eventSyncTask?.cancel()
        let serverId = selectedMachine.id
        let client = selectedClient
        eventSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // The project/session lists above are the shell snapshot.
                    // Subscribe live-only after it instead of replaying the
                    // server's lifetime global log on every app launch.
                    for try await event in client.shellEventStream(handledKinds: Self.shellSyncEventKinds) {
                        guard let self, !Task.isCancelled else { return }
                        self.handleSyncEvent(event, serverId: serverId)
                    }
                    return
                } catch {
                    Log.machines.error("Event sync for \(serverId, privacy: .public) failed; resubscribing: \(String(describing: error), privacy: .public)")
                    guard let self, !Task.isCancelled else { return }
                    // Reconcile durable metadata, then subscribe live-only
                    // again. This skips a malformed event instead of retrying
                    // forever from the same global cursor.
                    await self.projectList.refreshFromServer()
                }
            }
        }
    }

    public func stopEventSync() {
        eventSyncTask?.cancel()
        eventSyncTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    private func handleSyncEvent(_ event: ServerEventEnvelope, serverId: String) {
        guard serverId == selectedMachine.id else { return }
        switch event.kind {
        case "project.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                projectList.removeProjectLocally(id: id, serverId: serverId)
            }
        case "session.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                projectList.removeSessionLocally(id: id, serverId: serverId)
            }
        case "project.created", "project.updated", "worktree.created",
             "session.created", "session.updated", "session.attention.updated",
             "session.archived":
            scheduleProjectRefresh()
        case "harness.lifecycle.updated":
            // Update detection / install progress changed a harness — bump
            // the catalog revision so mounted pickers and settings refetch.
            onHarnessLifecycleChanged?(serverId)
        default:
            // Prompt/queue/error events are handled by the session transports.
            break
        }
    }

    /// Coalesces bursts of events (including the initial replay) into a single
    /// refresh from the server.
    private func scheduleProjectRefresh() {
        guard pendingRefreshTask == nil else { return }
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingRefreshTask = nil
            await self.projectList.refreshFromServer()
        }
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
            do {
                updateInfoByMachineId[id] = try await client.updateInfo(
                    refresh: true,
                    channel: serverUpdateChannel
                )
            } catch {
                updateInfoByMachineId[id] = nil
                Log.machines.debug("Update info probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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
                Log.machines.debug("Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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
                   let currentBootId = (try? await client.health())?.bootId {
                    restartedWithDifferentVersion = currentBootId != initialBootId
                }
                var requestedChannelIsCurrent = false
                if !exactTargetReached, restartedWithDifferentVersion,
                   let update = try? await client.updateInfo(
                       refresh: true,
                       channel: updateChannel
                   ) {
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
        if machineId == selectedMachineId {
            stopEventSync()
        }
        availabilityByMachineId[machineId] = .waiting(reason)
        requestGate.beginWaiting(for: machineId)
    }

    private func markReady(for machineId: String) {
        availabilityByMachineId[machineId] = .ready
        requestGate.markReady(for: machineId)
    }

    private func markFailed(for machineId: String, message: String) {
        availabilityByMachineId[machineId] = .failed(message)
        requestGate.markFailed(for: machineId, message: message)
    }

    public static func normalizedRemoteURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MachineControllerError.invalidHost(input) }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.host?.isEmpty == false else {
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
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
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
        let keepsSelection = allIds.contains(selectedMachineId)
            || selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix)
        return MachineRegistry(
            selectedMachineId: keepsSelection ? selectedMachineId : CodevisorMachine.local.id,
            hasExplicitMachineSelection: hasExplicitMachineSelection,
            remoteMachines: remotes,
            localAppearance: localAppearance,
            cloudAppearances: cloudAppearances
        )
    }
}
